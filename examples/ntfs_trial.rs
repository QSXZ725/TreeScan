#[cfg(windows)]
fn main() -> std::io::Result<()> {
    windows::compare()
}

#[cfg(not(windows))]
fn main() {
    eprintln!("The NTFS volume trial runs on Windows.");
}

#[cfg(windows)]
mod windows {
    use std::collections::{HashMap, HashSet};
    use std::ffi::OsString;
    use std::fs::{self, File, OpenOptions};
    use std::io;
    use std::mem::size_of;
    use std::os::windows::{ffi::OsStringExt, fs::OpenOptionsExt, io::AsRawHandle};
    use std::path::{Component, Path, PathBuf, Prefix};
    use std::ptr;
    use std::time::Instant;
    use treescan::{Metric, ROOT, Scan, ScanOptions};
    use windows_sys::Win32::Foundation::{ERROR_HANDLE_EOF, GENERIC_READ};
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::System::{
        IO::DeviceIoControl,
        Ioctl::{FSCTL_ENUM_USN_DATA, MFT_ENUM_DATA_V0},
    };

    struct Record {
        id: u64,
        attrs: u32,
        name: OsString,
    }

    struct Candidate {
        paths: Vec<(PathBuf, u64, u64)>,
        linked: usize,
    }

    pub fn compare() -> io::Result<()> {
        let root = std::env::args_os().nth(1).ok_or_else(|| {
            io::Error::other("usage: ntfs_trial <NTFS fixture directory or drive root>")
        })?;
        let root = std::path::absolute(root)?;
        let Some(Component::Prefix(prefix)) = root.components().next() else {
            return Err(io::Error::other(
                "select a directory on a local drive letter",
            ));
        };
        let Prefix::Disk(letter) = prefix.kind() else {
            return Err(io::Error::other(
                "select a directory on a local drive letter",
            ));
        };
        let drive_root = format!("{}:\\", char::from(letter));
        let root_info = information(&metadata_handle(&root)?)?;
        let drive_info = information(&metadata_handle(Path::new(&drive_root))?)?;
        if root_info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
            || root_info.dwVolumeSerialNumber != drive_info.dwVolumeSerialNumber
        {
            return Err(io::Error::other("select a directory on the drive volume"));
        }

        // Desired access zero opens the volume for metadata control requests.
        let volume_path = format!(r"\\.\{}:", char::from(letter));
        let root_id =
            (u64::from(root_info.nFileIndexHigh) << 32) | u64::from(root_info.nFileIndexLow);
        let started = Instant::now();
        let try_access = |access| {
            let volume = OpenOptions::new()
                .access_mode(access)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
                .open(&volume_path)?;
            enumerate_records(&volume)
        };
        let mut by_parent = match try_access(0) {
            Ok(records) => records,
            Err(metadata_error) => try_access(GENERIC_READ).map_err(|error| {
                io::Error::new(error.kind(), format!(
                    "FSCTL_ENUM_USN_DATA on {drive_root}: metadata handle: {metadata_error}; read handle: {error}"
                ))
            })?,
        };
        let enumeration_time = started.elapsed();
        let started_paths = Instant::now();
        let paths = reconstruct(&root, root_id, &mut by_parent)?;
        drop(by_parent);
        let reconstruction_time = started_paths.elapsed();
        let follow_up = Instant::now();
        let candidate = query_sizes(paths)?;
        let follow_up_time = follow_up.elapsed();
        println!(
            "mft_enum_ms={} paths_ms={} metadata_ms={} candidate_ms={}",
            enumeration_time.as_millis(),
            reconstruction_time.as_millis(),
            follow_up_time.as_millis(),
            started.elapsed().as_millis()
        );

        let mut general = Scan::start(&root, ScanOptions { workers: 1 })?;
        general.wait()?;
        let progress = general.progress();
        let totals = general
            .node(ROOT)
            .and_then(|node| node.sizes)
            .ok_or_else(|| {
                io::Error::other("the reference scan does not cover the fixture root")
            })?;
        let logical: u128 = candidate.paths.iter().map(|file| u128::from(file.1)).sum();
        let allocated: u128 = candidate.paths.iter().map(|file| u128::from(file.2)).sum();
        let mut parity = candidate.paths.len() == progress.files
            && progress.skipped_directories == 0
            && progress.unavailable_entries == 0
            && totals.logical.known_value() == Some(logical)
            && totals.allocated.known_value() == Some(allocated);
        println!(
            "reference_ms={} candidate_files={} reference_files={} multi_link_records={}",
            progress.elapsed.as_millis(),
            candidate.paths.len(),
            progress.files,
            candidate.linked
        );
        println!(
            "candidate_logical={} candidate_allocated={} reference_logical={:?} reference_allocated={:?}",
            logical,
            allocated,
            totals.logical.known_value(),
            totals.allocated.known_value()
        );
        for metric in [Metric::Logical, Metric::Allocated] {
            let mut best: Vec<_> = candidate
                .paths
                .iter()
                .map(|(path, logical, allocated)| {
                    let size = if metric == Metric::Logical {
                        logical
                    } else {
                        allocated
                    };
                    (path, u128::from(*size))
                })
                .collect();
            let compare = |left: &(&PathBuf, u128), right: &(&PathBuf, u128)| {
                right.1.cmp(&left.1).then_with(|| left.0.cmp(right.0))
            };
            if best.len() > 100 {
                best.select_nth_unstable_by(100, compare);
                best.truncate(100);
            }
            best.sort_unstable_by(compare);
            let expected = general.top_files(metric);
            let matched = best.len() == expected.len()
                && best
                    .iter()
                    .zip(&expected)
                    .all(|((path, size), (expected_path, entry))| {
                        *path == expected_path
                            && entry
                                .sizes
                                .and_then(|totals| totals.size(metric).known_value())
                                == Some(*size)
                    });
            println!("rank_{metric:?}_matches={matched}");
            parity &= matched;
        }
        println!("candidate_matches_reference={parity}");
        Ok(())
    }

    fn enumerate_records(volume: &File) -> io::Result<HashMap<u64, Vec<Record>>> {
        let mut by_parent = HashMap::<u64, Vec<Record>>::new();
        let mut request = MFT_ENUM_DATA_V0 {
            StartFileReferenceNumber: 0,
            LowUsn: 0,
            HighUsn: i64::MAX,
        };
        let mut buffer = vec![0u8; 256 * 1024];
        loop {
            let mut used = 0;
            // The request structure and output buffer are retained until this synchronous call returns.
            let ok = unsafe {
                DeviceIoControl(
                    volume.as_raw_handle(),
                    FSCTL_ENUM_USN_DATA,
                    (&request as *const MFT_ENUM_DATA_V0).cast(),
                    size_of::<MFT_ENUM_DATA_V0>() as u32,
                    buffer.as_mut_ptr().cast(),
                    buffer.len() as u32,
                    &mut used,
                    ptr::null_mut(),
                )
            };
            if ok == 0 {
                let error = io::Error::last_os_error();
                return if error.raw_os_error() == Some(ERROR_HANDLE_EOF as i32) {
                    Ok(by_parent)
                } else {
                    Err(error)
                };
            }
            let header = buffer
                .get(..used as usize)
                .filter(|data| data.len() >= 8)
                .ok_or_else(bad_record)?;
            let next = u64::from_le_bytes(header[..8].try_into().unwrap());
            if next <= request.StartFileReferenceNumber {
                return Err(bad_record());
            }
            request.StartFileReferenceNumber = next;
            let mut data = &header[8..];
            while !data.is_empty() {
                let length =
                    u32::from_le_bytes(data.get(..4).ok_or_else(bad_record)?.try_into().unwrap())
                        as usize;
                let record = data
                    .get(..length)
                    .filter(|record| record.len() >= 60)
                    .ok_or_else(bad_record)?;
                if u16::from_le_bytes(record[4..6].try_into().unwrap()) != 2 {
                    return Err(io::Error::other(
                        "the trial requires NTFS USN record version 2",
                    ));
                }
                let id = u64::from_le_bytes(record[8..16].try_into().unwrap());
                let parent = u64::from_le_bytes(record[16..24].try_into().unwrap());
                let attrs = u32::from_le_bytes(record[52..56].try_into().unwrap());
                let name_bytes = u16::from_le_bytes(record[56..58].try_into().unwrap()) as usize;
                let offset = u16::from_le_bytes(record[58..60].try_into().unwrap()) as usize;
                let name = record
                    .get(offset..offset + name_bytes)
                    .filter(|name| offset >= 60 && !name.is_empty() && name.len() % 2 == 0)
                    .ok_or_else(bad_record)?;
                let wide: Vec<u16> = name
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .copied()
                    .map(u16::from_le_bytes)
                    .collect();
                if id != parent {
                    by_parent.entry(parent).or_default().push(Record {
                        id,
                        attrs,
                        name: OsString::from_wide(&wide),
                    });
                }
                data = &data[length..];
            }
        }
    }

    fn reconstruct(
        root: &Path,
        root_id: u64,
        by_parent: &mut HashMap<u64, Vec<Record>>,
    ) -> io::Result<Vec<PathBuf>> {
        let mut active = vec![(root_id, root.to_path_buf())];
        let mut visited = HashSet::from([root_id]);
        let mut files = Vec::new();
        while let Some((parent, path)) = active.pop() {
            // Enforce ordinary directory-listing permissions before considering its records.
            let current = information(&metadata_handle(&path)?)?;
            safe_attributes(current.dwFileAttributes)?;
            drop(fs::read_dir(&path)?);
            for record in by_parent.remove(&parent).unwrap_or_default() {
                safe_attributes(record.attrs)?;
                let name = Path::new(&record.name);
                if !matches!(name.components().next(), Some(Component::Normal(_)))
                    || name.components().count() != 1
                {
                    return Err(bad_record());
                }
                let child = path.join(name);
                if record.attrs & FILE_ATTRIBUTE_DIRECTORY != 0 {
                    if !visited.insert(record.id) {
                        return Err(bad_record());
                    }
                    active.push((record.id, child));
                } else {
                    files.push(child);
                }
            }
        }
        Ok(files)
    }

    fn query_sizes(paths: Vec<PathBuf>) -> io::Result<Candidate> {
        let mut candidate = Candidate {
            paths: Vec::with_capacity(paths.len()),
            linked: 0,
        };
        for path in paths {
            let file = metadata_handle(&path)?;
            let info = information(&file)?;
            safe_attributes(info.dwFileAttributes)?;
            let standard: FILE_STANDARD_INFO = get_info(&file, FileStandardInfo)?;
            if standard.NumberOfLinks > 1 {
                candidate.linked += 1;
            }
            let allocation = if info.dwFileAttributes
                & (FILE_ATTRIBUTE_SPARSE_FILE | FILE_ATTRIBUTE_COMPRESSED)
                != 0
            {
                get_info::<FILE_COMPRESSION_INFO>(&file, FileCompressionInfo)?.CompressedFileSize
            } else {
                standard.AllocationSize
            };
            candidate.paths.push((
                path,
                standard.EndOfFile.try_into().map_err(|_| bad_record())?,
                allocation.try_into().map_err(|_| bad_record())?,
            ));
        }
        Ok(candidate)
    }

    fn safe_attributes(attrs: u32) -> io::Result<()> {
        if attrs
            & (FILE_ATTRIBUTE_REPARSE_POINT
                | FILE_ATTRIBUTE_OFFLINE
                | FILE_ATTRIBUTE_RECALL_ON_OPEN
                | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS)
            != 0
        {
            Err(io::Error::other(
                "select a fixture without reparse points, mounts, or cloud placeholders",
            ))
        } else {
            Ok(())
        }
    }

    fn metadata_handle(path: &Path) -> io::Result<File> {
        OpenOptions::new()
            .access_mode(FILE_READ_ATTRIBUTES)
            .custom_flags(
                FILE_FLAG_BACKUP_SEMANTICS
                    | FILE_FLAG_OPEN_REPARSE_POINT
                    | FILE_FLAG_OPEN_NO_RECALL,
            )
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .open(path)
    }

    fn information(file: &File) -> io::Result<BY_HANDLE_FILE_INFORMATION> {
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        // The structure matches the API response and lives through this call.
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(info)
        }
    }

    fn get_info<T: Default>(file: &File, class: FILE_INFO_BY_HANDLE_CLASS) -> io::Result<T> {
        let mut info = T::default();
        // Each caller supplies the structure for the specified information class.
        let ok = unsafe {
            GetFileInformationByHandleEx(
                file.as_raw_handle(),
                class,
                (&mut info as *mut T).cast(),
                size_of::<T>() as u32,
            )
        };
        if ok == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(info)
        }
    }

    fn bad_record() -> io::Error {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "malformed NTFS enumeration record",
        )
    }
}
