use crate::platform::{EntryKind, FileKey, FileSizes};
use crate::tree::ListingEnd;
use crate::{BATCH_INTERVAL, BATCH_SIZE, NodeId, NodeKind, ROOT, Shared};
use std::borrow::Cow;
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::{OsStr, OsString};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::windows::process::CommandExt;
use std::path::{Component, Path, PathBuf, Prefix, PrefixComponent};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};
use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

pub(crate) struct Location {
    distro: OsString,
    linux_path: Vec<u8>,
    as_root: bool,
}

fn distribution(path: &Path) -> Option<(PrefixComponent<'_>, &OsStr)> {
    let Component::Prefix(prefix) = path.components().next()? else {
        return None;
    };
    let (host, distro) = match prefix.kind() {
        Prefix::UNC(host, distro) | Prefix::VerbatimUNC(host, distro) => (host, distro),
        _ => return None,
    };
    (host.eq_ignore_ascii_case("wsl.localhost") || host.eq_ignore_ascii_case("wsl$"))
        .then_some((prefix, distro))
}

impl Location {
    pub fn prepare(
        path: &Path,
        refresh: bool,
        as_root: bool,
    ) -> io::Result<Option<(PathBuf, Self)>> {
        let Some((prefix, distro)) = distribution(path) else {
            return Ok(None);
        };
        let mut reference = PathBuf::from(prefix.as_os_str());
        reference.push(r"\");
        let mut linux_path = Vec::new();
        for component in path.components().skip(1) {
            match component {
                Component::RootDir | Component::CurDir => {}
                Component::Normal(name) => {
                    let name = name.to_str().ok_or_else(invalid_path)?;
                    let decoded = refresh.then(|| decode_name(name)).flatten();
                    let bytes = decoded.as_deref().unwrap_or(name.as_bytes());
                    linux_path.push(b'/');
                    linux_path.extend(bytes);
                    reference.push(encode_name(bytes));
                }
                _ => return Err(invalid_path()),
            }
        }
        if linux_path.is_empty() {
            linux_path.push(b'/');
        }
        Ok(Some((
            reference,
            Self {
                distro: distro.to_os_string(),
                linux_path,
                as_root,
            },
        )))
    }

    fn command(&self) -> Command {
        let system = std::env::var_os("SystemRoot")
            .map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from);
        let mut command = Command::new(system.join(r"System32\wsl.exe"));
        command
            .creation_flags(CREATE_NO_WINDOW)
            .arg("--distribution")
            .arg(&self.distro);
        if self.as_root {
            command.args(["--user", "root"]);
        }
        command.arg("--exec");
        command
    }
}

// Windows paths hold the tree's references. Escape Linux-only names so a
// backslash or a drive prefix cannot change the node's parent or shell target.
const ESCAPE: char = '\u{e000}';

fn encode_name(bytes: &[u8]) -> OsString {
    if let Ok(name) = std::str::from_utf8(bytes)
        && windows_name(name)
    {
        return name.into();
    }
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut escaped = String::with_capacity(3 + 2 * bytes.len());
    escaped.push(ESCAPE);
    for &byte in bytes {
        escaped.push(char::from(HEX[(byte >> 4) as usize]));
        escaped.push(char::from(HEX[(byte & 15) as usize]));
    }
    escaped.into()
}

fn windows_name(name: &str) -> bool {
    let device = name
        .split('.')
        .next()
        .unwrap()
        .trim_end()
        .to_ascii_uppercase();
    if matches!(
        device.as_str(),
        "CON" | "PRN" | "NUL" | "AUX" | "CONIN$" | "CONOUT$"
    ) || ["COM", "LPT"].into_iter().any(|prefix| {
        device.strip_prefix(prefix).is_some_and(|suffix| {
            matches!(
                suffix,
                "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            )
        })
    }) {
        return false;
    }
    !name.starts_with(ESCAPE)
        && !name.ends_with(['.', ' '])
        && !name.contains(['<', '>', ':', '"', '/', '\\', '|', '?', '*'])
        && !name.bytes().any(|byte| byte < 32)
}

fn decode_name(name: &str) -> Option<Vec<u8>> {
    let hex = name.strip_prefix(ESCAPE)?;
    if hex.is_empty() || hex.len() % 2 != 0 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    (0..hex.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).ok())
        .collect()
}

pub(crate) fn node_name(root: &Path, name: &OsStr) -> OsString {
    if distribution(root).is_some()
        && let Some(raw) = name.to_str().and_then(decode_name)
    {
        return String::from_utf8_lossy(&raw).into_owned().into();
    }
    name.to_os_string()
}

pub(crate) fn snapshot_path(root: &Path, relative: &Path) -> Option<Vec<u8>> {
    distribution(root)?;
    let mut output = Vec::new();
    for part in relative.iter() {
        let part = part.to_str()?;
        if !output.is_empty() {
            output.push(b'/');
        }
        if let Some(bytes) = decode_name(part) {
            output.extend(bytes);
        } else {
            output.extend_from_slice(part.as_bytes());
        }
    }
    Some(output)
}

pub(crate) fn shell_path(path: &Path) -> bool {
    distribution(path).is_none() || path.components().skip(1).all(|component| {
        !matches!(component, Component::Normal(name) if name.to_str().is_some_and(|name| name.starts_with(ESCAPE)))
    })
}

pub(crate) fn display_path(path: &Path) -> Cow<'_, str> {
    if shell_path(path) {
        return path.to_string_lossy();
    }
    let (prefix, _) = distribution(path).unwrap();
    let mut value = prefix.as_os_str().to_string_lossy().into_owned();
    for component in path.components().skip(1) {
        if let Component::Normal(name) = component {
            value.push('\\');
            value.push_str(&node_name(path, name).to_string_lossy());
        }
    }
    Cow::Owned(value)
}

fn invalid_path() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "select a directory in the WSL distribution",
    )
}

pub(crate) fn scan(location: &Location, shared: &Shared) -> io::Result<()> {
    let mut command = location.command();
    // A single WSL process reads the mounts and traverses the disk. Paths
    // travel as bytes on stdin, never as text in the shell script.
    command.args([
        "/bin/sh", "-c",
        r"cat /proc/self/mountinfo || exit; printf '\000'; exec env LC_ALL=C QUOTING_STYLE=shell-escape-always xargs -0 -r -x -n 1048576 -- find",
    ]);

    let (status, (writer, startup), error) = run(command, &shared.stop, |input, mut arguments| {
        let mut header = Vec::new();
        input.read_until(0, &mut header)?;
        if header.last() != Some(&0) || !header.first().is_some_and(u8::is_ascii_digit) {
            drop(arguments);
            input.take(8192).read_to_end(&mut header)?;
            return Ok((None, header));
        }
        header.pop();
        let mounts = mount_points(&header, &location.linux_path)?;
        if let Err(error) = arguments.write_all(&find_arguments(&location.linux_path, &mounts)) {
            if error.kind() == io::ErrorKind::BrokenPipe {
                return Ok((None, Vec::new()));
            }
            return Err(error);
        }
        drop(arguments);
        let mut writer = Writer::new(shared, mounts, &location.linux_path);
        let mut fields: [Vec<u8>; 8] = Default::default();
        while !shared.stop.load(Ordering::Relaxed) {
            match read_record(input, &mut fields) {
                Ok(true) => writer.record(&fields)?,
                Ok(false) => break,
                Err(_) if shared.stop.load(Ordering::Relaxed) => break,
                Err(error) => return Err(error),
            }
        }
        Ok((Some(writer), Vec::new()))
    })?;
    if shared.stop.load(Ordering::Relaxed) {
        if let Some(mut writer) = writer
            && writer.started
        {
            writer.apply_errors(&error);
            writer.finish(ListingEnd::Interrupted);
        }
        return Ok(());
    }
    let Some(mut writer) = writer.filter(|writer| writer.started) else {
        return Err(wsl_error(
            if error.sample.is_empty() {
                &startup
            } else {
                &error.sample
            },
            "Could not read the WSL directory (GNU findutils is required)",
        ));
    };
    let mapped = writer.apply_errors(&error);
    if status.success() || (mapped && !error.unmapped) {
        writer.finish(ListingEnd::Listed);
    } else {
        writer.finish(ListingEnd::Incomplete);
    }
    if !status.success() {
        *shared.error.lock().unwrap() =
            Some(wsl_error(&error.sample, "WSL returned partial results").to_string());
    }
    Ok(())
}

fn find_arguments(path: &[u8], mounts: &HashMap<Vec<u8>, PathBuf>) -> Vec<u8> {
    let mut arguments = Vec::new();
    let mut add = |value: &[u8]| {
        arguments.extend_from_slice(value);
        arguments.push(0);
    };
    for option in [b"-P".as_slice(), path, b"-xdev", b"-ignore_readdir_race"] {
        add(option);
    }
    if !mounts.is_empty() {
        add(b"(");
        add(b"(");
        for (index, mount) in mounts.keys().enumerate() {
            if index != 0 {
                add(b"-o");
            }
            add(b"-path");
            add(&glob_literal(mount));
        }
        for option in [
            b")".as_slice(),
            b"-printf",
            br"M\0%P\0%s\0%b\0%D\0%i\0%n\0%l\0",
            b"-prune",
            b")",
            b"-o",
        ] {
            add(option);
        }
    }
    for option in [
        b"(".as_slice(),
        b"-type",
        b"d",
        b"!",
        b"(",
        b"-readable",
        b"-a",
        b"-executable",
        b")",
        b"-printf",
        br"U\0%P\0%s\0%b\0%D\0%i\0%n\0%l\0",
        b"-prune",
        b")",
        b"-o",
        b"-printf",
        br"%y\0%P\0%s\0%b\0%D\0%i\0%n\0%l\0",
    ] {
        add(option);
    }
    arguments
}

fn run<T: Send>(
    mut command: Command,
    stop: &AtomicBool,
    read: impl FnOnce(
        &mut BufReader<std::process::ChildStdout>,
        std::process::ChildStdin,
    ) -> io::Result<T>
    + Send,
) -> io::Result<(ExitStatus, T, Diagnostics)> {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    thread::scope(|scope| {
        let data =
            scope.spawn(move || read(&mut BufReader::with_capacity(64 * 1024, stdout), stdin));
        let errors = scope.spawn(move || Diagnostics::read(BufReader::new(stderr)));
        let status = loop {
            if stop.load(Ordering::Relaxed) {
                let _ = child.kill();
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            thread::sleep(Duration::from_millis(15));
        };
        let result = data
            .join()
            .map_err(|_| io::Error::other("WSL metadata reader panicked"))??;
        let errors = errors
            .join()
            .map_err(|_| io::Error::other("WSL error reader panicked"))??;
        Ok((status, result, errors))
    })
}

#[derive(Default)]
struct Diagnostics {
    sample: Vec<u8>,
    paths: HashSet<Vec<u8>>,
    unmapped: bool,
}

impl Diagnostics {
    fn read(mut input: impl BufRead) -> io::Result<Self> {
        let mut result = Self::default();
        let mut line = Vec::new();
        while input.read_until(b'\n', &mut line)? != 0 {
            result
                .sample
                .extend_from_slice(&line[..line.len().min(8192 - result.sample.len())]);
            if let Some(path) = find_error_path(&line) {
                result.paths.insert(path);
            } else if line.iter().any(|byte| !byte.is_ascii_whitespace()) {
                result.unmapped = true;
            }
            line.clear();
        }
        Ok(result)
    }
}

// GNU find quotes filenames in its C-locale diagnostics. Parse the leading
// filename, including the shell-escaped form used for control bytes.
fn find_error_path(line: &[u8]) -> Option<Vec<u8>> {
    let mut input = line
        .strip_prefix(b"find: ")
        .or_else(|| line.strip_prefix(b"/usr/bin/find: "))?;
    let mut path = Vec::new();
    loop {
        match input {
            [b'\'', rest @ ..] | [b'$', b'\'', rest @ ..] => {
                input = rest;
                loop {
                    let (&byte, rest) = input.split_first()?;
                    input = rest;
                    if byte == b'\'' {
                        break;
                    }
                    if byte != b'\\' {
                        path.push(byte);
                        continue;
                    }
                    let (&escaped, rest) = input.split_first()?;
                    input = rest;
                    path.push(match (escaped, input) {
                        (a @ b'0'..=b'3', [b @ b'0'..=b'7', c @ b'0'..=b'7', rest @ ..]) => {
                            input = rest;
                            (a - b'0') * 64 + (b - b'0') * 8 + (c - b'0')
                        }
                        (b'a', _) => 7,
                        (b'b', _) => 8,
                        (b'f', _) => 12,
                        (b'n', _) => b'\n',
                        (b'r', _) => b'\r',
                        (b't', _) => b'\t',
                        (b'v', _) => 11,
                        (byte @ (b'\\' | b'\'' | b'"'), _) => byte,
                        _ => return None,
                    });
                }
            }
            [b'\\', byte, rest @ ..] => {
                path.push(*byte);
                input = rest;
            }
            [b':', b' ', ..] if path.starts_with(b"/") => return Some(path),
            _ => return None,
        }
    }
}

fn wsl_error(bytes: &[u8], detail: &str) -> io::Error {
    let utf16 = bytes
        .iter()
        .skip(1)
        .step_by(2)
        .filter(|&&byte| byte == 0)
        .count();
    let message = if bytes.starts_with(&[255, 254]) || utf16 > bytes.len() / 16 {
        let start = if bytes.starts_with(&[255, 254]) { 2 } else { 0 };
        let units: Vec<_> = bytes[start..]
            .as_chunks::<2>()
            .0
            .iter()
            .copied()
            .map(u16::from_le_bytes)
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    };
    let message = message.trim();
    if message.is_empty() {
        io::Error::other(detail.to_owned())
    } else {
        io::Error::other(format!("{detail}: {message}"))
    }
}

fn mount_points(bytes: &[u8], root: &[u8]) -> io::Result<HashMap<Vec<u8>, PathBuf>> {
    let mut mounts = HashMap::new();
    for line in bytes.split(|byte| *byte == b'\n') {
        let mut fields = line.split(|byte| *byte == b' ');
        let Some(point) = fields.nth(4).map(decode_mount_field) else {
            continue;
        };
        if point != b"/" && (point == root || descendant(&point, root)) {
            return Err(io::Error::other(
                "the WSL directory is on another mounted filesystem",
            ));
        }
        if !descendant(root, &point) {
            continue;
        }
        let source = fields
            .find(|field| *field == b"-")
            .and_then(|_| fields.nth(1))
            .map(decode_mount_field)
            .unwrap_or_else(|| point.clone());
        mounts.insert(
            point,
            PathBuf::from(String::from_utf8_lossy(&source).into_owned()),
        );
    }
    Ok(mounts)
}

fn descendant(parent: &[u8], path: &[u8]) -> bool {
    path != parent
        && path.starts_with(parent)
        && (parent == b"/" || path.get(parent.len()) == Some(&b'/'))
}

fn decode_mount_field(mut value: &[u8]) -> Vec<u8> {
    let mut decoded = Vec::with_capacity(value.len());
    while let Some((&byte, remainder)) = value.split_first() {
        if let (b'\\', [a @ b'0'..=b'3', b @ b'0'..=b'7', c @ b'0'..=b'7', rest @ ..]) =
            (byte, remainder)
        {
            decoded.push((a - b'0') * 64 + (b - b'0') * 8 + (c - b'0'));
            value = rest;
        } else {
            decoded.push(byte);
            value = remainder;
        }
    }
    decoded
}

fn glob_literal(path: &[u8]) -> Vec<u8> {
    let mut literal = Vec::with_capacity(path.len());
    for &byte in path {
        if matches!(byte, b'\\' | b'*' | b'?' | b'[' | b']') {
            literal.push(b'\\');
        }
        literal.push(byte);
    }
    literal
}

fn read_record(input: &mut impl BufRead, fields: &mut [Vec<u8>; 8]) -> io::Result<bool> {
    for (index, field) in fields.iter_mut().enumerate() {
        field.clear();
        let len = input.read_until(0, field)?;
        if len == 0 && index == 0 {
            return Ok(false);
        }
        if field.pop() != Some(0) {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "incomplete WSL metadata record",
            ));
        }
    }
    Ok(true)
}

struct Writer<'a> {
    shared: &'a Shared,
    stack: Vec<(Vec<u8>, NodeId)>,
    batch: Vec<(OsString, EntryKind)>,
    mounts: HashMap<Vec<u8>, PathBuf>,
    base: &'a [u8],
    started: bool,
    root_device: Option<u64>,
    last: Instant,
}

impl<'a> Writer<'a> {
    fn new(shared: &'a Shared, mounts: HashMap<Vec<u8>, PathBuf>, base: &'a [u8]) -> Self {
        Self {
            shared,
            stack: vec![(Vec::new(), ROOT)],
            batch: Vec::new(),
            mounts,
            base,
            started: false,
            root_device: None,
            last: Instant::now(),
        }
    }

    fn record(&mut self, fields: &[Vec<u8>; 8]) -> io::Result<()> {
        let [kind, path, logical, allocated, device, inode, links, target] = fields;
        let kind = *kind
            .first()
            .ok_or_else(|| io::Error::other("missing WSL entry type"))?;
        let device = number(device);
        if path.is_empty() {
            self.started = true;
            self.root_device = device;
            if kind == b'U' {
                self.finish(ListingEnd::Unreadable);
            } else if kind != b'd' {
                return Err(invalid_path());
            }
            return Ok(());
        }
        let split = path.iter().rposition(|byte| *byte == b'/');
        let (parent, name) = split.map_or((&[][..], path.as_slice()), |index| {
            (&path[..index], &path[index + 1..])
        });
        while self
            .stack
            .last()
            .is_some_and(|(prefix, _)| prefix != parent)
        {
            self.flush();
            let (_, id) = self.stack.pop().unwrap();
            self.shared
                .tree
                .write()
                .unwrap()
                .listing_ended(id, ListingEnd::Listed);
        }
        if self.stack.is_empty() || !self.started {
            return Err(io::Error::other(
                "WSL metadata arrived before its directory",
            ));
        }
        let entry = if kind == b'M' || (device.is_some() && device != self.root_device) {
            let mut full = self.base.to_vec();
            if !full.ends_with(b"/") {
                full.push(b'/');
            }
            full.extend_from_slice(path);
            EntryKind::Mount(self.mounts.get(&full).cloned())
        } else {
            match kind {
                b'd' => EntryKind::Directory { placeholder: false },
                b'U' => EntryKind::SkippedDirectory { placeholder: false },
                b'l' => EntryKind::Link(Some(PathBuf::from(
                    String::from_utf8_lossy(target).into_owned(),
                ))),
                b'f' => EntryKind::File(FileSizes {
                    logical: number(logical),
                    allocated: number(allocated).and_then(|blocks| blocks.checked_mul(512)),
                    identity: device.zip(number(inode)).map(|(volume, index)| FileKey {
                        volume,
                        index: u128::from(index).to_le_bytes(),
                    }),
                    linked: number(links).is_some_and(|links| links > 1),
                    placeholder: false,
                }),
                b'?' => EntryKind::Unavailable,
                _ => EntryKind::Other,
            }
        };
        let directory = matches!(entry, EntryKind::Directory { .. });
        self.batch.push((encode_name(name), entry));
        if directory || self.batch.len() >= BATCH_SIZE || self.last.elapsed() >= BATCH_INTERVAL {
            let pending = self.flush();
            if directory {
                self.stack.push((path.clone(), *pending.back().unwrap()));
            }
        }
        Ok(())
    }

    fn flush(&mut self) -> VecDeque<NodeId> {
        let mut pending = VecDeque::new();
        if let Some((_, id)) = self.stack.last()
            && !self.batch.is_empty()
        {
            self.shared.tree.write().unwrap().add_batch(
                *id,
                std::mem::take(&mut self.batch),
                &mut pending,
            );
            self.last = Instant::now();
        }
        pending
    }

    fn finish(&mut self, status: ListingEnd) {
        self.flush();
        let mut tree = self.shared.tree.write().unwrap();
        while let Some((_, id)) = self.stack.pop() {
            tree.listing_ended(id, status);
        }
    }

    fn apply_errors(&mut self, errors: &Diagnostics) -> bool {
        self.flush();
        let mut tree = self.shared.tree.write().unwrap();
        let root = tree.path(ROOT).unwrap();
        let mut all_mapped = !errors.paths.is_empty();
        for path in &errors.paths {
            let relative = if path.as_slice() == self.base {
                &[][..]
            } else if let Some(relative) = path
                .strip_prefix(self.base)
                .filter(|relative| self.base == b"/" || relative.starts_with(b"/"))
            {
                relative.strip_prefix(b"/").unwrap_or(relative)
            } else {
                all_mapped = false;
                continue;
            };
            let mut reference = root.clone();
            for component in relative
                .split(|&byte| byte == b'/')
                .filter(|component| !component.is_empty())
            {
                reference.push(encode_name(component));
            }
            let mut pending = reference.as_path();
            loop {
                if let Some(id) = tree.find_path(pending)
                    && let Some(node) = tree
                        .node(id)
                        .filter(|node| node.kind == NodeKind::Directory)
                {
                    if node.coverage != crate::Coverage::Unreadable {
                        tree.listing_failed(id, pending == reference);
                    }
                    break;
                }
                let Some(parent) = pending.parent().filter(|parent| parent.starts_with(&root))
                else {
                    all_mapped = false;
                    break;
                };
                pending = parent;
            }
        }
        all_mapped
    }
}

fn number(value: &[u8]) -> Option<u64> {
    std::str::from_utf8(value).ok()?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attributes_late_find_errors_without_including_healthy_siblings() {
        use crate::{Coverage, tree::Tree};
        use std::sync::{Mutex, RwLock};

        let root = PathBuf::from(r"\\wsl.localhost\Ubuntu\work");
        let shared = Shared {
            tree: RwLock::new(Tree::new(root.clone(), Instant::now())),
            stop: AtomicBool::new(false),
            error: Mutex::new(None),
        };
        let mut writer = Writer::new(&shared, HashMap::new(), b"/work");
        let directory = [
            b"d".to_vec(),
            vec![],
            vec![],
            vec![],
            b"42".to_vec(),
            vec![],
            vec![],
            vec![],
        ];
        for path in [b"".as_slice(), b"bad:line\n\xff", b"healthy", b"last"] {
            let mut row = directory.clone();
            row[1] = path.to_vec();
            writer.record(&row).unwrap();
        }
        assert_eq!(
            shared
                .tree
                .read()
                .unwrap()
                .node(NodeId(1))
                .unwrap()
                .coverage,
            Coverage::Complete
        );
        let diagnostics =
            Diagnostics::read(&b"find: '/work/bad:line\\n\\377': Input/output error\n"[..])
                .unwrap();
        assert_eq!(
            find_error_path(br"find: '/work/one'\''two': Permission denied"),
            Some(b"/work/one'two".to_vec())
        );
        assert_eq!(
            find_error_path(br"/usr/bin/find: '/work/one\'two\n\377': Permission denied"),
            Some(b"/work/one'two\n\xff".to_vec())
        );
        assert!(writer.apply_errors(&diagnostics));
        writer.finish(ListingEnd::Listed);
        let tree = shared.tree.read().unwrap();
        assert_eq!(tree.node(ROOT).unwrap().coverage, Coverage::Partial);
        assert_eq!(tree.node(NodeId(1)).unwrap().coverage, Coverage::Unreadable);
        assert_eq!(tree.node(NodeId(2)).unwrap().coverage, Coverage::Complete);
        assert_eq!(tree.node(NodeId(3)).unwrap().coverage, Coverage::Complete);
        assert_eq!(tree.progress(false).skipped_directories, 1);
    }

    #[test]
    fn parses_distribution_path_and_prunes_bind_mounts() {
        let path = Path::new(r"\\wsl.localhost\Ubuntu\home\work");
        let (_, disk) = Location::prepare(path, false, false).unwrap().unwrap();
        assert_eq!(disk.distro, "Ubuntu");
        assert_eq!(disk.linux_path, b"/home/work");
        let table = b"33 2 8:0 / / rw - ext4 /dev/sda rw\n34 33 8:0 /other /home/work/a\\040b rw - ext4 /dev/sda rw\n";
        let mounts = mount_points(table, b"/home/work").unwrap();
        assert_eq!(mounts[b"/home/work/a b".as_slice()], Path::new("/dev/sda"));
        assert!(mount_points(table, b"/home/work/a b/sub").is_err());
        assert!(mount_points(table, b"/home/work/a b").is_err());
        let args = find_arguments(b"/home/work", &mounts);
        assert!(
            args.split(|byte| *byte == 0)
                .any(|arg| arg == b"/home/work/a b")
        );
    }

    #[test]
    fn streams_linux_sizes_links_and_directory_coverage() {
        use crate::{Coverage, NodeKind, tree::Tree};
        use std::sync::{Mutex, RwLock};

        let disk = PathBuf::from(r"\\wsl.localhost\Ubuntu\");
        let shared = Shared {
            tree: RwLock::new(Tree::new(disk.clone(), Instant::now())),
            stop: AtomicBool::new(false),
            error: Mutex::new(None),
        };
        let records = [
            ["d", "", "4096", "8", "42", "1", "3", ""],
            ["d", "data", "4096", "8", "42", "2", "2", ""],
            ["f", "data/sparse", "1048576", "8", "42", "3", "2", ""],
            ["f", "same-inode", "1048576", "8", "42", "3", "2", ""],
            ["l", "link", "4", "0", "42", "4", "1", "data"],
            ["M", "mounted", "4096", "8", "42", "5", "2", ""],
            ["U", "private", "4096", "8", "42", "6", "2", ""],
        ];
        let mut bytes = Vec::new();
        for entry in records {
            for field in entry {
                bytes.extend_from_slice(field.as_bytes());
                bytes.push(0);
            }
        }
        let mut input = io::Cursor::new(bytes);
        let mut writer = Writer::new(&shared, HashMap::new(), b"/");
        let mut fields = Default::default();
        while read_record(&mut input, &mut fields).unwrap() {
            writer.record(&fields).unwrap();
        }
        writer.finish(ListingEnd::Listed);
        let tree = shared.tree.read().unwrap();
        let root = tree.node(ROOT).unwrap().sizes.unwrap();
        assert_eq!(root.allocated.bytes, 4096);
        assert_eq!(root.logical.bytes, 2 * 1048576);
        let lookup = |name| {
            tree.node(tree.find_path(&disk.join(name)).unwrap())
                .unwrap()
        };
        assert!(lookup("same-inode").shared_with.is_some());
        assert_eq!(lookup("data").coverage, Coverage::Complete);
        assert_eq!(lookup("link").kind, NodeKind::Link);
        assert_eq!(lookup("mounted").kind, NodeKind::Mount);
        assert_eq!(lookup("private").coverage, Coverage::Unreadable);
    }

    #[test]
    fn accounts_for_linux_names_and_round_trips_for_refresh() {
        use crate::tree::Tree;
        use std::sync::{Mutex, RwLock};

        let root = PathBuf::from(r"\\wsl.localhost\Ubuntu\");
        let shared = Shared {
            tree: RwLock::new(Tree::new(root.clone(), Instant::now())),
            stop: AtomicBool::new(false),
            error: Mutex::new(None),
        };
        let mut writer = Writer::new(&shared, HashMap::new(), b"/");
        let records: [[&[u8]; 8]; 5] = [
            [b"d", b"", b"0", b"0", b"42", b"1", b"2", b""],
            [b"d", br"a\b", b"0", b"0", b"42", b"2", b"2", b""],
            [
                b"f",
                br"a\b/data:Zone.Identifier",
                b"9",
                b"8",
                b"42",
                b"3",
                b"1",
                b"",
            ],
            [b"f", b"\xff.txt", b"8", b"8", b"42", b"4", b"1", b""],
            [
                b"f",
                "\u{fffd}.txt".as_bytes(),
                b"7",
                b"8",
                b"42",
                b"5",
                b"1",
                b"",
            ],
        ];
        for record in records {
            writer.record(&record.map(<[u8]>::to_vec)).unwrap();
        }
        writer.finish(ListingEnd::Listed);
        let tree = shared.tree.read().unwrap();
        assert_eq!(tree.progress(false).files, 3);
        assert_eq!(tree.progress(false).unavailable_entries, 0);
        assert_eq!(
            tree.node(ROOT).unwrap().sizes.unwrap().allocated.bytes,
            3 * 4096
        );

        let folder = root.join(encode_name(br"a\b"));
        let id = tree.find_path(&folder).unwrap();
        assert_eq!(tree.node(id).unwrap().name, r"a\b");
        assert!(!shell_path(&folder));
        let (reference, refreshed) = Location::prepare(&folder, true, true).unwrap().unwrap();
        assert_eq!(reference, folder);
        assert_eq!(refreshed.linux_path, br"/a\b");
        assert!(refreshed.as_root);
        assert_ne!(
            encode_name(b"\xff.txt"),
            encode_name("\u{fffd}.txt".as_bytes())
        );
    }
}
