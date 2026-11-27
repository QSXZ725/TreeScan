[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot '..'),
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Workspace).Path
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$manifest = [IO.File]::ReadAllText((Join-Path $root 'Cargo.toml'))
$version = [regex]::Match($manifest, '(?m)^version = "(\d+\.\d+\.\d+)"\r?$').Groups[1].Value
if (!$version) { throw 'Cargo.toml must declare a three-part version.' }

$targets = @('aarch64-apple-darwin', 'x86_64-apple-darwin')
$binaries = @()
$targetDir = Join-Path $root 'target'
foreach ($target in $targets) {
    & cargo build --manifest-path (Join-Path $root 'Cargo.toml') --locked --release --target-dir $targetDir --target $target --bin treescan
    if ($LASTEXITCODE -ne 0) { throw "macOS build failed for $target ($LASTEXITCODE)." }
    $binaries += Join-Path $targetDir "$target/release/treescan"
}

$folder = "TreeScan-$version-macos-universal"
$stage = Join-Path $targetDir ('macos-' + [Guid]::NewGuid().ToString('N'))
$files = [IO.Directory]::CreateDirectory((Join-Path $stage $folder)).FullName
$app = Join-Path $files 'treescan'
& xcrun lipo -create @binaries -output $app
if ($LASTEXITCODE -ne 0) { throw "Creating the universal binary failed ($LASTEXITCODE)." }
& xcrun lipo $app -verify_arch arm64 x86_64
if ($LASTEXITCODE -ne 0) { throw "The universal binary is missing an architecture ($LASTEXITCODE)." }
& chmod 755 $app
if ($LASTEXITCODE -ne 0) { throw "Setting executable permissions failed ($LASTEXITCODE)." }
& codesign --force --sign - $app
if ($LASTEXITCODE -ne 0) { throw "Signing the universal binary failed ($LASTEXITCODE)." }
& codesign --verify --strict $app
if ($LASTEXITCODE -ne 0) { throw "Verifying the universal binary failed ($LASTEXITCODE)." }
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $files

$output = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName
$archive = Join-Path $output "$folder.tar.gz"
$temporary = Join-Path $stage "$folder.tar.gz"
& tar -czf $temporary -C $stage $folder
if ($LASTEXITCODE -ne 0) { throw "macOS packaging failed ($LASTEXITCODE)." }
Move-Item -LiteralPath $temporary -Destination $archive -Force
Get-Item -LiteralPath $archive
