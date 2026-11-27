use crate::platform::{EntryKind, FileKey, FileSizes};
use crate::{
    BATCH_SIZE, ChildPage, Coverage, Metric, NodeId, NodeKind, NodeView, Phase, Progress, ROOT,
    Size, Totals,
};
use std::cmp::Reverse;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::ffi::OsString;
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const TOP_LIMIT: usize = 100;
const PAGE_CACHE_SLOTS: usize = 32;
const PAGE_CACHE_ITEMS: usize = 4096;
pub(crate) const PAGE_LENGTH: usize = 80;

#[derive(Clone, Copy)]
pub(crate) enum ListingEnd {
    Listed,
    Unreadable,
    Missing,
    Incomplete,
    Interrupted,
    NotStarted,
}

struct Node {
    parent: NodeId,
    name: OsString,
    data: Data,
    sizes: Totals,
    revision: u64,
}

enum Data {
    Directory(Directory),
    File(FileSizes),
    Link(Option<PathBuf>),
    Mount(Option<PathBuf>),
    Other,
    SkippedDirectory { placeholder: bool },
    Unavailable,
}

struct Directory {
    children: Vec<NodeId>,
    open_children: usize,
    end: Option<ListingEnd>,
    coverage: Coverage,
    placeholder: bool,
    contents_revision: u64,
    order_revision: [u64; 2],
}

impl Directory {
    fn new(placeholder: bool) -> Self {
        Self {
            children: Vec::new(),
            open_children: 0,
            end: None,
            coverage: Coverage::Pending,
            placeholder,
            contents_revision: 0,
            order_revision: [0; 2],
        }
    }
}

struct LinkGroup {
    owner: NodeId,
    allocated: Option<u64>,
    aliases: Vec<NodeId>,
}

struct ChildOrder {
    directory: NodeId,
    metric: Metric,
    revision: u64,
    ids: Vec<NodeId>,
}

// The larger key ranks higher. For equal sizes, the earlier path ranks higher.
#[derive(Eq, Ord, PartialEq, PartialOrd)]
struct Rank {
    bytes: u128,
    path: Reverse<PathBuf>,
    id: NodeId,
}

pub(crate) struct Tree {
    root: PathBuf,
    nodes: Vec<Node>,
    file_owners: HashMap<FileKey, NodeId>,
    link_groups: HashMap<FileKey, LinkGroup>,
    ranks: [BTreeSet<Rank>; 2],
    child_orders: Mutex<VecDeque<ChildOrder>>,
    started: Instant,
    finished: Option<Duration>,
    progress: Progress,
    pub generation: u64,
}

impl Tree {
    pub fn new(root: PathBuf, started: Instant) -> Self {
        let name = root.file_name().unwrap_or(root.as_os_str()).into();
        Self {
            root,
            nodes: vec![Node {
                parent: ROOT,
                name,
                data: Data::Directory(Directory::new(false)),
                sizes: Totals::default(),
                revision: 0,
            }],
            file_owners: HashMap::new(),
            link_groups: HashMap::new(),
            ranks: Default::default(),
            child_orders: Mutex::new(VecDeque::new()),
            started,
            finished: None,
            progress: Progress::default(),
            generation: 0,
        }
    }

    pub fn progress(&self, stopping: bool) -> Progress {
        let mut progress = self.progress;
        if progress.phase == Phase::Running && stopping {
            progress.phase = Phase::Stopping;
        }
        progress.elapsed = self.finished.unwrap_or_else(|| self.started.elapsed());
        progress
    }

    pub fn finish(&mut self, phase: Phase) {
        self.finished = Some(self.started.elapsed());
        self.progress.phase = phase;
        self.progress.revision += 1;
    }

    pub(crate) fn count_batched_directory(&mut self) {
        self.progress.batched_directories += 1;
    }

    pub fn path(&self, mut id: NodeId) -> Option<PathBuf> {
        let mut components = Vec::new();
        while id != ROOT {
            let node = self.nodes.get(id.0)?;
            components.push(&node.name);
            id = node.parent;
        }
        let mut path = self.root.clone();
        for name in components.into_iter().rev() {
            path.push(name);
        }
        Some(path)
    }

    pub fn find_path(&self, path: &Path) -> Option<NodeId> {
        let relative = path.strip_prefix(&self.root).ok()?;
        let mut id = ROOT;
        for name in relative.iter() {
            let Data::Directory(directory) = &self.nodes[id.0].data else {
                return None;
            };
            id = *directory
                .children
                .iter()
                .find(|child| self.nodes[child.0].name == name)?;
        }
        Some(id)
    }

    pub fn node(&self, id: NodeId) -> Option<NodeView> {
        self.nodes.get(id.0).map(|node| self.view(id, node))
    }

    pub(crate) fn children_by_name(&self, parent: NodeId) -> Vec<NodeId> {
        let Data::Directory(directory) = &self.nodes[parent.0].data else {
            return Vec::new();
        };
        let mut children = directory.children.clone();
        children.sort_unstable_by(|left, right| {
            self.nodes[left.0]
                .name
                .cmp(&self.nodes[right.0].name)
                .then(left.cmp(right))
        });
        children
    }

    pub fn children(&self, parent: NodeId) -> Option<Vec<NodeView>> {
        let Data::Directory(directory) = &self.nodes.get(parent.0)?.data else {
            return None;
        };
        Some(
            directory
                .children
                .iter()
                .map(|id| self.view(*id, &self.nodes[id.0]))
                .collect(),
        )
    }

    pub fn children_page(
        &self,
        parent: NodeId,
        metric: Metric,
        offset: usize,
        limit: usize,
    ) -> Option<ChildPage> {
        let (total, ids) = self.ordered_children(parent, metric, offset, limit)?;
        let rows = ids.into_iter().map(|id| self.node(id).unwrap()).collect();
        Some(ChildPage { total, rows })
    }

    pub(crate) fn directory_revision(&self, id: NodeId) -> Option<u64> {
        match &self.nodes.get(id.0)?.data {
            Data::Directory(directory) => Some(directory.contents_revision),
            _ => None,
        }
    }

    pub(crate) fn page_stamp(&self, ids: &[NodeId]) -> String {
        let mut stamp = String::new();
        for id in ids {
            write!(stamp, "{:x}:{:x},", id.0, self.nodes[id.0].revision).unwrap();
        }
        stamp
    }

    pub(crate) fn ordered_children(
        &self,
        parent: NodeId,
        metric: Metric,
        offset: usize,
        limit: usize,
    ) -> Option<(usize, Vec<NodeId>)> {
        let Data::Directory(directory) = &self.nodes.get(parent.0)?.data else {
            return None;
        };
        let total = directory.children.len();
        let end = offset.saturating_add(limit).min(total);
        if offset >= end {
            return Some((total, Vec::new()));
        }
        let revision = directory.order_revision[metric.index()];
        let cacheable = end <= PAGE_CACHE_ITEMS;
        let mut cache = self.child_orders.lock().unwrap();
        let previous = cacheable
            .then(|| {
                cache
                    .iter()
                    .position(|order| order.directory == parent && order.metric == metric)
            })
            .flatten()
            .and_then(|position| cache.remove(position));
        if let Some(order) =
            previous.filter(|order| order.revision == revision && order.ids.len() >= end)
        {
            let ids = order.ids[offset..end].to_vec();
            cache.push_back(order);
            return Some((total, ids));
        }
        let prefix = if cacheable {
            end.next_power_of_two().max(256).min(total)
        } else {
            end
        };
        let mut ids = directory.children.clone();
        let compare = |left: &NodeId, right: &NodeId| {
            let left = &self.nodes[left.0];
            let right = &self.nodes[right.0];
            Self::sortable_size(right, metric)
                .cmp(&Self::sortable_size(left, metric))
                .then_with(|| left.name.cmp(&right.name))
        };
        if prefix < total {
            ids.select_nth_unstable_by(prefix, compare);
            ids.truncate(prefix);
        }
        ids.sort_unstable_by(compare);
        let window = ids[offset..end].to_vec();
        if cacheable {
            // Drop the scratch capacity for wide directories before retaining their prefix.
            ids.shrink_to_fit();
            cache.push_back(ChildOrder {
                directory: parent,
                metric,
                revision,
                ids,
            });
            if cache.len() > PAGE_CACHE_SLOTS {
                cache.pop_front();
            }
        }
        Some((total, window))
    }

    fn sortable_size(node: &Node, metric: Metric) -> Option<u128> {
        match &node.data {
            Data::File(_) => {}
            Data::Directory(directory)
                if matches!(directory.coverage, Coverage::Complete | Coverage::Partial) => {}
            _ => return None,
        }
        let size = node.sizes.size(metric);
        (size.unknown_files == 0 || size.bytes > 0).then_some(size.bytes)
    }

    pub fn top_files(&self, metric: Metric) -> Vec<(PathBuf, NodeView)> {
        self.ranks[metric.index()]
            .iter()
            .rev()
            .map(|rank| {
                (
                    rank.path.0.clone(),
                    self.view(rank.id, &self.nodes[rank.id.0]),
                )
            })
            .collect()
    }

    pub fn add_batch(
        &mut self,
        parent: NodeId,
        entries: Vec<(OsString, EntryKind)>,
        pending: &mut VecDeque<NodeId>,
    ) {
        let revision = self.progress.revision + 1;
        let directory = self.directory_mut(parent);
        let changed_coverage = directory.coverage != Coverage::Partial;
        directory.coverage = Coverage::Partial;
        directory.contents_revision = revision;
        directory.order_revision = [revision; 2];
        if changed_coverage {
            self.touch_row(parent, [true; 2]);
        }
        let mut delta = Totals::default();
        let mut collisions = Vec::new();
        for (name, entry) in entries {
            let id = NodeId(self.nodes.len());
            let is_file = matches!(&entry, EntryKind::File(_));
            let mut sizes = Totals::default();
            let mut deferred_link = None;
            let data = match entry {
                EntryKind::Directory { placeholder } => {
                    pending.push_back(id);
                    self.directory_mut(parent).open_children += 1;
                    Data::Directory(Directory::new(placeholder))
                }
                EntryKind::File(file) => {
                    self.progress.files += 1;
                    sizes.logical = Size::from_file(file.logical);
                    if let Some(key) = file.identity.filter(|_| file.linked) {
                        if !self.file_owners.contains_key(&key)
                            && !self.link_groups.contains_key(&key)
                        {
                            // Keep singleton files in the compact owner map so batch accumulation
                            // avoids per-file ancestor updates on Windows NTFS batch enumeration.
                            self.file_owners.insert(key, id);
                            sizes.allocated = Size::from_file(file.allocated);
                        } else {
                            deferred_link = Some((key, file.allocated));
                        }
                    } else {
                        sizes.allocated = Size::from_file(file.allocated);
                    }
                    Data::File(file)
                }
                EntryKind::Link(target) => Data::Link(target),
                EntryKind::Mount(target) => Data::Mount(target),
                EntryKind::Other => Data::Other,
                EntryKind::SkippedDirectory { placeholder } => {
                    self.progress.skipped_directories += 1;
                    self.directory_mut(parent).open_children += 1;
                    Data::SkippedDirectory { placeholder }
                }
                EntryKind::Unavailable => {
                    self.progress.unavailable_entries += 1;
                    self.directory_mut(parent).open_children += 1;
                    Data::Unavailable
                }
            };
            self.nodes.push(Node {
                parent,
                name,
                data,
                sizes,
                revision,
            });
            self.directory_mut(parent).children.push(id);
            delta += sizes;

            if is_file {
                self.insert_rank(id, Metric::Logical, sizes.logical.known_value());
                if let Some((key, allocated)) = deferred_link {
                    collisions.push((id, key, allocated));
                } else {
                    self.insert_rank(id, Metric::Allocated, sizes.allocated.known_value());
                }
            }
        }
        let mut ancestor = parent;
        loop {
            self.nodes[ancestor.0].sizes += delta;
            if delta != Totals::default() {
                self.touch_row(
                    ancestor,
                    [
                        delta.allocated != Size::default(),
                        delta.logical != Size::default(),
                    ],
                );
            }
            if ancestor == ROOT {
                break;
            }
            ancestor = self.nodes[ancestor.0].parent;
        }
        for (id, key, allocated) in collisions {
            self.add_link(id, key, allocated);
        }
        self.progress.entries = self.nodes.len() - 1;
        let elapsed = self.started.elapsed();
        self.progress.first_rows.get_or_insert(elapsed);
        if parent != ROOT {
            self.progress
                .first_browsable_directory
                .get_or_insert(elapsed);
        }
        self.progress.revision += 1;
    }

    pub fn listing_ended(&mut self, id: NodeId, end: ListingEnd) {
        let was = self.directory_mut(id).coverage;
        let directory = self.directory_mut(id);
        if matches!(
            directory.end,
            Some(ListingEnd::Incomplete | ListingEnd::Unreadable | ListingEnd::Missing)
        ) {
            return;
        }
        directory.end = Some(end);
        match end {
            ListingEnd::Listed => {
                directory.coverage = Coverage::Partial;
                self.complete_ancestors(id);
            }
            ListingEnd::Unreadable | ListingEnd::Missing => {
                directory.coverage = Coverage::Unreadable;
                self.progress.skipped_directories += 1;
            }
            ListingEnd::Incomplete => {
                directory.coverage = Coverage::Partial;
                self.progress.skipped_directories += 1;
            }
            ListingEnd::Interrupted => directory.coverage = Coverage::Partial,
            ListingEnd::NotStarted => {}
        }
        if self.directory_mut(id).coverage != was {
            self.touch_row(id, [true; 2]);
        }
        self.progress.revision += 1;
    }

    #[cfg(windows)]
    pub(crate) fn listing_failed(&mut self, mut id: NodeId, unreadable: bool) {
        let complete = self.directory_mut(id).coverage == Coverage::Complete;
        let end = if unreadable && self.directory_mut(id).children.is_empty() {
            ListingEnd::Unreadable
        } else {
            ListingEnd::Incomplete
        };
        self.listing_ended(id, end);
        if complete {
            while id != ROOT {
                id = self.nodes[id.0].parent;
                let parent = self.directory_mut(id);
                parent.open_children += 1;
                if parent.coverage != Coverage::Complete {
                    break;
                }
                parent.coverage = Coverage::Partial;
                self.touch_row(id, [true; 2]);
            }
            self.progress.revision += 1;
        }
    }

    pub fn replace_subtree(
        &self,
        selected: NodeId,
        fresh: &Tree,
        stop: &AtomicBool,
    ) -> Option<Self> {
        // ponytail: rebuild the in-memory totals and ranking after refresh. This keeps
        // only the top 100 during scanning. Incremental indexes can avoid a second tree
        // if large sessions hit a memory limit.
        let mut rebuilt = Self::new(self.root.clone(), self.started);
        rebuilt.generation = self.generation + 1;
        let mut fresh_files = HashMap::<FileKey, FileSizes>::new();
        for node in &fresh.nodes {
            if let Data::File(file) = node.data
                && let Some(key) = file.identity
                && (file.linked
                    || self.link_groups.contains_key(&key)
                    || self.file_owners.contains_key(&key))
            {
                fresh_files
                    .entry(key)
                    .and_modify(|known| {
                        known.logical = known.logical.or(file.logical);
                        known.allocated = known.allocated.or(file.allocated);
                    })
                    .or_insert(file);
            }
        }
        let missing = matches!(fresh.root_listing(), Some(ListingEnd::Missing));
        let mut directories = VecDeque::from([(self, ROOT, ROOT)]);
        let mut pending = VecDeque::new();
        while let Some((source, old_id, new_id)) = directories.pop_front() {
            let Data::Directory(directory) = &source.nodes[old_id.0].data else {
                continue;
            };
            for chunk in directory.children.chunks(BATCH_SIZE) {
                if stop.load(Ordering::Relaxed) {
                    return None;
                }
                let nodes: Vec<_> = chunk
                    .iter()
                    .filter_map(|id| {
                        if std::ptr::eq(source, self) && *id == selected {
                            (!missing).then_some((fresh, ROOT))
                        } else {
                            Some((source, *id))
                        }
                    })
                    .collect();
                if nodes.is_empty() {
                    continue;
                }
                let start = rebuilt.nodes.len();
                let entries = nodes
                    .iter()
                    .map(|(tree, id)| {
                        let node = &tree.nodes[id.0];
                        let kind = match &node.data {
                            Data::Directory(dir) => EntryKind::Directory {
                                placeholder: dir.placeholder,
                            },
                            Data::File(file) => {
                                let mut file = *file;
                                if let Some(key) = file.identity {
                                    if let Some(updated) = fresh_files.get(&key) {
                                        file.logical = updated.logical;
                                        file.allocated = updated.allocated;
                                    }
                                    file.linked |= self.link_groups.contains_key(&key)
                                        || fresh.link_groups.contains_key(&key)
                                        || fresh_files.contains_key(&key);
                                }
                                EntryKind::File(file)
                            }
                            Data::Link(target) => EntryKind::Link(target.clone()),
                            Data::Mount(target) => EntryKind::Mount(target.clone()),
                            Data::Other => EntryKind::Other,
                            Data::SkippedDirectory { placeholder } => EntryKind::SkippedDirectory {
                                placeholder: *placeholder,
                            },
                            Data::Unavailable => EntryKind::Unavailable,
                        };
                        (node.name.clone(), kind)
                    })
                    .collect();
                rebuilt.add_batch(new_id, entries, &mut pending);
                pending.clear();
                for (index, (tree, id)) in nodes.into_iter().enumerate() {
                    if matches!(tree.nodes[id.0].data, Data::Directory(_)) {
                        directories.push_back((tree, id, NodeId(start + index)));
                    }
                }
            }
            if let Some(end) = directory.end {
                rebuilt.listing_ended(new_id, end);
            }
        }
        if stop.load(Ordering::Relaxed) {
            None
        } else {
            Some(rebuilt)
        }
    }

    fn root_listing(&self) -> Option<ListingEnd> {
        let Data::Directory(directory) = &self.nodes[ROOT.0].data else {
            unreachable!("root is a directory");
        };
        directory.end
    }

    pub fn release_contents(&mut self) -> Self {
        let mut progress_only = Self::new(self.root.clone(), self.started);
        progress_only.progress = self.progress;
        progress_only.finished = self.finished;
        std::mem::replace(self, progress_only)
    }

    fn view(&self, id: NodeId, node: &Node) -> NodeView {
        let mut view = NodeView {
            id,
            parent: (id != ROOT).then_some(node.parent),
            #[cfg(windows)]
            name: crate::wsl::node_name(&self.root, &node.name),
            #[cfg(not(windows))]
            name: node.name.clone(),
            kind: NodeKind::Other,
            coverage: Coverage::Excluded,
            sizes: None,
            target: None,
            shared_with: None,
            placeholder: false,
        };
        match &node.data {
            Data::Directory(directory) => {
                view.kind = NodeKind::Directory;
                view.coverage = directory.coverage;
                view.placeholder = directory.placeholder;
                if matches!(directory.coverage, Coverage::Complete | Coverage::Partial) {
                    view.sizes = Some(node.sizes);
                }
            }
            Data::File(file) => {
                view.kind = NodeKind::File;
                view.coverage = Coverage::Complete;
                view.sizes = Some(node.sizes);
                view.placeholder = file.placeholder;
                view.shared_with = file
                    .identity
                    .and_then(|key| self.link_groups.get(&key))
                    .map(|group| group.owner)
                    .filter(|owner| *owner != id);
            }
            Data::Link(target) => {
                view.kind = NodeKind::Link;
                view.target.clone_from(target);
            }
            Data::Mount(target) => {
                view.kind = NodeKind::Mount;
                view.target.clone_from(target);
            }
            Data::Other => {}
            Data::SkippedDirectory { placeholder } => {
                view.kind = NodeKind::Directory;
                view.coverage = Coverage::Unreadable;
                view.placeholder = *placeholder;
            }
            Data::Unavailable => {
                view.kind = NodeKind::Unknown;
                view.coverage = Coverage::Unreadable;
            }
        }
        view
    }

    fn directory_mut(&mut self, id: NodeId) -> &mut Directory {
        let Data::Directory(directory) = &mut self.nodes[id.0].data else {
            unreachable!("only directories are queued or receive children");
        };
        directory
    }

    fn touch_row(&mut self, id: NodeId, order: [bool; 2]) {
        let revision = self.progress.revision + 1;
        self.nodes[id.0].revision = revision;
        if id != ROOT {
            let parent = self.nodes[id.0].parent;
            let directory = self.directory_mut(parent);
            directory.contents_revision = revision;
            for (version, changed) in directory.order_revision.iter_mut().zip(order) {
                if changed {
                    *version = revision;
                }
            }
        }
    }

    fn complete_ancestors(&mut self, mut id: NodeId) {
        loop {
            let directory = self.directory_mut(id);
            if !matches!(directory.end, Some(ListingEnd::Listed)) || directory.open_children != 0 {
                break;
            }
            directory.coverage = Coverage::Complete;
            self.touch_row(id, [true; 2]);
            if id == ROOT {
                break;
            }
            id = self.nodes[id.0].parent;
            self.directory_mut(id).open_children -= 1;
        }
    }

    fn add_link(&mut self, id: NodeId, key: FileKey, observed: Option<u64>) {
        let existing = self.link_groups.remove(&key).or_else(|| {
            let owner = self.file_owners.remove(&key)?;
            let allocated = match self.nodes[owner.0].data {
                Data::File(file) => file.allocated,
                _ => None,
            };
            Some(LinkGroup {
                owner,
                allocated,
                aliases: Vec::new(),
            })
        });
        if let Some(mut group) = existing {
            let previous_owner = group.owner;
            let previous_size = group.allocated;
            if self.path(id) < self.path(group.owner) {
                self.remove_rank(group.owner, Metric::Allocated, group.allocated);
                self.replace_allocation(group.owner, Size::default());
                for &alias in &group.aliases {
                    self.touch_row(alias, [false; 2]);
                }
                self.touch_row(group.owner, [false; 2]);
                group.aliases.push(group.owner);
                group.owner = id;
            } else {
                group.aliases.push(id);
            }
            group.allocated = group.allocated.or(observed);
            if group.owner != previous_owner || group.allocated != previous_size {
                self.replace_allocation(group.owner, Size::from_file(group.allocated));
                self.insert_rank(
                    group.owner,
                    Metric::Allocated,
                    group.allocated.map(u128::from),
                );
            }
            self.link_groups.insert(key, group);
        } else {
            self.file_owners.insert(key, id);
            self.replace_allocation(id, Size::from_file(observed));
            self.insert_rank(id, Metric::Allocated, observed.map(u128::from));
        }
    }

    fn replace_allocation(&mut self, mut id: NodeId, size: Size) {
        let previous = self.nodes[id.0].sizes.allocated;
        if previous == size {
            return;
        }
        loop {
            let node = &mut self.nodes[id.0];
            let parent = node.parent;
            node.sizes.allocated.bytes = node.sizes.allocated.bytes - previous.bytes + size.bytes;
            node.sizes.allocated.unknown_files =
                node.sizes.allocated.unknown_files - previous.unknown_files + size.unknown_files;
            self.touch_row(id, [true, false]);
            if id == ROOT {
                break;
            }
            id = parent;
        }
    }

    fn insert_rank(&mut self, id: NodeId, metric: Metric, bytes: Option<u128>) {
        let Some(bytes) = bytes else { return };
        let rank = &self.ranks[metric.index()];
        if rank.len() == TOP_LIMIT && rank.first().is_some_and(|last| bytes < last.bytes) {
            return;
        }
        let candidate = Rank {
            bytes,
            path: Reverse(self.path(id).unwrap()),
            id,
        };
        let rank = &mut self.ranks[metric.index()];
        if rank.len() < TOP_LIMIT || rank.first().is_some_and(|last| &candidate > last) {
            rank.insert(candidate);
            if rank.len() > TOP_LIMIT {
                rank.pop_first();
            }
        }
    }

    fn remove_rank(&mut self, id: NodeId, metric: Metric, bytes: Option<u64>) {
        if let Some(bytes) = bytes {
            let candidate = Rank {
                bytes: bytes.into(),
                path: Reverse(self.path(id).unwrap()),
                id,
            };
            self.ranks[metric.index()].remove(&candidate);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_stamps_keep_unaffected_windows_and_directories() {
        let mut tree = Tree::new(PathBuf::from("root"), Instant::now());
        let mut pending = VecDeque::new();
        let directory = || EntryKind::Directory { placeholder: false };
        let file = |bytes| {
            EntryKind::File(FileSizes {
                allocated: Some(bytes),
                logical: Some(bytes),
                identity: None,
                linked: false,
                placeholder: false,
            })
        };
        tree.add_batch(
            ROOT,
            vec![("left".into(), directory()), ("right".into(), directory())],
            &mut pending,
        );
        let left = pending.pop_front().unwrap();
        let right = pending.pop_front().unwrap();
        tree.add_batch(
            left,
            vec![("large".into(), file(100)), ("small".into(), directory())],
            &mut pending,
        );
        let small = pending.pop_front().unwrap();
        tree.add_batch(small, vec![("before".into(), file(1))], &mut pending);
        let stamps = |tree: &Tree, metric| {
            let (_, order) = tree.ordered_children(left, metric, 0, 2).unwrap();
            assert_eq!(tree.node(order[0]).unwrap().name, "large");
            (tree.page_stamp(&order[..1]), tree.page_stamp(&order[1..]))
        };
        let before = stamps(&tree, Metric::Allocated);
        let unchanged = tree.directory_revision(right);
        let changed = tree.directory_revision(left);
        tree.add_batch(small, vec![("after".into(), file(1))], &mut pending);
        let after = stamps(&tree, Metric::Allocated);
        assert_eq!(before.0, after.0);
        assert_ne!(before.1, after.1);
        assert_eq!(tree.directory_revision(right), unchanged);
        assert_ne!(tree.directory_revision(left), changed);
        assert_eq!(stamps(&tree, Metric::Logical), after);

        tree.add_batch(small, vec![("largest".into(), file(100))], &mut pending);
        let (_, order) = tree
            .ordered_children(left, Metric::Allocated, 0, 2)
            .unwrap();
        assert_eq!(order[0], small);
    }

    #[test]
    fn interruption_preserves_partial_and_pending_sizes() {
        let mut tree = Tree::new(PathBuf::from("root"), Instant::now());
        let mut pending = VecDeque::new();
        tree.add_batch(
            ROOT,
            vec![
                ("seen".into(), EntryKind::Directory { placeholder: false }),
                (
                    "pending".into(),
                    EntryKind::Directory { placeholder: false },
                ),
            ],
            &mut pending,
        );
        let seen = pending.pop_front().unwrap();
        let unvisited = pending.pop_front().unwrap();
        tree.listing_ended(ROOT, ListingEnd::Listed);
        tree.add_batch(
            seen,
            vec![(
                "metadata-only".into(),
                EntryKind::File(FileSizes {
                    logical: Some(20),
                    allocated: None,
                    identity: None,
                    linked: false,
                    placeholder: true,
                }),
            )],
            &mut pending,
        );
        tree.listing_ended(seen, ListingEnd::Interrupted);
        tree.finish(Phase::Cancelled);

        assert_eq!(tree.node(seen).unwrap().coverage, Coverage::Partial);
        let unvisited = tree.node(unvisited).unwrap();
        assert_eq!(unvisited.coverage, Coverage::Pending);
        assert!(unvisited.sizes.is_none());
        let root = tree.node(ROOT).unwrap();
        assert_eq!(root.coverage, Coverage::Partial);
        let sizes = root.sizes.unwrap();
        assert_eq!(sizes.logical.known_value(), Some(20));
        assert_eq!(sizes.allocated.known_value(), None);
        assert!(tree.top_files(Metric::Allocated).is_empty());
    }

    #[test]
    fn batch_singletons_stay_compact_and_same_batch_links_promote_cleanly() {
        let mut tree = Tree::new(PathBuf::from("root"), Instant::now());
        let mut pending = VecDeque::new();
        let singleton_key = FileKey {
            volume: 1,
            index: [1; 16],
        };
        let shared_key = FileKey {
            volume: 1,
            index: [2; 16],
        };
        let linked_file = |allocated, key| {
            EntryKind::File(FileSizes {
                allocated,
                logical: Some(1024),
                identity: Some(key),
                linked: true,
                placeholder: false,
            })
        };
        tree.add_batch(
            ROOT,
            vec![
                ("solo.bin".into(), linked_file(Some(8192), singleton_key)),
                ("z-link.bin".into(), linked_file(None, shared_key)),
                ("m-link.bin".into(), linked_file(Some(4096), shared_key)),
                ("a-link.bin".into(), linked_file(Some(4096), shared_key)),
            ],
            &mut pending,
        );
        assert!(tree.file_owners.contains_key(&singleton_key));
        assert!(!tree.link_groups.contains_key(&singleton_key));
        assert!(!tree.file_owners.contains_key(&shared_key));
        assert!(tree.link_groups.contains_key(&shared_key));

        let root = tree.node(ROOT).unwrap().sizes.unwrap();
        assert_eq!(root.allocated.known_value(), Some(8192 + 4096));
        assert_eq!(root.logical.known_value(), Some(4 * 1024));

        let (_, ordered) = tree
            .ordered_children(ROOT, Metric::Allocated, 0, 10)
            .unwrap();
        assert_eq!(tree.node(ordered[0]).unwrap().name, "solo.bin");
        assert_eq!(tree.node(ordered[1]).unwrap().name, "a-link.bin");
        assert_eq!(tree.node(ordered[1]).unwrap().shared_with, None);
        assert_eq!(tree.node(ordered[2]).unwrap().shared_with, Some(ordered[1]));
        assert_eq!(tree.node(ordered[3]).unwrap().shared_with, Some(ordered[1]));

        let top = tree.top_files(Metric::Allocated);
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].1.name, "solo.bin");
        assert_eq!(top[1].1.name, "a-link.bin");
    }

    #[test]
    fn replace_subtree_handles_cross_boundary_link_addition_and_removal() {
        let mut tree = Tree::new(PathBuf::from("root"), Instant::now());
        let mut pending = VecDeque::new();
        let key = FileKey {
            volume: 7,
            index: [9; 16],
        };
        let file = |linked| {
            EntryKind::File(FileSizes {
                allocated: Some(4096),
                logical: Some(512),
                identity: Some(key),
                linked,
                placeholder: false,
            })
        };
        tree.add_batch(
            ROOT,
            vec![
                ("a".into(), EntryKind::Directory { placeholder: false }),
                ("z-original".into(), file(false)),
            ],
            &mut pending,
        );
        let dir_a = pending.pop_front().unwrap();
        tree.listing_ended(ROOT, ListingEnd::Listed);
        tree.listing_ended(dir_a, ListingEnd::Listed);

        let mut fresh_add = Tree::new(PathBuf::from("root/a"), Instant::now());
        let mut fp = VecDeque::new();
        fresh_add.add_batch(ROOT, vec![("alias".into(), file(true))], &mut fp);
        fresh_add.listing_ended(ROOT, ListingEnd::Listed);

        let with_link = tree
            .replace_subtree(dir_a, &fresh_add, &AtomicBool::new(false))
            .unwrap();
        assert!(with_link.link_groups.contains_key(&key));
        assert_eq!(
            with_link
                .node(ROOT)
                .unwrap()
                .sizes
                .unwrap()
                .allocated
                .known_value(),
            Some(4096)
        );
        let orig_id = with_link
            .find_path(&Path::new("root").join("z-original"))
            .unwrap();
        let alias_id = with_link
            .find_path(&Path::new("root").join("a").join("alias"))
            .unwrap();
        assert_eq!(with_link.node(orig_id).unwrap().shared_with, Some(alias_id));

        let mut fresh_remove = Tree::new(PathBuf::from("root/a"), Instant::now());
        fresh_remove.listing_ended(ROOT, ListingEnd::Listed);
        let dir_a_with_link = with_link.find_path(&Path::new("root").join("a")).unwrap();
        let without_link = with_link
            .replace_subtree(dir_a_with_link, &fresh_remove, &AtomicBool::new(false))
            .unwrap();
        assert!(without_link.link_groups.is_empty());
        assert!(without_link.file_owners.contains_key(&key));
        let orig_id = without_link
            .find_path(&Path::new("root").join("z-original"))
            .unwrap();
        assert_eq!(without_link.node(orig_id).unwrap().shared_with, None);
        assert_eq!(
            without_link
                .node(ROOT)
                .unwrap()
                .sizes
                .unwrap()
                .allocated
                .known_value(),
            Some(4096)
        );
    }
}
