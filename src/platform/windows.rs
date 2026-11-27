use super::{EntryKind, FileKey, FileSizes};
use std::ffi::OsString;
use std::fs::{self, DirEntry, File, OpenOptions};
use std::io;
use std::mem::{offset_of, size_of};
use std::os::windows::{
    ffi::{OsStrExt, OsStringExt},
    fs::{MetadataExt, OpenOptionsExt},
    io::AsRawHandle,
};
use std::path::{self, Component, Path, PathBuf, Prefix};
use windows_sys::Win32::Foundation::ERROR_NO_MORE_FILES;
use windows_sys::Win32::Storage::{CloudFilters::*, FileSystem::*};
use windows_sys::Win32::System::SystemServices::{
    IO_REPARSE_TAG_CLOUD, IO_REPARSE_TAG_CLOUD_MASK, IO_REPARSE_TAG_MOUNT_POINT,
};
use windows_sys::Win32::System::WindowsProgramming::{DRIVE_FIXED, DRIVE_REMOVABLE};

const NAME_SURROGATE: u32 = 0x2000_0000;
const REMOTE_ATTRIBUTES: u32 =
    FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_OPEN | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;

pub(crate) struct Adapter {
    batch_metadata: bool,
}

impl Adapter {
    pub fn prepare(path: &Path) -> io::Result<(PathBuf, Self)> {
        let path = path::absolute(path)?;
        let file = metadata_handle(&path)?;
        let info: FILE_ATTRIBUTE_TAG_INFO = query(&file, FileAttributeTagInfo)?;
        if info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
            || info.ReparseTag & NAME_SURROGATE != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "select a directory or the direct target of the link",
            ));
        }
        Ok((
            path,
            Self {
                batch_metadata: false,
            },
        ))
    }

    pub fn with_batch_metadata(mut self, path: &Path, requested: bool) -> Self {
        self.batch_metadata = requested && local_ntfs(path);
        self
    }

    pub fn list(
        &self,
        path: &Path,
    ) -> io::Result<(
        impl Iterator<Item = io::Result<(OsString, EntryKind)>> + '_,
        bool,
    )> {
        if self.batch_metadata
            && let Ok(directory) = BatchDirectory::open(path)
        {
            return Ok((Listed::Batch(directory), true));
        }
        self.check_directory(path)?;
        Ok((Listed::Native(Box::new(fs::read_dir(path)?)), false))
    }

    pub fn check_directory(&self, path: &Path) -> io::Result<()> {
        check_directory(&metadata_handle(path)?)
    }
}

enum Listed {
    Native(Box<fs::ReadDir>),
    Batch(BatchDirectory),
}

impl Iterator for Listed {
    type Item = io::Result<(OsString, EntryKind)>;

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Self::Native(directory) => directory
                .next()
                .map(|entry| entry.map(|entry| (entry.file_name(), inspect(&entry)))),
            Self::Batch(directory) => directory.next(),
        }
    }
}

fn check_directory(file: &File) -> io::Result<()> {
    let info: FILE_ATTRIBUTE_TAG_INFO = query(file, FileAttributeTagInfo)?;
    if info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
        || !matches!(
            directory_kind(info.FileAttributes, info.ReparseTag),
            EntryKind::Directory { .. }
        )
    {
        return Err(io::Error::other(
            "directory is redirected or not available locally",
        ));
    }
    Ok(())
}

fn inspect(entry: &DirEntry) -> EntryKind {
    let Ok(metadata) = entry.metadata() else {
        return EntryKind::Unavailable;
    };
    inspect_path(
        || entry.path(),
        metadata.file_attributes(),
        metadata.file_size(),
        metadata.is_symlink(),
    )
}

fn inspect_path(
    path: impl FnOnce() -> PathBuf,
    attributes: u32,
    logical: u64,
    is_symlink: bool,
) -> EntryKind {
    let is_directory = attributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    if attributes & FILE_ATTRIBUTE_DEVICE != 0 {
        return EntryKind::Other;
    }
    if attributes & FILE_ATTRIBUTE_RECALL_ON_OPEN != 0 && !is_symlink {
        return if is_directory {
            EntryKind::SkippedDirectory { placeholder: true }
        } else {
            file_kind(logical, true, None, None, false)
        };
    }
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT == 0 {
        if is_directory {
            return directory_kind(attributes, 0);
        }
        if attributes & REMOTE_ATTRIBUTES != 0 {
            return file_kind(logical, true, None, None, false);
        }
        return match metadata_handle(&path()) {
            Ok(file) => ordinary_file(logical, attributes, &file),
            Err(_) => file_kind(logical, false, None, None, false),
        };
    }

    let path = path();
    let file = metadata_handle(&path).ok();
    let tag = file.as_ref().and_then(|file| {
        query::<FILE_ATTRIBUTE_TAG_INFO>(file, FileAttributeTagInfo)
            .ok()
            .map(|info| info.ReparseTag)
    });
    if is_symlink || tag.is_some_and(|tag| tag & NAME_SURROGATE != 0) {
        let target = fs::read_link(path).ok();
        return if tag == Some(IO_REPARSE_TAG_MOUNT_POINT)
            && target.as_deref().is_some_and(is_volume_path)
        {
            EntryKind::Mount(target)
        } else {
            EntryKind::Link(target)
        };
    }
    if is_directory {
        return tag.map_or(EntryKind::SkippedDirectory { placeholder: false }, |tag| {
            directory_kind(attributes, tag)
        });
    }
    if let Some(file) = file.as_ref().filter(|_| tag.is_some_and(is_cloud_tag)) {
        let links = query::<FILE_STANDARD_INFO>(file, FileStandardInfo)
            .ok()
            .map(|info| info.NumberOfLinks);
        let identity = file_key(file);
        let allocated = if identity.is_some() || links == Some(1) {
            cloud_allocation(file)
        } else {
            None
        };
        return file_kind(logical, true, allocated, identity, links != Some(1));
    }
    if tag.is_some() || attributes & REMOTE_ATTRIBUTES != 0 {
        file_kind(
            logical,
            attributes & REMOTE_ATTRIBUTES != 0,
            None,
            None,
            false,
        )
    } else {
        EntryKind::Unavailable
    }
}

fn local_ntfs(path: &Path) -> bool {
    let Some(Component::Prefix(prefix)) = path.components().next() else {
        return false;
    };
    if !matches!(
        prefix.kind(),
        Prefix::Disk(_) | Prefix::VerbatimDisk(_) | Prefix::Verbatim(_)
    ) {
        return false;
    }
    let root: Vec<_> = prefix
        .as_os_str()
        .encode_wide()
        .chain([b'\\'.into(), 0])
        .collect();
    if !matches!(
        unsafe { GetDriveTypeW(root.as_ptr()) },
        DRIVE_FIXED | DRIVE_REMOVABLE
    ) {
        return false;
    }
    let Ok(file) = metadata_handle(path) else {
        return false;
    };
    let mut filesystem = [0u16; 16];
    let mut flags = 0;
    let success = unsafe {
        GetVolumeInformationByHandleW(
            file.as_raw_handle(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut flags,
            filesystem.as_mut_ptr(),
            filesystem.len() as u32,
        )
    };
    success != 0 && filesystem.starts_with(&[b'N'.into(), b'T'.into(), b'F'.into(), b'S'.into(), 0])
}

struct BatchDirectory {
    path: PathBuf,
    file: File,
    volume: u64,
    buffer: Box<[u64]>,
    next: Option<usize>,
    exhausted: bool,
}

impl BatchDirectory {
    fn open(path: &Path) -> io::Result<Self> {
        let file = open_metadata(path, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY)?;
        check_directory(&file)?;
        let volume = file_key(&file)
            .ok_or_else(|| io::Error::other("no stable directory identity"))?
            .volume;
        let mut directory = Self {
            path: path.to_owned(),
            file,
            volume,
            buffer: vec![0; 64 * 1024 / size_of::<u64>()].into_boxed_slice(),
            next: None,
            exhausted: false,
        };
        // A filesystem or filter can reject extended metadata. Only fall back
        // before yielding any rows so a retry cannot count the same entries twice.
        directory.read_buffer()?;
        Ok(directory)
    }

    fn read_buffer(&mut self) -> io::Result<()> {
        let bytes = size_of::<u64>() * self.buffer.len();
        let success = unsafe {
            GetFileInformationByHandleEx(
                self.file.as_raw_handle(),
                FileIdExtdDirectoryInfo,
                self.buffer.as_mut_ptr().cast(),
                bytes as u32,
            )
        };
        if success != 0 {
            self.next = Some(0);
            return Ok(());
        }
        self.exhausted = true;
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_NO_MORE_FILES as i32) {
            Ok(())
        } else {
            Err(error)
        }
    }

    fn entry(&mut self, offset: usize) -> Option<(OsString, EntryKind)> {
        type Header = FILE_ID_EXTD_DIR_INFO;
        let bytes = unsafe {
            std::slice::from_raw_parts(
                self.buffer.as_ptr().cast::<u8>(),
                size_of::<u64>() * self.buffer.len(),
            )
        };
        let record = bytes.get(offset..)?;
        let read = |index| -> Option<u32> {
            Some(u32::from_le_bytes(
                record.get(index..index + 4)?.try_into().ok()?,
            ))
        };
        let size = |index| -> Option<u64> {
            i64::from_le_bytes(record.get(index..index + 8)?.try_into().ok()?)
                .try_into()
                .ok()
        };
        let next = read(offset_of!(Header, NextEntryOffset))? as usize;
        let name_len = read(offset_of!(Header, FileNameLength))? as usize;
        let name_offset = offset_of!(Header, FileName);
        let end = name_offset.checked_add(name_len)?;
        if name_len == 0
            || !name_len.is_multiple_of(2)
            || (next != 0 && (next < end || next >= record.len()))
        {
            return None;
        }
        let name = record
            .get(name_offset..end)?
            .as_chunks::<2>()
            .0
            .iter()
            .copied()
            .map(u16::from_le_bytes)
            .collect::<Vec<_>>();
        let name = OsString::from_wide(&name);
        self.next = (next != 0).then_some(offset + next);
        if name == "." || name == ".." {
            return Some((name, EntryKind::Other));
        }
        let attributes = read(offset_of!(Header, FileAttributes))?;
        let logical = size(offset_of!(Header, EndOfFile)).unwrap_or_default();
        let tag = read(offset_of!(Header, ReparsePointTag))?;
        let index: [u8; 16] = record
            .get(offset_of!(Header, FileId)..)?
            .get(..16)?
            .try_into()
            .ok()?;
        let kind = if attributes
            & (FILE_ATTRIBUTE_SPARSE_FILE
                | FILE_ATTRIBUTE_COMPRESSED
                | FILE_ATTRIBUTE_REPARSE_POINT
                | FILE_ATTRIBUTE_DEVICE
                | REMOTE_ATTRIBUTES)
            != 0
            || index == [0; 16]
        {
            inspect_path(
                || self.path.join(&name),
                attributes,
                logical,
                tag & NAME_SURROGATE != 0,
            )
        } else if attributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
            directory_kind(attributes, tag)
        } else {
            file_kind(
                logical,
                false,
                size(offset_of!(Header, AllocationSize)),
                Some(FileKey {
                    volume: self.volume,
                    index,
                }),
                true,
            )
        };
        Some((name, kind))
    }
}

impl Iterator for BatchDirectory {
    type Item = io::Result<(OsString, EntryKind)>;

    fn next(&mut self) -> Option<Self::Item> {
        while !self.exhausted {
            if self.next.is_none()
                && let Err(error) = self.read_buffer()
            {
                return Some(Err(error));
            }
            let offset = self.next?;
            match self.entry(offset) {
                Some((name, _)) if name == "." || name == ".." => continue,
                Some(entry) => return Some(Ok(entry)),
                None => {
                    self.exhausted = true;
                    return Some(Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "invalid directory metadata record",
                    )));
                }
            }
        }
        None
    }
}

fn is_cloud_tag(tag: u32) -> bool {
    tag & !IO_REPARSE_TAG_CLOUD_MASK == IO_REPARSE_TAG_CLOUD
}

fn is_volume_path(path: &Path) -> bool {
    matches!(
        path.components().next(),
        Some(Component::Prefix(prefix)) if matches!(
            prefix.kind(),
            Prefix::Verbatim(volume) if volume.as_encoded_bytes().get(..7)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case(b"Volume{"))
        )
    )
}

fn directory_kind(attributes: u32, tag: u32) -> EntryKind {
    let cloud = is_cloud_tag(tag);
    if tag & NAME_SURROGATE != 0
        || (attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 && !cloud)
        || attributes & REMOTE_ATTRIBUTES != 0
        // Do not let enumeration initiate on-demand population of a cloud directory.
        || (cloud && unsafe { CfGetPlaceholderStateFromAttributeTag(attributes, tag) }
            & CF_PLACEHOLDER_STATE_PARTIAL != 0)
    {
        EntryKind::SkippedDirectory {
            placeholder: cloud || attributes & REMOTE_ATTRIBUTES != 0,
        }
    } else {
        EntryKind::Directory { placeholder: cloud }
    }
}

fn metadata_handle(path: &Path) -> io::Result<File> {
    open_metadata(path, FILE_READ_ATTRIBUTES)
}

fn open_metadata(path: &Path, access: u32) -> io::Result<File> {
    OpenOptions::new()
        .access_mode(access)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_OPEN_NO_RECALL,
        )
        .open(path)
}

fn query<T: Default>(file: &File, class: FILE_INFO_BY_HANDLE_CLASS) -> io::Result<T> {
    let mut output = T::default();
    // Each caller pairs the information class with its matching Win32 structure.
    let ok = unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            class,
            (&mut output as *mut T).cast(),
            size_of::<T>() as u32,
        )
    };
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(output)
    }
}

fn ordinary_file(logical: u64, attributes: u32, file: &File) -> EntryKind {
    let Ok(info) = query::<FILE_STANDARD_INFO>(file, FileStandardInfo) else {
        return file_kind(logical, false, None, file_key(file), true);
    };
    let identity = file_key(file);
    let linked = info.NumberOfLinks > 1;
    let allocated = if linked && identity.is_none() {
        None
    } else if attributes & (FILE_ATTRIBUTE_SPARSE_FILE | FILE_ATTRIBUTE_COMPRESSED) != 0 {
        query::<FILE_COMPRESSION_INFO>(file, FileCompressionInfo)
            .ok()
            .and_then(|info| info.CompressedFileSize.try_into().ok())
    } else {
        info.AllocationSize.try_into().ok()
    };
    file_kind(logical, false, allocated, identity, linked)
}

fn file_key(file: &File) -> Option<FileKey> {
    let info: FILE_ID_INFO = query(file, FileIdInfo).ok()?;
    (info.FileId.Identifier != [0; 16]).then_some(FileKey {
        volume: info.VolumeSerialNumber,
        index: info.FileId.Identifier,
    })
}

fn cloud_allocation(file: &File) -> Option<u64> {
    const BUFFER_LEN: usize = (size_of::<CF_PLACEHOLDER_STANDARD_INFO>()
        + CF_PLACEHOLDER_MAX_FILE_IDENTITY_LENGTH as usize)
        .div_ceil(size_of::<i64>());
    let mut buffer = [0i64; BUFFER_LEN];
    // The aligned, writable buffer fits the fixed header and the maximum identity blob.
    let result = unsafe {
        CfGetPlaceholderInfo(
            file.as_raw_handle(),
            CF_PLACEHOLDER_INFO_STANDARD,
            buffer.as_mut_ptr().cast(),
            size_of::<[i64; BUFFER_LEN]>() as u32,
            std::ptr::null_mut(),
        )
    };
    if result == 0 {
        buffer[0].try_into().ok()
    } else {
        None
    }
}

fn file_kind(
    logical: u64,
    placeholder: bool,
    allocated: Option<u64>,
    identity: Option<FileKey>,
    linked: bool,
) -> EntryKind {
    EntryKind::File(FileSizes {
        logical: Some(logical),
        allocated,
        identity,
        linked,
        placeholder,
    })
}
