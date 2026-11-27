//! An in-memory scan session. The worker pool reads file system metadata while the
//! coordinator publishes batches that callers can query during and after a scan.

mod ffi;
mod platform;
#[cfg(windows)]
mod smart;
mod snapshot;
mod tree;
#[cfg(windows)]
mod wsl;

use platform::{Adapter, EntryKind};
use std::collections::VecDeque;
use std::ffi::OsString;
use std::io;
use std::ops::AddAssign;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Mutex, RwLock,
    atomic::{AtomicBool, Ordering},
    mpsc::{self, Receiver, SyncSender},
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tree::{ListingEnd, Tree};

const MAX_WORKERS: usize = 32;
const BATCH_SIZE: usize = 128;
const BATCH_INTERVAL: Duration = Duration::from_millis(25);

/// A node ID belongs to the current result generation of one scan session.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct NodeId(pub usize);

pub const ROOT: NodeId = NodeId(0);

pub fn display_path(path: &Path) -> std::borrow::Cow<'_, str> {
    #[cfg(windows)]
    return wsl::display_path(path);
    #[cfg(not(windows))]
    path.to_string_lossy()
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Metric {
    #[default]
    Allocated,
    Logical,
}

impl Metric {
    fn index(self) -> usize {
        match self {
            Self::Allocated => 0,
            Self::Logical => 1,
        }
    }
}

/// A known subtotal and the number of file entries lacking a value for this metric.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Size {
    pub bytes: u128,
    pub unknown_files: usize,
}

impl Size {
    fn from_file(bytes: Option<u64>) -> Self {
        Self {
            bytes: bytes.unwrap_or(0).into(),
            unknown_files: usize::from(bytes.is_none()),
        }
    }

    pub fn known_value(self) -> Option<u128> {
        (self.unknown_files == 0).then_some(self.bytes)
    }
}

impl AddAssign for Size {
    fn add_assign(&mut self, other: Self) {
        self.bytes += other.bytes;
        self.unknown_files += other.unknown_files;
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Totals {
    pub allocated: Size,
    pub logical: Size,
}

impl Totals {
    pub fn size(self, metric: Metric) -> Size {
        match metric {
            Metric::Allocated => self.allocated,
            Metric::Logical => self.logical,
        }
    }
}

impl AddAssign for Totals {
    fn add_assign(&mut self, other: Self) {
        self.allocated += other.allocated;
        self.logical += other.logical;
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NodeKind {
    Directory,
    File,
    Link,
    Mount,
    Other,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Coverage {
    Pending,
    Partial,
    Complete,
    Unreadable,
    Excluded,
}

#[derive(Clone, Debug)]
pub struct NodeView {
    pub id: NodeId,
    pub parent: Option<NodeId>,
    pub name: OsString,
    pub kind: NodeKind,
    pub coverage: Coverage,
    pub sizes: Option<Totals>,
    pub target: Option<PathBuf>,
    /// The node receiving allocated bytes for this hard-linked file.
    pub shared_with: Option<NodeId>,
    pub placeholder: bool,
}

#[derive(Clone, Debug)]
pub struct ChildPage {
    pub total: usize,
    pub rows: Vec<NodeView>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Phase {
    #[default]
    Running,
    Stopping,
    Complete,
    Cancelled,
    Failed,
}

impl Phase {
    pub fn is_finished(self) -> bool {
        matches!(self, Self::Complete | Self::Cancelled | Self::Failed)
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Progress {
    pub phase: Phase,
    pub revision: u64,
    pub entries: usize,
    pub files: usize,
    pub skipped_directories: usize,
    pub unavailable_entries: usize,
    pub batched_directories: usize,
    pub elapsed: Duration,
    pub first_rows: Option<Duration>,
    pub first_browsable_directory: Option<Duration>,
}

#[derive(Clone, Copy, Debug)]
pub struct ScanOptions {
    pub workers: usize,
}

impl Default for ScanOptions {
    fn default() -> Self {
        let workers = thread::available_parallelism().map_or(1, |count| count.get().min(4));
        Self { workers }
    }
}

struct Shared {
    tree: RwLock<Tree>,
    stop: AtomicBool,
    error: Mutex<Option<String>>,
}

enum ScanSource {
    Native(Adapter),
    #[cfg(windows)]
    Wsl(wsl::Location),
}

impl ScanSource {
    fn prepare(
        path: &Path,
        original_root: Option<&Path>,
        _wsl_root: bool,
        _windows_batch: bool,
    ) -> io::Result<(PathBuf, Self)> {
        #[cfg(windows)]
        if let Some((reference, location)) =
            wsl::Location::prepare(path, original_root.is_some(), _wsl_root)?
        {
            return Ok((reference, Self::Wsl(location)));
        }
        let (root, adapter) = Adapter::prepare(original_root.unwrap_or(path))?;
        #[cfg(windows)]
        let adapter = adapter.with_batch_metadata(&root, _windows_batch);
        if original_root.is_some() {
            let parents: Vec<_> = path
                .ancestors()
                .skip(1)
                .take_while(|parent| parent.starts_with(&root) && *parent != root.as_path())
                .collect();
            for parent in parents.into_iter().rev() {
                adapter.check_directory(parent)?;
            }
            Ok((path.to_path_buf(), Self::Native(adapter)))
        } else {
            Ok((root, Self::Native(adapter)))
        }
    }

    fn run(&self, shared: &Shared, workers: usize) -> io::Result<()> {
        let result = match self {
            Self::Native(adapter) => scan_directories(adapter, shared, workers),
            #[cfg(windows)]
            Self::Wsl(location) => wsl::scan(location, shared),
        };
        if let Err(error) = &result {
            *shared.error.lock().unwrap() = Some(error.to_string());
        }
        result
    }
}

pub struct Scan {
    results: Arc<Shared>,
    operation: Arc<Shared>,
    coordinator: Option<JoinHandle<io::Result<()>>>,
    options: ScanOptions,
    wsl_root: bool,
    windows_batch: bool,
}

impl Scan {
    pub fn start(root: impl AsRef<Path>, options: ScanOptions) -> io::Result<Self> {
        Self::start_mode(root, options, false, false)
    }

    pub(crate) fn start_with_wsl_user(
        root: impl AsRef<Path>,
        options: ScanOptions,
        wsl_root: bool,
    ) -> io::Result<Self> {
        Self::start_mode(root, options, wsl_root, cfg!(windows))
    }

    /// Uses directory metadata batches on supported local NTFS volumes.
    #[cfg(windows)]
    pub fn start_windows_batch(root: impl AsRef<Path>, options: ScanOptions) -> io::Result<Self> {
        Self::start_mode(root, options, false, true)
    }

    fn start_mode(
        root: impl AsRef<Path>,
        options: ScanOptions,
        wsl_root: bool,
        windows_batch: bool,
    ) -> io::Result<Self> {
        if !(1..=MAX_WORKERS).contains(&options.workers) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("worker count must be between 1 and {MAX_WORKERS}"),
            ));
        }
        let started = Instant::now();
        let (root, source) = ScanSource::prepare(root.as_ref(), None, wsl_root, windows_batch)?;
        let shared = Arc::new(Shared {
            tree: RwLock::new(Tree::new(root, started)),
            stop: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let session = Arc::clone(&shared);
        let coordinator = thread::Builder::new()
            .name("treescan".into())
            .spawn(move || {
                let result = source.run(&session, options.workers);
                let phase = if result.is_err() {
                    Phase::Failed
                } else if session.stop.load(Ordering::Relaxed) {
                    Phase::Cancelled
                } else {
                    Phase::Complete
                };
                session.tree.write().unwrap().finish(phase);
                result
            })?;
        Ok(Self {
            results: Arc::clone(&shared),
            operation: shared,
            coordinator: Some(coordinator),
            options,
            wsl_root,
            windows_batch,
        })
    }

    /// Scan one directory using the original volume boundaries. While it is running,
    /// readers can continue to use the previous result. Cancellation keeps that result.
    pub fn rescan(&mut self, directory: NodeId) -> io::Result<()> {
        if !self.progress().phase.is_finished() {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "scan is already running",
            ));
        }
        self.wait()?;
        let (root, path, generation) = {
            let current = self.results.tree.read().unwrap();
            if !current
                .node(directory)
                .is_some_and(|node| node.kind == NodeKind::Directory)
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "select a scanned directory",
                ));
            }
            (
                current.path(ROOT).unwrap(),
                current.path(directory).unwrap(),
                current.generation,
            )
        };
        let started = Instant::now();
        let (path, source) =
            ScanSource::prepare(&path, Some(&root), self.wsl_root, self.windows_batch)?;
        let operation = Arc::new(Shared {
            tree: RwLock::new(Tree::new(path, started)),
            stop: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let session = Arc::clone(&operation);
        let results = Arc::clone(&self.results);
        let workers = self.options.workers;
        let coordinator = thread::Builder::new()
            .name("treescan-refresh".into())
            .spawn(move || {
                let result = source.run(&session, workers);
                let mut phase = if result.is_err() {
                    Phase::Failed
                } else {
                    Phase::Cancelled
                };
                if result.is_ok() && !session.stop.load(Ordering::Relaxed) {
                    let replacement = if directory == ROOT {
                        Some(session.tree.write().unwrap().release_contents())
                    } else {
                        let fresh = session.tree.read().unwrap();
                        let previous = results.tree.read().unwrap();
                        previous.replace_subtree(directory, &fresh, &session.stop)
                    };
                    if let Some(mut replacement) = replacement
                        && !session.stop.load(Ordering::Relaxed)
                    {
                        replacement.generation = generation + 1;
                        replacement.finish(Phase::Complete);
                        let previous =
                            std::mem::replace(&mut *results.tree.write().unwrap(), replacement);
                        drop(previous);
                        phase = Phase::Complete;
                    }
                }
                let discarded = {
                    let mut work = session.tree.write().unwrap();
                    work.finish(phase);
                    work.release_contents()
                };
                drop(discarded);
                result
            })?;
        self.operation = operation;
        self.coordinator = Some(coordinator);
        Ok(())
    }

    /// Request cancellation without waiting for in-flight metadata operations.
    pub fn stop(&self) {
        self.operation.stop.store(true, Ordering::Relaxed);
    }

    /// Wait for the background scan to finish. Results stay available on this session.
    pub fn wait(&mut self) -> io::Result<()> {
        if let Some(coordinator) = self.coordinator.take() {
            coordinator
                .join()
                .map_err(|_| io::Error::other("scan coordinator panicked"))?
        } else if self.progress().phase == Phase::Failed {
            Err(io::Error::other("scan failed"))
        } else {
            Ok(())
        }
    }

    pub fn progress(&self) -> Progress {
        self.operation
            .tree
            .read()
            .unwrap()
            .progress(self.operation.stop.load(Ordering::Relaxed))
    }

    pub fn result_progress(&self) -> Progress {
        self.results.tree.read().unwrap().progress(false)
    }

    /// Writes a versioned JSON snapshot of the current result tree.
    pub fn write_snapshot(&self, output: impl io::Write) -> io::Result<()> {
        snapshot::write(&self.results.tree.read().unwrap(), output)
    }

    pub fn last_error(&self) -> Option<String> {
        self.operation.error.lock().unwrap().clone()
    }

    pub fn generation(&self) -> u64 {
        self.results.tree.read().unwrap().generation
    }

    pub fn node(&self, id: NodeId) -> Option<NodeView> {
        self.results.tree.read().unwrap().node(id)
    }

    pub fn path(&self, id: NodeId) -> Option<PathBuf> {
        self.results.tree.read().unwrap().path(id)
    }

    pub fn find_path(&self, path: impl AsRef<Path>) -> Option<NodeId> {
        self.results.tree.read().unwrap().find_path(path.as_ref())
    }

    pub fn children(&self, directory: NodeId) -> Option<Vec<NodeView>> {
        self.results.tree.read().unwrap().children(directory)
    }

    pub fn children_page(
        &self,
        directory: NodeId,
        metric: Metric,
        offset: usize,
        limit: usize,
    ) -> Option<ChildPage> {
        self.results
            .tree
            .read()
            .unwrap()
            .children_page(directory, metric, offset, limit)
    }

    /// The 100 highest known values. Allocated rankings contain one name per hard-linked file.
    pub fn top_files(&self, metric: Metric) -> Vec<(PathBuf, NodeView)> {
        self.results.tree.read().unwrap().top_files(metric)
    }
}

impl Drop for Scan {
    fn drop(&mut self) {
        self.stop();
    }
}

type Job = (NodeId, PathBuf);

enum Event {
    Batch(NodeId, Vec<(OsString, EntryKind)>),
    End(NodeId, ListingEnd, bool),
}

fn scan_directories(adapter: &Adapter, shared: &Shared, workers: usize) -> io::Result<()> {
    thread::scope(|scope| {
        let (jobs, receiver) = mpsc::sync_channel(workers * 2);
        let receiver = Arc::new(Mutex::new(receiver));
        let (sender, events) = mpsc::sync_channel(workers * 2);
        for index in 0..workers {
            let receiver = Arc::clone(&receiver);
            let sender = sender.clone();
            thread::Builder::new()
                .name(format!("treescan-{}", index + 1))
                .spawn_scoped(scope, move || {
                    worker(&receiver, &sender, adapter, &shared.stop)
                })?;
        }
        drop(sender);
        drop(receiver);
        coordinate(shared, jobs, events, workers)
    })
}

fn coordinate(
    shared: &Shared,
    jobs: SyncSender<Job>,
    events: Receiver<Event>,
    workers: usize,
) -> io::Result<()> {
    let mut pending = VecDeque::from([ROOT]);
    let mut active = 0;
    loop {
        if shared.stop.load(Ordering::Relaxed) {
            pending.clear();
        }
        // Prefetch up to two queued directories per worker to keep traversal saturated.
        while active < workers * 2 {
            let Some(id) = pending.pop_front() else { break };
            let path = shared.tree.read().unwrap().path(id).unwrap();
            jobs.send((id, path))
                .map_err(|_| io::Error::other("scan workers exited"))?;
            active += 1;
        }
        if active == 0 {
            return Ok(());
        }
        let event = events
            .recv()
            .map_err(|_| io::Error::other("scan workers exited"))?;
        let mut tree = shared.tree.write().unwrap();
        match event {
            Event::Batch(id, entries) => tree.add_batch(id, entries, &mut pending),
            Event::End(id, status, batched) => {
                tree.listing_ended(id, status);
                if batched {
                    tree.count_batched_directory();
                }
                active -= 1;
            }
        }
    }
}

fn worker(
    jobs: &Mutex<Receiver<Job>>,
    events: &SyncSender<Event>,
    adapter: &Adapter,
    stop: &AtomicBool,
) {
    loop {
        let job = jobs.lock().unwrap().recv();
        let Ok((id, path)) = job else { break };
        if enumerate(id, &path, adapter, stop, events).is_err() {
            break;
        }
    }
}

fn enumerate(
    id: NodeId,
    path: &Path,
    adapter: &Adapter,
    stop: &AtomicBool,
    events: &SyncSender<Event>,
) -> Result<(), mpsc::SendError<Event>> {
    if stop.load(Ordering::Relaxed) {
        return events.send(Event::End(id, ListingEnd::NotStarted, false));
    }
    let (mut directory, batched) = match adapter.list(path) {
        Ok(directory) => directory,
        Err(error) => {
            let state = if error.kind() == io::ErrorKind::NotFound {
                ListingEnd::Missing
            } else {
                ListingEnd::Unreadable
            };
            return events.send(Event::End(id, state, false));
        }
    };

    let mut batch = Vec::new();
    let mut published = Instant::now();
    let end = loop {
        if stop.load(Ordering::Relaxed) {
            break ListingEnd::Interrupted;
        }
        let entry = match directory.next() {
            Some(Ok(entry)) => entry,
            Some(Err(_)) => break ListingEnd::Incomplete,
            None => break ListingEnd::Listed,
        };
        batch.push(entry);
        if batch.len() >= BATCH_SIZE || published.elapsed() >= BATCH_INTERVAL {
            events.send(Event::Batch(id, std::mem::take(&mut batch)))?;
            published = Instant::now();
        }
    };
    if !batch.is_empty() {
        events.send(Event::Batch(id, batch))?;
    }
    events.send(Event::End(id, end, batched))
}
