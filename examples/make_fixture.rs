use std::fs;
use std::io;
use std::path::PathBuf;
use std::thread;

fn main() -> io::Result<()> {
    let mut args = std::env::args_os().skip(1);
    let root = PathBuf::from(args.next().ok_or_else(usage)?);
    let count: usize = args
        .next()
        .as_deref()
        .and_then(|arg| arg.to_str())
        .and_then(|arg| arg.parse().ok())
        .filter(|count| *count > 0)
        .ok_or_else(usage)?;
    if args.next().is_some() {
        return Err(usage());
    }
    // Require a fresh root so that generating a fixture cannot overwrite existing files.
    fs::create_dir(&root)?;
    let workers = thread::available_parallelism()?.get().min(4);
    let per_directory = 1_000;
    thread::scope(|scope| -> io::Result<()> {
        let mut tasks = Vec::new();
        for worker in 0..workers {
            let root = &root;
            tasks.push(scope.spawn(move || -> io::Result<()> {
                let data = [0x61; 8192];
                let sizes = [64, 512, 4096, 8192];
                for index in (worker..count.div_ceil(per_directory)).step_by(workers) {
                    let directory = root
                        .join(format!("group-{:03}", index / 100))
                        .join(format!("dir-{:05}", index));
                    fs::create_dir_all(&directory)?;
                    let first = index * per_directory;
                    for (offset, number) in (first..count).take(per_directory).enumerate() {
                        fs::write(
                            directory.join(format!("file-{number:07}.dat")),
                            &data[..sizes[offset % sizes.len()]],
                        )?;
                    }
                }
                Ok(())
            }));
        }
        for task in tasks {
            task.join()
                .map_err(|_| io::Error::other("fixture worker panicked"))??;
        }
        Ok(())
    })?;
    println!("Created {count} files in {}", root.display());
    Ok(())
}

fn usage() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: make_fixture <new-directory> <file-count>",
    )
}
