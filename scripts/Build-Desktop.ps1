[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot '..'),
    [string]$OutputDirectory,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [switch]$Official
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsLinux -and !$IsMacOS) { throw 'Use Linux or macOS to build its native Flutter desktop bundle.' }
$root = (Resolve-Path -LiteralPath $Workspace).Path
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$destination = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName
$project = Join-Path $root 'desktop'
$pubspec = [IO.File]::ReadAllText((Join-Path $project 'pubspec.yaml'))
$version = [regex]::Match($pubspec, '(?m)^version:[ \t]*(\d+\.\d+\.\d+)\+([0-9]+)[ \t]*\r?$')
if (!$version.Success) { throw 'Set the desktop product version and build number.' }
$product = $version.Groups[1].Value
$build = $version.Groups[2].Value
$number = if ($Official) { $product } else { "$product-build.$build" }
$platform = if ($IsLinux) { 'linux' } else { 'macos' }
$officialValue = $Official.IsPresent.ToString().ToLowerInvariant()

Push-Location -LiteralPath $project
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependencies could not be resolved.' }
    & flutter build $platform --release --no-pub "--dart-define=TREESCAN_VERSION=$product" `
        "--dart-define=TREESCAN_BUILD_NUMBER=$build" "--dart-define=TREESCAN_GITHUB_REPOSITORY=$Repository" `
        "--dart-define=TREESCAN_OFFICIAL_RELEASE=$officialValue"
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed to build the $platform app." }

    if ($IsLinux) {
        $arch = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        if ($arch -notin @('x64', 'arm64')) { throw "Unsupported Linux build architecture $arch." }
        $name = "TreeScan-$number-linux-$arch-desktop"
        $bundle = Join-Path $project "build/linux/$arch/release/bundle"
        foreach ($item in 'treescan', 'lib/libtreescan.so', 'lib/libflutter_linux_gtk.so', 'lib/libapp.so') {
            if (!(Test-Path -LiteralPath (Join-Path $bundle $item) -PathType Leaf)) { throw "Missing $item." }
        }
        $stage = [IO.Directory]::CreateDirectory((Join-Path $root "target/desktop-linux-$PID")).FullName
        Copy-Item -LiteralPath $bundle -Destination (Join-Path $stage $name) -Recurse
        $package = Join-Path $destination "$name.tar.gz"
        & tar -czf $package -C $stage $name
        if ($LASTEXITCODE -ne 0) { throw 'Linux desktop archive creation failed.' }
    } else {
        $name = "TreeScan-$number-macos-universal-desktop"
        $bundle = Join-Path $project 'build/macos/Build/Products/Release/TreeScan.app'
        foreach ($item in 'Contents/MacOS/TreeScan', 'Contents/Frameworks/libtreescan.dylib',
                'Contents/Frameworks/App.framework/App', 'Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS') {
            $archs = & lipo -archs (Join-Path $bundle $item)
            if ($LASTEXITCODE -ne 0 -or $archs -notmatch '\barm64\b' -or $archs -notmatch '\bx86_64\b') {
                throw "Expected both macOS architectures in $item."
            }
        }
        & codesign --verify --deep --strict $bundle
        if ($LASTEXITCODE -ne 0) { throw 'macOS signature verification failed.' }
        $package = Join-Path $destination "$name.zip"
        & ditto -c -k --keepParent $bundle $package
        if ($LASTEXITCODE -ne 0) { throw 'macOS desktop archive creation failed.' }
    }
    Get-Item -LiteralPath $package
} finally {
    Pop-Location
}
