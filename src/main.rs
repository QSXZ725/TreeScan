use std::io;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;
use treescan::{Coverage, Metric, Phase, ROOT, Scan, ScanOptions, Size, display_path};

static INTERRUPTED: AtomicBool = AtomicBool::new(false);
const USAGE: &str = "用法  treescan <目录或卷根目录> [--metric allocated|logical] [--workers 1..32] [--stop-after-ms 毫秒] [--export JSON文件或-]";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("TreeScan 运行失败（{error}）");
            ExitCode::FAILURE
        }
    }
}

fn run() -> io::Result<()> {
    let mut arguments = std::env::args_os().skip(1);
    let Some(root) = arguments.next() else {
        println!("{USAGE}");
        return Ok(());
    };
    if root == "--help" || root == "-h" {
        println!("{USAGE}");
        #[cfg(windows)]
        println!("--windows-batch  在支持的本地 NTFS 目录试用批量枚举");
        return Ok(());
    }
    if root == "--version" || root == "-V" {
        println!("TreeScan {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    let mut options = ScanOptions::default();
    let mut metric = Metric::Allocated;
    let mut stop_after = None;
    let mut export = None;
    #[cfg(target_os = "android")]
    let mut control_stdin = false;
    #[cfg(windows)]
    let mut windows_batch = false;
    while let Some(option) = arguments.next() {
        #[cfg(target_os = "android")]
        if option == "--control-stdin" {
            control_stdin = true;
            continue;
        }
        #[cfg(windows)]
        if option == "--windows-batch" {
            windows_batch = true;
            continue;
        }
        let value = arguments.next().ok_or_else(|| invalid_option(&option))?;
        match (option.to_str(), value.to_str()) {
            (Some("--export"), _) if export.is_none() => export = Some(PathBuf::from(value)),
            (Some("--workers"), Some(value)) => {
                options.workers = value.parse().map_err(|_| invalid_option(&option))?;
            }
            (Some("--metric"), Some("logical")) => metric = Metric::Logical,
            (Some("--metric"), Some("allocated")) => metric = Metric::Allocated,
            (Some("--stop-after-ms"), Some(value)) => {
                stop_after = Some(Duration::from_millis(
                    value.parse().map_err(|_| invalid_option(&option))?,
                ));
            }
            _ => return Err(invalid_option(&option)),
        }
    }

    install_interrupt_handler()?;
    #[cfg(target_os = "android")]
    if control_stdin {
        thread::spawn(|| {
            use std::io::Read;
            if io::stdin()
                .lock()
                .read(&mut [0_u8])
                .is_ok_and(|read| read != 0)
            {
                INTERRUPTED.store(true, Ordering::Relaxed);
            }
        });
    }
    let root = PathBuf::from(root);
    #[cfg(windows)]
    let mut scan = if windows_batch {
        Scan::start_windows_batch(root, options)
    } else {
        Scan::start(root, options)
    }?;
    #[cfg(not(windows))]
    let mut scan = Scan::start(root, options)?;
    let mut stop_time = None;
    let mut next_report = Duration::from_secs(1);
    eprintln!("正在扫描，按 Ctrl+C 停止并保留结果。");

    let progress = loop {
        let progress = scan.progress();
        if progress.phase.is_finished() {
            break progress;
        }
        if stop_time.is_none()
            && (INTERRUPTED.load(Ordering::Relaxed)
                || stop_after.is_some_and(|after| progress.elapsed >= after))
        {
            scan.stop();
            eprintln!("已接受停止请求，正在收尾。");
            stop_time = Some(progress.elapsed);
        }
        if progress.elapsed >= next_report {
            eprintln!(
                "已发现 {} 个文件，已跳过 {} 个目录。",
                progress.files, progress.skipped_directories
            );
            next_report = progress.elapsed + Duration::from_secs(1);
        }
        thread::sleep(Duration::from_millis(20));
    };
    scan.wait()?;
    if let Some(path) = export {
        if path == Path::new("-") {
            use std::io::{BufWriter, Write};
            let mut output = BufWriter::new(io::stdout().lock());
            scan.write_snapshot(&mut output)?;
            return output.flush();
        }
        export_snapshot(&scan, &path)?;
        println!("已导出扫描结果到 {}", path.display());
    }
    let peak = peak_memory();
    if let Some(requested) = stop_time {
        println!(
            "发出停止请求后 {}结束",
            duration(Some(progress.elapsed.saturating_sub(requested)))
        );
    }

    let root = scan.node(ROOT).expect("the root is always present");
    let phase = if progress.phase == Phase::Cancelled {
        "已停止"
    } else {
        "已完成"
    };
    println!(
        "扫描{phase}，{} 个工作线程，耗时 {}",
        options.workers,
        duration(Some(progress.elapsed))
    );
    println!(
        "首批条目 {}，首个子目录可浏览 {}",
        duration(progress.first_rows),
        duration(progress.first_browsable_directory)
    );
    if let Some(peak) = peak {
        println!("峰值常驻内存 {:.1} MiB", peak as f64 / 1024.0 / 1024.0);
    }
    #[cfg(windows)]
    if windows_batch {
        println!(
            "{} 个目录使用了 Windows 批量枚举",
            progress.batched_directories
        );
    }
    println!(
        "发现 {} 个文件，跳过 {} 个目录，{} 个条目无法识别",
        progress.files, progress.skipped_directories, progress.unavailable_entries
    );
    println!(
        "根目录 {}，逻辑大小 {}，占用空间 {}",
        coverage(root.coverage),
        size(root.sizes.map(|sizes| sizes.logical)),
        size(root.sizes.map(|sizes| sizes.allocated))
    );

    let metric_name = match metric {
        Metric::Allocated => "占用空间",
        Metric::Logical => "逻辑大小",
    };
    let mut children = scan.children(ROOT).unwrap_or_default();
    children.sort_unstable_by(|left, right| {
        let key = |row: &treescan::NodeView| {
            row.sizes
                .and_then(|sizes| sortable_size(sizes.size(metric)))
        };
        key(right)
            .cmp(&key(left))
            .then_with(|| left.name.cmp(&right.name))
    });
    println!("\n直接子项（按{metric_name}排序，最多 10 项）");
    for child in children.into_iter().take(10) {
        let metric_size = child.sizes.map(|sizes| sizes.size(metric));
        let label = size(metric_size);
        let name = child.name.to_string_lossy();
        let target = child
            .target
            .as_ref()
            .map(|path| format!(" → {}", path.display()))
            .unwrap_or_default();
        let sharing = child
            .shared_with
            .and_then(|id| scan.path(id))
            .map(|path| format!("，共享占用归于 {}", display_path(&path)))
            .unwrap_or_default();
        let placeholder = if child.placeholder {
            "，云占位"
        } else {
            ""
        };
        println!(
            "  {label:>16}  {name}{target}（{:?}，{}{}{placeholder}）",
            child.kind,
            coverage(child.coverage),
            sharing
        );
    }
    println!("\n大文件排行（按{metric_name}排序，最多 100 项）");
    for (path, file) in scan.top_files(metric) {
        let label = size(file.sizes.map(|sizes| sizes.size(metric)));
        println!("  {label:>16}  {}", display_path(&path));
    }
    Ok(())
}

fn export_snapshot(scan: &Scan, path: &Path) -> io::Result<()> {
    use std::fs::{OpenOptions, remove_file, rename};
    use std::io::{BufWriter, Write};
    use std::time::{SystemTime, UNIX_EPOCH};

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
        scan.write_snapshot(&mut output)?;
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

fn invalid_option(option: &std::ffi::OsStr) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("选项 {:?} 有误。{USAGE}", option),
    )
}

fn duration(value: Option<Duration>) -> String {
    value.map_or_else(
        || "未取得".into(),
        |value| format!("{:.3} 秒", value.as_secs_f64()),
    )
}

fn sortable_size(value: Size) -> Option<u128> {
    (value.unknown_files == 0 || value.bytes > 0).then_some(value.bytes)
}

fn size(value: Option<Size>) -> String {
    match value {
        None => "未知".into(),
        Some(value) if value.unknown_files == 0 => format!("{} B", value.bytes),
        Some(value) if value.bytes == 0 => format!("未知（{} 项）", value.unknown_files),
        Some(value) => format!("{} B（另有 {} 项未知）", value.bytes, value.unknown_files),
    }
}

fn coverage(value: Coverage) -> &'static str {
    match value {
        Coverage::Pending => "未访问",
        Coverage::Partial => "部分统计",
        Coverage::Complete => "已统计",
        Coverage::Unreadable => "无法访问",
        Coverage::Excluded => "未遍历",
    }
}

#[cfg(windows)]
fn install_interrupt_handler() -> io::Result<()> {
    use windows_sys::Win32::System::Console::{
        CTRL_BREAK_EVENT, CTRL_C_EVENT, SetConsoleCtrlHandler,
    };

    unsafe extern "system" fn handler(event: u32) -> i32 {
        if matches!(event, CTRL_C_EVENT | CTRL_BREAK_EVENT) {
            INTERRUPTED.store(true, Ordering::Relaxed);
            1
        } else {
            0
        }
    }

    // The callback has static lifetime and only updates an atomic flag.
    if unsafe { SetConsoleCtrlHandler(Some(handler), 1) } == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
fn install_interrupt_handler() -> io::Result<()> {
    extern "C" fn handler(_: libc::c_int) {
        INTERRUPTED.store(true, Ordering::Relaxed);
    }

    // Updating a lock-free atomic is safe in a signal handler.
    let previous =
        unsafe { libc::signal(libc::SIGINT, handler as *const () as libc::sighandler_t) };
    if previous == libc::SIG_ERR {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(windows)]
fn peak_memory() -> Option<u64> {
    use windows_sys::Win32::System::{
        ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS},
        Threading::GetCurrentProcess,
    };

    let length = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
    let mut counters = PROCESS_MEMORY_COUNTERS {
        cb: length,
        ..Default::default()
    };
    // The current process handle needs no close, and the output buffer matches cb.
    let success = unsafe { GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, length) };
    (success != 0).then_some(counters.PeakWorkingSetSize as u64)
}

#[cfg(unix)]
fn peak_memory() -> Option<u64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    // getrusage initializes the structure on success.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
        return None;
    }
    let peak = u64::try_from(unsafe { usage.assume_init() }.ru_maxrss).ok()?;
    #[cfg(target_os = "macos")]
    return Some(peak);
    #[cfg(not(target_os = "macos"))]
    return peak.checked_mul(1024);
}
