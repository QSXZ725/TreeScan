use std::path::PathBuf;

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

#[cfg(unix)]
pub(crate) use unix::Adapter;
#[cfg(windows)]
pub(crate) use windows::Adapter;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct FileKey {
    pub volume: u64,
    pub index: [u8; 16],
}

#[derive(Clone, Copy)]
pub(crate) struct FileSizes {
    pub logical: Option<u64>,
    pub allocated: Option<u64>,
    pub identity: Option<FileKey>,
    pub linked: bool,
    pub placeholder: bool,
}

pub(crate) enum EntryKind {
    Directory { placeholder: bool },
    File(FileSizes),
    Link(Option<PathBuf>),
    Mount(Option<PathBuf>),
    Other,
    SkippedDirectory { placeholder: bool },
    Unavailable,
}
