use crate::{Coverage, NodeKind, Phase, ROOT, Size, display_path, tree::Tree};
use serde_json::{Value, json, to_writer};
use std::fmt::Write as _;
use std::io::{self, Write};
use std::path::Path;

pub(crate) fn write(tree: &Tree, mut output: impl Write) -> io::Result<()> {
    let root = tree.path(ROOT).unwrap();
    let phase = match tree.progress(false).phase {
        Phase::Running => "running",
        Phase::Stopping => "stopping",
        Phase::Complete => "complete",
        Phase::Cancelled => "cancelled",
        Phase::Failed => "failed",
    };
    output.write_all(b"{\"format\":\"treescan-snapshot\",\"formatVersion\":1,\"platform\":")?;
    to_writer(&mut output, std::env::consts::OS)?;
    output.write_all(b",\"root\":")?;
    to_writer(&mut output, &display_path(&root))?;
    if let Some(raw) = native_path(&root) {
        output.write_all(b",\"rawRoot\":")?;
        to_writer(&mut output, &raw)?;
    }
    output.write_all(b",\"phase\":")?;
    to_writer(&mut output, phase)?;
    output.write_all(b",\"entries\":[\n")?;

    let mut pending = vec![ROOT];
    while let Some(id) = pending.pop() {
        if id != ROOT {
            output.write_all(b",\n")?;
        }
        let node = tree.node(id).unwrap();
        let path = tree.path(id).unwrap();
        let relative = path.strip_prefix(&root).unwrap();
        let (path, raw_path) = relative_path(&root, relative);
        let kind = match node.kind {
            NodeKind::Directory => "directory",
            NodeKind::File => "file",
            NodeKind::Link => "link",
            NodeKind::Mount => "mount",
            NodeKind::Other => "other",
            NodeKind::Unknown => "unknown",
        };
        let coverage = match node.coverage {
            Coverage::Pending => "pending",
            Coverage::Partial => "partial",
            Coverage::Complete => "complete",
            Coverage::Unreadable => "unreadable",
            Coverage::Excluded => "excluded",
        };
        let mut entry = json!({
            "path": path, "kind": kind, "coverage": coverage,
            "allocated": node.sizes.map(|sizes| size(sizes.allocated)),
            "logical": node.sizes.map(|sizes| size(sizes.logical)),
            "placeholder": node.placeholder,
        });
        if let Some(raw) = raw_path {
            entry["rawPath"] = raw;
        }
        to_writer(&mut output, &entry)?;
        pending.extend(tree.children_by_name(id).into_iter().rev());
    }
    output.write_all(b"\n]}\n")
}

fn size(value: Size) -> Value {
    json!({ "bytes": value.bytes.to_string(), "unknownFiles": value.unknown_files })
}

fn relative_path(_root: &Path, path: &Path) -> (String, Option<Value>) {
    if path.as_os_str().is_empty() {
        return (".".into(), None);
    }
    #[cfg(windows)]
    if let Some(bytes) = crate::wsl::snapshot_path(_root, path) {
        let raw = std::str::from_utf8(&bytes)
            .is_err()
            .then(|| byte_path(&bytes));
        return (String::from_utf8_lossy(&bytes).into_owned(), raw);
    }
    (
        path.iter()
            .map(|name| name.to_string_lossy())
            .collect::<Vec<_>>()
            .join("/"),
        native_path(path),
    )
}

fn native_path(path: &Path) -> Option<Value> {
    let name = path.as_os_str();
    if name.to_str().is_some() {
        return None;
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let mut text = String::new();
        for unit in name.encode_wide() {
            write!(text, "{unit:04x}").unwrap();
        }
        Some(json!({ "encoding": "utf16-hex", "value": text }))
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        Some(byte_path(name.as_bytes()))
    }
}

fn byte_path(bytes: &[u8]) -> Value {
    let mut text = String::with_capacity(2 * bytes.len());
    for byte in bytes {
        write!(text, "{byte:02x}").unwrap();
    }
    json!({ "encoding": "unix-bytes-hex", "value": text })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::{EntryKind, FileSizes};
    use crate::tree::ListingEnd;
    use std::collections::VecDeque;
    use std::path::PathBuf;
    use std::time::Instant;

    #[test]
    fn snapshot_has_stable_paths_wide_sizes_and_unreadable_entries() {
        let mut tree = Tree::new(PathBuf::from("example"), Instant::now());
        tree.add_batch(
            ROOT,
            vec![
                (
                    "z".into(),
                    EntryKind::File(FileSizes {
                        logical: Some(u64::MAX),
                        allocated: Some(4096),
                        identity: None,
                        linked: false,
                        placeholder: false,
                    }),
                ),
                (
                    "a".into(),
                    EntryKind::SkippedDirectory { placeholder: true },
                ),
            ],
            &mut VecDeque::new(),
        );
        tree.listing_ended(ROOT, ListingEnd::Listed);
        tree.finish(Phase::Complete);
        let mut encoded = Vec::new();
        write(&tree, &mut encoded).unwrap();
        let data: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(data["formatVersion"], 1);
        assert_eq!(data["entries"][0]["coverage"], "partial");
        assert_eq!(data["entries"][1]["path"], "a");
        assert_eq!(data["entries"][1]["coverage"], "unreadable");
        assert!(data["entries"][1]["allocated"].is_null());
        assert_eq!(data["entries"][2]["logical"]["bytes"], u64::MAX.to_string());
        assert_eq!(data["entries"][2]["allocated"]["bytes"], "4096");
    }
}
