use crate::{Metric, NodeId, NodeView, Phase, ROOT, Scan, ScanOptions, Size, snapshot};
use serde_json::{Value, json};
use std::ffi::{CString, c_char};
use std::fs::{OpenOptions, remove_file, rename};
use std::io::{self, BufWriter, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr;
use std::slice;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Default)]
struct Session {
    scan: Option<Scan>,
    refreshing: bool,
    stop_requested: Option<Duration>,
}

/// The caller owns the returned session and must release it with treescan_close.
#[unsafe(no_mangle)]
extern "C" fn treescan_open() -> *mut Session {
    Box::into_raw(Box::new(Session::default()))
}

/// Requests and responses are UTF-8 JSON. One isolate owns the session and serializes calls.
#[unsafe(no_mangle)]
unsafe extern "C" fn treescan_request(
    session: *mut Session,
    request: *const u8,
    length: usize,
) -> *mut c_char {
    if session.is_null() || request.is_null() {
        return ptr::null_mut();
    }
    // Dart keeps the request buffer alive and exclusively owns the session.
    let input = unsafe { slice::from_raw_parts(request, length) };
    let session = unsafe { &mut *session };
    let reply = catch_unwind(AssertUnwindSafe(|| {
        match serde_json::from_slice(input)
            .map_err(io::Error::other)
            .and_then(|request| session.request(request))
        {
            Ok(value) => json!({ "value": value }),
            Err(error) => json!({ "error": error.to_string() }),
        }
    }))
    .unwrap_or_else(|_| {
        *session = Session::default();
        json!({ "error": "scan request failed" })
    });
    CString::new(reply.to_string()).unwrap().into_raw()
}

#[unsafe(no_mangle)]
unsafe extern "C" fn treescan_free_reply(reply: *mut c_char) {
    if !reply.is_null() {
        // This pointer comes from CString::into_raw in treescan_request.
        drop(unsafe { CString::from_raw(reply) });
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn treescan_close(session: *mut Session) {
    if !session.is_null() {
        // Closing requests cancellation through Scan::drop.
        drop(unsafe { Box::from_raw(session) });
    }
}

impl Session {
    fn request(&mut self, request: Value) -> io::Result<Value> {
        let action = request["op"]
            .as_str()
            .ok_or_else(|| invalid("missing operation"))?;
        #[cfg(windows)]
        if action == "smart" {
            return crate::smart::disks().map(Value::Array);
        }
        let metric = if request["logical"] == true {
            Metric::Logical
        } else {
            Metric::Allocated
        };
        let id = NodeId(
            request["id"]
                .as_u64()
                .and_then(|id| id.try_into().ok())
                .unwrap_or(0),
        );
        if action == "start" {
            let path = request["path"]
                .as_str()
                .filter(|path| !path.is_empty())
                .ok_or_else(|| invalid("select a directory"))?;
            let mut options = ScanOptions::default();
            if let Some(workers) = request["workers"].as_u64() {
                options.workers = workers
                    .try_into()
                    .map_err(|_| invalid("invalid worker count"))?;
            }
            let scan = Scan::start_with_wsl_user(path, options, request["wslRoot"] == true)?;
            let path = scan.path(ROOT).unwrap();
            self.scan = Some(scan);
            self.refreshing = false;
            self.stop_requested = None;
            return Ok(json!({ "root": path.to_string_lossy() }));
        }

        let scan = self
            .scan
            .as_mut()
            .ok_or_else(|| invalid("no active session"))?;
        if action == "refresh" {
            if request["generation"].as_u64() != Some(scan.generation()) {
                return Ok(Value::Null);
            }
            scan.rescan(id)?;
            self.refreshing = true;
            self.stop_requested = None;
            return Ok(json!(true));
        }
        if action == "stop" {
            self.stop_requested.get_or_insert(scan.progress().elapsed);
            scan.stop();
            return Ok(json!(true));
        }
        if action == "poll" {
            let progress = scan.progress();
            let results = scan.results.tree.read().unwrap();
            let current = results.progress(false);
            let directories: Vec<_> = request["directories"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|entry| {
                    let id = entry.as_u64()?.try_into().ok()?;
                    results.directory_revision(NodeId(id))
                })
                .collect();
            return Ok(json!({
                "phase": format!("{:?}", progress.phase),
                "refreshing": self.refreshing && !progress.phase.is_finished(),
                "generation": results.generation,
                "revision": current.revision,
                "directoryRevisions": directories,
                "files": current.files,
                "skipped": current.skipped_directories,
                "unavailable": current.unavailable_entries,
                "operationFiles": progress.files,
                "elapsedMs": ms(progress.elapsed),
                "firstRowsMs": progress.first_rows.map(ms),
                "firstDirectoryMs": progress.first_browsable_directory.map(ms),
                "stopDrainMs": self.stop_requested.filter(|_| progress.phase == Phase::Cancelled)
                    .map(|requested| ms(progress.elapsed.saturating_sub(requested))),
                "error": scan.last_error(),
                "root": results.node(ROOT).map(|node| row(node, results.path(ROOT).as_deref())),
            }));
        }

        let tree = scan.results.tree.read().unwrap();
        if request["generation"].as_u64() != Some(tree.generation) {
            return Ok(Value::Null);
        }
        match action {
            "visiblePages" => {
                let limit = request["limit"]
                    .as_u64()
                    .and_then(|limit| limit.try_into().ok())
                    .unwrap_or(crate::tree::PAGE_LENGTH);
                let Some((total, ids)) = tree.ordered_children(id, metric, 0, limit) else {
                    return Ok(Value::Null);
                };
                let stamps = request["stamps"].as_array();
                let pages: Vec<_> = ids
                    .chunks(crate::tree::PAGE_LENGTH)
                    .enumerate()
                    .map(|(index, ids)| {
                        let stamp = tree.page_stamp(ids);
                        let known = stamps
                            .and_then(|stamps| stamps.get(index))
                            .and_then(Value::as_str);
                        let rows = (known != Some(stamp.as_str())).then(|| {
                            ids.iter()
                                .map(|id| row(tree.node(*id).unwrap(), None))
                                .collect::<Vec<_>>()
                        });
                        json!({ "stamp": stamp, "rows": rows })
                    })
                    .collect();
                Ok(
                    json!({ "total": total, "revision": tree.directory_revision(id), "pages": pages }),
                )
            }
            "page" => {
                let offset = request["offset"]
                    .as_u64()
                    .and_then(|count| count.try_into().ok())
                    .unwrap_or_default();
                let limit = request["limit"].as_u64().unwrap_or(100).clamp(1, 256) as usize;
                Ok(tree.children_page(id, metric, offset, limit).map_or(Value::Null, |page| {
                    json!({
                        "total": page.total,
                        "rows": page.rows.into_iter().map(|node| row(node, None)).collect::<Vec<_>>(),
                    })
                }))
            }
            "top" => Ok(Value::Array(
                tree.top_files(metric)
                    .into_iter()
                    .map(|(path, node)| row(node, Some(&path)))
                    .collect(),
            )),
            "node" => Ok(tree
                .node(id)
                .map_or(Value::Null, |node| row(node, tree.path(id).as_deref()))),
            "find" => {
                let mut path = Path::new(
                    request["path"]
                        .as_str()
                        .ok_or_else(|| invalid("missing path"))?,
                );
                let nearest = request["nearest"] == true;
                loop {
                    if let Some(id) = tree.find_path(path) {
                        return Ok(tree
                            .node(id)
                            .map_or(Value::Null, |node| row(node, Some(path))));
                    }
                    match path.parent().filter(|_| nearest) {
                        Some(parent) => path = parent,
                        None => break,
                    }
                }
                Ok(Value::Null)
            }
            "export" => {
                let path = request["path"]
                    .as_str()
                    .filter(|path| !path.is_empty())
                    .ok_or_else(|| invalid("missing export path"))?;
                export_tree(&tree, Path::new(path))?;
                Ok(json!(true))
            }
            _ => Err(invalid("unknown operation")),
        }
    }
}

fn export_tree(tree: &crate::tree::Tree, path: &Path) -> io::Result<()> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let pending = path.with_file_name(format!(".treescan-{}-{stamp}.tmp", std::process::id()));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending)?;
    let write = || -> io::Result<()> {
        let mut output = BufWriter::new(file);
        snapshot::write(tree, &mut output)?;
        output.flush()?;
        drop(output);
        rename(&pending, path)
    };
    let result = write();
    if result.is_err() {
        let _ = remove_file(pending);
    }
    result
}

fn row(node: NodeView, path: Option<&Path>) -> Value {
    #[cfg(windows)]
    let shell_accessible = path.is_none_or(crate::wsl::shell_path);
    #[cfg(not(windows))]
    let shell_accessible = true;
    json!({
        "id": node.id.0,
        "parent": node.parent.map(|parent| parent.0),
        "name": node.name.to_string_lossy(),
        "kind": format!("{:?}", node.kind),
        "coverage": format!("{:?}", node.coverage),
        "sizes": node.sizes.map(|sizes| json!({
            "allocated": size(sizes.allocated),
            "logical": size(sizes.logical),
        })),
        "target": node.target.as_ref().map(|target| target.to_string_lossy()),
        "sharedWith": node.shared_with.map(|id| id.0),
        "placeholder": node.placeholder,
        "path": path.map(|path| path.to_string_lossy()),
        "displayPath": path.map(crate::display_path),
        "shellAccessible": shell_accessible,
    })
}

fn size(size: Size) -> Value {
    json!({ "bytes": size.bytes.to_string(), "unknown": size.unknown_files })
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
