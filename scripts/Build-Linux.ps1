[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot '..'),
    [string]$OutputDirectory,
    [string]$Sysroot,
    [ValidateSet('x64','arm64')]
    [string]$Architecture = 'x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Workspace).Path
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$manifest = [IO.File]::ReadAllText((Join-Path $root 'Cargo.toml'))
$version = [regex]::Match($manifest, '(?m)^version = "(\d+\.\d+\.\d+)"\r?$').Groups[1].Value
if (!$version) { throw 'Cargo.toml must declare a three-part version.' }

$target = if ($Architecture -eq 'arm64') { 'aarch64-unknown-linux-musl' } else { 'x86_64-unknown-linux-musl' }
$machine = if ($Architecture -eq 'arm64') { 183 } else { 62 }
$windows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$suffix = if ($windows) { '.exe' } else { '' }
$cargo = (Get-Command "cargo$suffix").Source
$rustc = (Get-Command "rustc$suffix").Source
$rustRoot = (& $rustc --print sysroot).Trim()
$hostTarget = (& $rustc -vV | Select-String '^host: ').Line.Substring(6)
$linker = Join-Path $rustRoot "lib/rustlib/$hostTarget/bin/rust-lld$suffix"
$flags = @('-C', "linker=$linker", '-C', 'linker-flavor=ld.lld', '-C', 'link-self-contained=yes')
if ($Sysroot) {
    $Sysroot = (Resolve-Path -LiteralPath $Sysroot).Path
    $flags += @('--sysroot', $Sysroot)
}
$targetRoot = if ($Sysroot) { $Sysroot } else { $rustRoot }
if (!(Test-Path (Join-Path $targetRoot "lib/rustlib/$target/lib"))) {
    throw "Install Rust's $target standard library before building."
}
$priorFlags = $env:CARGO_ENCODED_RUSTFLAGS
$priorTarget = $env:CARGO_TARGET_DIR
$env:CARGO_ENCODED_RUSTFLAGS = $flags -join [char]31
$env:CARGO_TARGET_DIR = Join-Path $root 'target'
Push-Location -LiteralPath $root
try {
    & $cargo build --locked --release --target $target --bin treescan
    if ($LASTEXITCODE -ne 0) { throw "Linux $Architecture build failed ($LASTEXITCODE)." }
} finally {
    Pop-Location
    $env:CARGO_ENCODED_RUSTFLAGS = $priorFlags
    $env:CARGO_TARGET_DIR = $priorTarget
}

$binary = Join-Path $root "target/$target/release/treescan"
$header = [IO.File]::ReadAllBytes($binary)
if ($header.Length -lt 64 -or [BitConverter]::ToUInt32($header, 0) -ne 0x464C457F -or
    $header[4] -ne 2 -or $header[5] -ne 1 -or [BitConverter]::ToUInt16($header, 18) -ne $machine) {
    throw "Expected a little-endian $Architecture ELF executable."
}

$tar = if ($windows) {
    $git = (Get-Command git.exe).Source
    $gitTools = (& $git --exec-path).Trim()
    (Resolve-Path -LiteralPath (Join-Path $gitTools '../../../usr/bin/tar.exe')).Path
} else {
    (Get-Command tar).Source
}
$output = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName
$folder = "TreeScan-$version-linux-$Architecture"
$archive = Join-Path $output "$folder.tar.gz"
$temporary = "$archive.$PID.tmp"
$uncompressed = "$temporary.tar"
try {
    $common = @('--force-local', '--file', $uncompressed, '--owner=0', '--group=0', "--transform=s|^|$folder/|")
    & $tar --create --format=ustar '--mode=0755' @common -C ([IO.Path]::GetDirectoryName($binary)) treescan
    if ($LASTEXITCODE -ne 0) { throw "Linux archive creation failed ($LASTEXITCODE)." }
    & $tar --append '--mode=0644' @common -C $root LICENSE
    if ($LASTEXITCODE -ne 0) { throw "Adding the license to the Linux archive failed ($LASTEXITCODE)." }
    $source = [IO.File]::OpenRead($uncompressed)
    try {
        $file = [IO.File]::Create($temporary)
        try {
            $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Optimal, $true)
            try { $source.CopyTo($gzip) } finally { $gzip.Dispose() }
        } finally { $file.Dispose() }
    } finally { $source.Dispose() }
    Move-Item -LiteralPath $temporary -Destination $archive -Force
} finally {
    [IO.File]::Delete($temporary)
    [IO.File]::Delete($uncompressed)
}
Get-Item -LiteralPath $archive
