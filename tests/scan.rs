use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use treescan::{Coverage, Metric, NodeId, NodeKind, NodeView, Phase, ROOT, Scan, ScanOptions};

struct Fixture {
    path: PathBuf,
    resolved: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        #[cfg(windows)]
        let parent = Path::new(env!("CARGO_MANIFEST_DIR")).join("target");
        // Use the native Unix filesystem when WSL builds the checkout under /mnt.
        #[cfg(unix)]
        let parent = std::env::temp_dir();
        fs::create_dir_all(&parent).unwrap();
        let path = parent.join(format!(
            "scan-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir(&path).unwrap();
        let resolved = path.canonicalize().unwrap();
        assert!(resolved.starts_with(parent.canonicalize().unwrap()));
        Self { path, resolved }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if self
            .path
            .canonicalize()
            .is_ok_and(|path| path == self.resolved)
        {
            fs::remove_dir_all(&self.path).unwrap();
        }
    }
}

fn child(scan: &Scan, directory: NodeId, name: &str) -> NodeView {
    scan.children(directory)
        .unwrap()
        .into_iter()
        .find(|child| child.name == name)
        .unwrap()
}

#[test]
fn reads_sparse_files_and_attributes_hard_links_consistently() {
    let fixture = Fixture::new();
    let root = &fixture.path;
    let left = root.join("a-alias");
    let right = root.join("z-original");
    fs::create_dir(&left).unwrap();
    fs::create_dir(&right).unwrap();
    fs::create_dir(root.join("empty")).unwrap();
    let original = right.join("payload.bin");
    fs::write(&original, [42u8; 8193]).unwrap();
    fs::hard_link(&original, left.join("alias.bin")).unwrap();
    fs::hard_link(&original, root.join("m-alias.bin")).unwrap();
    make_directory_link(&right, &root.join("directory-link"));
    make_sparse(&root.join("sparse.bin"), 16 * 1024 * 1024);
    for size in 1..=105 {
        fs::write(root.join(format!("smaller-{size:03}.bin")), vec![0u8; size]).unwrap();
    }

    for workers in [1, 4] {
        let mut scan = Scan::start(root, ScanOptions { workers }).unwrap();
        scan.wait().unwrap();
        let progress = scan.progress();
        assert_eq!(progress.phase, Phase::Complete);
        assert_eq!(progress.files, 109);
        assert_eq!(progress.skipped_directories, 0);
        assert!(progress.first_rows.is_some());
        assert!(progress.first_browsable_directory.is_some());

        let root_node = scan.node(ROOT).unwrap();
        assert_eq!(root_node.coverage, Coverage::Complete);
        let totals = root_node.sizes.unwrap();
        assert_eq!(
            totals.logical.known_value(),
            Some(16 * 1024 * 1024 + 3 * 8193 + 5565)
        );
        assert_eq!(totals.allocated.unknown_files, 0);
        let left = child(&scan, ROOT, "a-alias");
        let right = child(&scan, ROOT, "z-original");
        let owner = child(&scan, left.id, "alias.bin");
        assert_eq!(owner.shared_with, None);
        assert!(owner.sizes.unwrap().allocated.bytes >= 8193);
        assert_eq!(
            left.sizes.unwrap().allocated,
            owner.sizes.unwrap().allocated
        );
        assert_eq!(right.sizes.unwrap().allocated.known_value(), Some(0));
        assert_eq!(
            child(&scan, right.id, "payload.bin").shared_with,
            Some(owner.id)
        );
        assert_eq!(
            child(&scan, ROOT, "m-alias.bin").shared_with,
            Some(owner.id)
        );
        assert!(
            scan.path(owner.id)
                .unwrap()
                .ends_with(Path::new("a-alias").join("alias.bin"))
        );

        let sparse = child(&scan, ROOT, "sparse.bin");
        assert_eq!(sparse.sizes.unwrap().allocated.known_value(), Some(0));
        let empty = child(&scan, ROOT, "empty");
        assert_eq!(empty.coverage, Coverage::Complete);
        assert_eq!(empty.sizes.unwrap().allocated.known_value(), Some(0));
        let link = child(&scan, ROOT, "directory-link");
        assert_eq!(link.kind, NodeKind::Link);
        assert_eq!(link.coverage, Coverage::Excluded);
        assert_eq!(
            link.target.unwrap().canonicalize().unwrap(),
            root.join("z-original").canonicalize().unwrap()
        );
        assert!(scan.children(link.id).is_none());

        let logical = scan.top_files(Metric::Logical);
        assert_eq!(logical.len(), 100);
        assert_eq!(logical[0].1.id, sparse.id);
        assert_eq!(logical[1].1.id, owner.id);
        assert_eq!(logical.last().unwrap().1.name, "smaller-010.bin");
        let allocated = scan.top_files(Metric::Allocated);
        assert_eq!(allocated.len(), 100);
        assert_eq!(allocated[0].1.id, owner.id);
        assert!(allocated.iter().all(|(_, node)| node.shared_with.is_none()));
    }
}

#[test]
fn keeps_sibling_results_when_directory_listing_is_denied() {
    let fixture = Fixture::new();
    let root = &fixture.path;
    let blocked = root.join("blocked");
    fs::create_dir(&blocked).unwrap();
    fs::write(blocked.join("hidden.bin"), [7u8; 8192]).unwrap();
    fs::write(root.join("visible.bin"), [3u8; 4096]).unwrap();
    let Some(restore) = deny_listing(&blocked) else {
        return;
    };

    let denied = fs::read_dir(&blocked).err().map(|error| error.kind());
    let scan = Scan::start(root, ScanOptions { workers: 2 }).and_then(|mut scan| {
        scan.wait()?;
        Ok(scan)
    });
    restore();

    assert_eq!(denied, Some(io::ErrorKind::PermissionDenied));
    let scan = scan.unwrap();
    assert_eq!(scan.progress().skipped_directories, 1);
    assert_eq!(scan.progress().files, 1);
    assert_eq!(scan.node(ROOT).unwrap().coverage, Coverage::Partial);
    assert_eq!(
        scan.node(ROOT)
            .unwrap()
            .sizes
            .unwrap()
            .logical
            .known_value(),
        Some(4096)
    );
    let blocked = child(&scan, ROOT, "blocked");
    assert_eq!(blocked.coverage, Coverage::Unreadable);
    assert!(blocked.sizes.is_none());
}

#[test]
fn refresh_backfills_rank_without_enumerating_siblings() {
    let fixture = Fixture::new();
    let left = fixture.path.join("left");
    let right = fixture.path.join("right");
    fs::create_dir(&left).unwrap();
    fs::create_dir(&right).unwrap();
    let largest = left.join("largest");
    fs::write(&largest, [1u8; 4096]).unwrap();
    for size in 1..=100 {
        fs::write(right.join(format!("{size:03}")), vec![2u8; size]).unwrap();
    }
    let mut scan = Scan::start(&fixture.path, ScanOptions { workers: 2 }).unwrap();
    scan.wait().unwrap();
    assert_eq!(scan.top_files(Metric::Logical)[0].1.name, "largest");
    assert_eq!(
        scan.top_files(Metric::Logical).last().unwrap().1.name,
        "002"
    );
    fs::remove_file(largest).unwrap();
    fs::write(right.join("new-outside"), [0u8; 8192]).unwrap();

    let selected = child(&scan, ROOT, "left").id;
    scan.rescan(selected).unwrap();
    scan.wait().unwrap();
    assert_eq!(scan.generation(), 1);
    assert_eq!(scan.result_progress().files, 100);
    assert_eq!(
        scan.node(ROOT)
            .unwrap()
            .sizes
            .unwrap()
            .logical
            .known_value(),
        Some(5050)
    );
    let rank = scan.top_files(Metric::Logical);
    assert_eq!(rank.len(), 100);
    assert_eq!(rank[0].1.name, "100");
    assert_eq!(rank.last().unwrap().1.name, "001");
    let root_path = scan.path(ROOT).unwrap();
    assert!(scan.find_path(root_path.join("left")).is_some());
    assert!(
        scan.find_path(root_path.join("right").join("new-outside"))
            .is_none()
    );
}

#[test]
fn refresh_links_across_the_selected_boundary() {
    let fixture = Fixture::new();
    let first = fixture.path.join("a");
    fs::create_dir(&first).unwrap();
    let alias = first.join("alias");
    let original = fixture.path.join("z-original");
    fs::write(&original, [4u8; 8193]).unwrap();
    let mut scan = Scan::start(&fixture.path, ScanOptions { workers: 2 }).unwrap();
    scan.wait().unwrap();
    let allocation = scan.node(ROOT).unwrap().sizes.unwrap().allocated;

    fs::hard_link(&original, &alias).unwrap();
    scan.rescan(child(&scan, ROOT, "a").id).unwrap();
    scan.wait().unwrap();
    let owner = child(&scan, child(&scan, ROOT, "a").id, "alias");
    assert_eq!(child(&scan, ROOT, "z-original").shared_with, Some(owner.id));
    assert_eq!(
        scan.node(ROOT).unwrap().sizes.unwrap().allocated,
        allocation
    );
    assert_eq!(scan.top_files(Metric::Allocated)[0].1.id, owner.id);

    fs::remove_file(alias).unwrap();
    scan.rescan(child(&scan, ROOT, "a").id).unwrap();
    scan.wait().unwrap();
    assert_eq!(
        scan.node(ROOT).unwrap().sizes.unwrap().allocated,
        allocation
    );
    assert_eq!(scan.top_files(Metric::Allocated)[0].1.name, "z-original");
    assert_eq!(child(&scan, ROOT, "z-original").shared_with, None);
}

#[cfg(unix)]
fn make_directory_link(target: &Path, path: &Path) {
    std::os::unix::fs::symlink(target, path).unwrap();
}

#[cfg(windows)]
fn make_directory_link(target: &Path, path: &Path) {
    // Junction creation works without the Windows symbolic-link privilege.
    let output = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile", "-NonInteractive", "-Command",
            "New-Item -ItemType Junction -Path $env:TREESCAN_TEST_LINK -Target $env:TREESCAN_TEST_DEST -ErrorAction Stop | Out-Null",
        ])
        .env("TREESCAN_TEST_LINK", path)
        .env("TREESCAN_TEST_DEST", target)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn make_sparse(path: &Path, length: u64) {
    let file = File::create_new(path).unwrap();
    #[cfg(windows)]
    {
        use std::{os::windows::io::AsRawHandle, ptr};
        use windows_sys::Win32::System::{IO::DeviceIoControl, Ioctl::FSCTL_SET_SPARSE};

        let mut returned = 0;
        // The synchronous sparse flag operation needs no input or output data buffer.
        let ok = unsafe {
            DeviceIoControl(
                file.as_raw_handle(),
                FSCTL_SET_SPARSE,
                ptr::null(),
                0,
                ptr::null_mut(),
                0,
                &mut returned,
                ptr::null_mut(),
            )
        };
        assert_ne!(ok, 0, "{}", io::Error::last_os_error());
    }
    file.set_len(length).unwrap();
}

#[cfg(unix)]
fn deny_listing(path: &Path) -> Option<impl FnOnce() + '_> {
    use std::os::unix::fs::PermissionsExt;
    // A privileged Linux or macOS runner bypasses mode bits.
    if unsafe { libc::geteuid() } == 0 {
        return None;
    }
    let previous = fs::metadata(path).unwrap().permissions();
    fs::set_permissions(path, fs::Permissions::from_mode(0)).unwrap();
    Some(move || fs::set_permissions(path, previous).unwrap())
}

#[cfg(windows)]
fn deny_listing(path: &Path) -> Option<impl FnOnce() + '_> {
    use std::process::Command;

    let user = Command::new("whoami.exe")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()
        .unwrap();
    assert!(user.status.success());
    let stdout = String::from_utf8_lossy(&user.stdout);
    let sid = stdout
        .split(|ch: char| ch != '-' && !ch.is_ascii_alphanumeric())
        .find(|field| field.starts_with("S-1-"))
        .unwrap();
    let deny = Command::new("icacls.exe")
        .arg(path)
        .args(["/deny", &format!("*{sid}:(RD)")])
        .output()
        .unwrap();
    assert!(
        deny.status.success(),
        "{}",
        String::from_utf8_lossy(&deny.stderr)
    );
    let sid = format!("*{sid}");
    Some(move || {
        let restore = Command::new("icacls.exe")
            .arg(path)
            .args(["/remove:d", &sid])
            .output()
            .unwrap();
        assert!(
            restore.status.success(),
            "{}",
            String::from_utf8_lossy(&restore.stderr)
        );
    })
}

#[cfg(windows)]
#[test]
#[ignore = "requires the Windows Cloud Files filter and a writable NTFS volume"]
fn reports_a_dehydrated_cloud_placeholder() {
    use std::mem::size_of;
    use std::os::windows::{ffi::OsStrExt, fs::MetadataExt};
    use std::ptr;
    use windows_sys::Win32::Storage::{
        CloudFilters::*,
        FileSystem::{FILE_ATTRIBUTE_NORMAL, FILE_BASIC_INFO},
    };
    use windows_sys::Win32::System::SystemServices::IO_REPARSE_TAG_CLOUD;
    use windows_sys::core::w;

    struct SyncRoot(Vec<u16>);

    impl Drop for SyncRoot {
        fn drop(&mut self) {
            // Only the newly registered test directory is passed here.
            unsafe { CfUnregisterSyncRoot(self.0.as_ptr()) };
        }
    }

    let fixture = Fixture::new();
    let wide: Vec<u16> = fixture
        .path
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let registration = CF_SYNC_REGISTRATION {
        StructSize: size_of::<CF_SYNC_REGISTRATION>() as u32,
        ProviderName: w!("TreeScan test fixture"),
        ProviderVersion: w!("0.1"),
        ..Default::default()
    };
    let policies = CF_SYNC_POLICIES {
        StructSize: size_of::<CF_SYNC_POLICIES>() as u32,
        Hydration: CF_HYDRATION_POLICY {
            Primary: CF_HYDRATION_POLICY_PROGRESSIVE,
            Modifier: CF_HYDRATION_POLICY_MODIFIER_NONE,
        },
        Population: CF_POPULATION_POLICY {
            Primary: CF_POPULATION_POLICY_ALWAYS_FULL,
            Modifier: CF_POPULATION_POLICY_MODIFIER_NONE,
        },
        ..Default::default()
    };
    // The path, registration, policies, and their strings live through the call.
    let result = unsafe {
        CfRegisterSyncRoot(
            wide.as_ptr(),
            &registration,
            &policies,
            CF_REGISTER_FLAG_NONE,
        )
    };
    assert_eq!(result, 0, "CfRegisterSyncRoot returned {result:#010x}");
    let sync_root = SyncRoot(wide);

    let length = 128 * 1024;
    let identity = [1u8];
    let mut placeholder = CF_PLACEHOLDER_CREATE_INFO {
        RelativeFileName: w!("cloud.bin"),
        FsMetadata: CF_FS_METADATA {
            BasicInfo: FILE_BASIC_INFO {
                FileAttributes: FILE_ATTRIBUTE_NORMAL,
                ..Default::default()
            },
            FileSize: length,
        },
        FileIdentity: identity.as_ptr().cast(),
        FileIdentityLength: identity.len() as u32,
        Flags: CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC,
        ..Default::default()
    };
    // The mutable create-info entry and its identity stay valid through the call.
    let result = unsafe {
        CfCreatePlaceholders(
            sync_root.0.as_ptr(),
            &mut placeholder,
            1,
            CF_CREATE_FLAG_NONE,
            ptr::null_mut(),
        )
    };
    assert_eq!(result, 0, "CfCreatePlaceholders returned {result:#010x}");

    let dehydrated = || {
        let attributes = fs::read_dir(&fixture.path)
            .unwrap()
            .filter_map(Result::ok)
            .find(|entry| entry.file_name() == "cloud.bin")
            .unwrap()
            .metadata()
            .unwrap()
            .file_attributes();
        let state =
            unsafe { CfGetPlaceholderStateFromAttributeTag(attributes, IO_REPARSE_TAG_CLOUD) };
        assert_ne!(state, CF_PLACEHOLDER_STATE_INVALID);
        state & CF_PLACEHOLDER_STATE_PARTIALLY_ON_DISK != 0
    };
    assert!(dehydrated());
    let mut scan = Scan::start(&fixture.path, ScanOptions { workers: 1 }).unwrap();
    scan.wait().unwrap();
    let cloud = child(&scan, ROOT, "cloud.bin");
    assert!(cloud.placeholder);
    let sizes = cloud.sizes.unwrap();
    assert_eq!(sizes.logical.known_value(), Some(length as u128));
    assert_eq!(sizes.allocated.known_value(), Some(0));
    assert!(dehydrated());
    let mut batch = Scan::start_windows_batch(&fixture.path, ScanOptions { workers: 1 }).unwrap();
    batch.wait().unwrap();
    assert_eq!(batch.progress().batched_directories, 1);
    let cloud = child(&batch, ROOT, "cloud.bin");
    assert!(cloud.placeholder);
    assert_eq!(cloud.sizes, Some(sizes));
    assert!(dehydrated());
}
