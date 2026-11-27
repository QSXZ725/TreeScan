use super::{EntryKind, FileKey, FileSizes};
use std::ffi::OsString;
use std::fs::{self, DirEntry};
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

#[cfg(any(target_os = "linux", target_os = "android"))]
use std::{collections::HashMap, os::unix::ffi::OsStringExt};

pub(crate) struct Adapter {
    device: u64,
    #[cfg(any(target_os = "linux", target_os = "android"))]
    mounts: HashMap<PathBuf, PathBuf>,
}

impl Adapter {
    pub fn prepare(path: &Path) -> io::Result<(PathBuf, Self)> {
        let path = fs::canonicalize(path)?;
        let metadata = fs::symlink_metadata(&path)?;
        if !metadata.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "select a directory",
            ));
        }

        let adapter = Self {
            device: metadata.dev(),
            #[cfg(any(target_os = "linux", target_os = "android"))]
            mounts: mount_points(&path),
        };
        Ok((path, adapter))
    }

    pub fn list(
        &self,
        path: &Path,
    ) -> io::Result<(
        impl Iterator<Item = io::Result<(OsString, EntryKind)>> + '_,
        bool,
    )> {
        self.check_directory(path)?;
        Ok((
            fs::read_dir(path)?
                .map(|entry| entry.map(|entry| (entry.file_name(), self.inspect(&entry)))),
            false,
        ))
    }

    pub fn check_directory(&self, path: &Path) -> io::Result<()> {
        #[cfg(any(target_os = "linux", target_os = "android"))]
        if self.mounts.keys().any(|mount| path.starts_with(mount)) {
            return Err(io::Error::other("directory is on another mount"));
        }
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.is_dir() || metadata.dev() != self.device {
            return Err(io::Error::other("directory changed before enumeration"));
        }
        Ok(())
    }

    fn inspect(&self, entry: &DirEntry) -> EntryKind {
        // Linux bind mounts can have the same device number as the parent.
        #[cfg(any(target_os = "linux", target_os = "android"))]
        if !self.mounts.is_empty()
            && let Some(source) = self.mounts.get(&entry.path())
        {
            return EntryKind::Mount(Some(source.clone()));
        }

        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(_) if entry.file_type().is_ok_and(|kind| kind.is_dir()) => {
                return EntryKind::SkippedDirectory { placeholder: false };
            }
            Err(_) => return EntryKind::Unavailable,
        };
        if metadata.file_type().is_symlink() {
            EntryKind::Link(fs::read_link(entry.path()).ok())
        } else if metadata.dev() != self.device {
            EntryKind::Mount(mount_source(entry.path()))
        } else if metadata.is_dir() {
            EntryKind::Directory { placeholder: false }
        } else if metadata.is_file() {
            EntryKind::File(FileSizes {
                logical: Some(metadata.len()),
                allocated: metadata.blocks().checked_mul(512),
                identity: Some(FileKey {
                    volume: metadata.dev(),
                    index: u128::from(metadata.ino()).to_le_bytes(),
                }),
                linked: metadata.nlink() > 1,
                placeholder: false,
            })
        } else {
            EntryKind::Other
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn mount_points(root: &Path) -> HashMap<PathBuf, PathBuf> {
    let Ok(contents) = fs::read("/proc/self/mountinfo") else {
        return HashMap::new();
    };
    contents
        .split(|byte| *byte == b'\n')
        .filter_map(|line| {
            let mut fields = line.split(|byte| *byte == b' ');
            let mount = mount_path(fields.nth(4)?);
            if mount == root || !mount.starts_with(root) {
                return None;
            }
            fields.find(|field| *field == b"-")?;
            let source = mount_path(fields.nth(1)?);
            Some((mount, source))
        })
        .collect()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn mount_path(mut field: &[u8]) -> PathBuf {
    let mut decoded = Vec::with_capacity(field.len());
    while let Some((&byte, rest)) = field.split_first() {
        if let (b'\\', [a @ b'0'..=b'3', b @ b'0'..=b'7', c @ b'0'..=b'7', tail @ ..]) =
            (byte, rest)
        {
            decoded.push((a - b'0') * 64 + (b - b'0') * 8 + (c - b'0'));
            field = tail;
        } else {
            decoded.push(byte);
            field = rest;
        }
    }
    std::ffi::OsString::from_vec(decoded).into()
}

#[cfg(target_os = "macos")]
fn mount_source(path: PathBuf) -> Option<PathBuf> {
    use std::ffi::{CStr, CString, OsStr};
    use std::mem::MaybeUninit;
    use std::os::unix::ffi::OsStrExt;

    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut info = MaybeUninit::<libc::statfs>::uninit();
    // statfs writes the structure and terminates f_mntfromname on success.
    if unsafe { libc::statfs(path.as_ptr(), info.as_mut_ptr()) } != 0 {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let source = unsafe { CStr::from_ptr(info.f_mntfromname.as_ptr()) };
    Some(OsStr::from_bytes(source.to_bytes()).into())
}

#[cfg(not(target_os = "macos"))]
fn mount_source(_: PathBuf) -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[test]
    fn decodes_linux_mount_paths() {
        assert_eq!(mount_path(b"/mnt/a\\040b\\134c"), Path::new("/mnt/a b\\c"));
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn marks_a_native_mount_as_a_boundary() {
        let name = if cfg!(target_os = "linux") {
            "proc"
        } else {
            "dev"
        };
        let (root, adapter) = Adapter::prepare(Path::new("/")).unwrap();
        let (entries, _) = adapter.list(&root).unwrap();
        let (_, mount) = entries
            .filter_map(Result::ok)
            .find(|(entry_name, _)| entry_name == name)
            .unwrap();
        assert!(matches!(mount, EntryKind::Mount(Some(_))));
        let mount = root.join(name);
        let (selected, adapter) = Adapter::prepare(&mount).unwrap();
        assert!(adapter.list(&selected).is_ok());
    }
}
