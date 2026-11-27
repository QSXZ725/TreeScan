[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot '..'),
    [string]$OutputDirectory,
    [string]$Sdk,
    [string]$JavaHome,
    [string]$Ndk,
    [string]$RustSysroots,
    [switch]$Official
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Workspace).Path
$windows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$suffix = if ($windows) { '.exe' } else { '' }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
if (!$Sdk) {
    $candidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    if ($windows -and $env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Android/Sdk'
    }
    $Sdk = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (!$Sdk) { throw 'Locate the Android SDK with -Sdk or ANDROID_SDK_ROOT.' }
if (!$Ndk) { $Ndk = Join-Path $Sdk 'ndk/27.0.12077973' }
$ndkHost = if ($windows) { 'windows-x86_64' } elseif ($IsMacOS) { 'darwin-x86_64' } else { 'linux-x86_64' }
$clang = Join-Path $Ndk "toolchains/llvm/prebuilt/$ndkHost/bin/clang$suffix"
if (!(Test-Path -LiteralPath $clang)) { throw 'Install Android NDK 27.0.12077973 or set -Ndk.' }
if ($RustSysroots) { $RustSysroots = (Resolve-Path -LiteralPath $RustSysroots).Path }
if ($windows -and $env:USERPROFILE) { $env:PATH = "$env:USERPROFILE/.cargo/bin;$env:PATH" }
if (!$JavaHome) {
    $compiler = (Get-Command "javac$suffix").Source
    $JavaHome = Split-Path -Parent (Split-Path -Parent $compiler)
}
$java = Join-Path $JavaHome "bin/java$suffix"
$javac = Join-Path $JavaHome "bin/javac$suffix"
$jar = Join-Path $JavaHome "bin/jar$suffix"
$keytool = Join-Path $JavaHome "bin/keytool$suffix"
$tools = Get-ChildItem -LiteralPath (Join-Path $Sdk 'build-tools') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (!$tools) { throw 'Install the Android SDK build tools.' }
$platform = Join-Path $Sdk 'platforms/android-36/android.jar'
if (!(Test-Path -LiteralPath $platform)) { throw 'Install Android SDK Platform 36.' }

$manifest = [IO.File]::ReadAllText((Join-Path $root 'desktop/pubspec.yaml'))
$versionParts = [regex]::Match($manifest, '(?m)^version:[ \t]*(\d+\.\d+\.\d+)\+([0-9]+)[ \t]*\r?$')
if (!$versionParts.Success) { throw 'Set the product version and build number in desktop/pubspec.yaml.' }
$version = $versionParts.Groups[1].Value
$build = [int]$versionParts.Groups[2].Value
if ($build -le 0) { throw 'Android needs a positive build number.' }

$stage = Join-Path $root ('target/android-' + [Guid]::NewGuid().ToString('N'))
$classes = [IO.Directory]::CreateDirectory((Join-Path $stage 'classes')).FullName
$dex = [IO.Directory]::CreateDirectory((Join-Path $stage 'dex')).FullName
$classJar = Join-Path $stage 'classes.jar'
$unsigned = Join-Path $stage 'unsigned.apk'
$aligned = Join-Path $stage 'aligned.apk'
$signed = Join-Path $stage 'signed.apk'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'android/src/org/treescan/mobile') -Filter '*.java' -File |
    ForEach-Object FullName)
$androidManifest = Join-Path $root 'android/AndroidManifest.xml'
$resources = Join-Path $stage 'res'
$drawable = [IO.Directory]::CreateDirectory((Join-Path $resources 'drawable-nodpi')).FullName
$resourceArchive = Join-Path $stage 'resources.zip'
$aapt = Join-Path $tools.FullName "aapt2$suffix"
Copy-Item -LiteralPath (Join-Path $root 'desktop/assets/treescan-logo.png') -Destination (Join-Path $drawable 'treescan_logo.png')
Copy-Item -LiteralPath (Join-Path $root 'android/res/xml') -Destination $resources -Recurse

& $javac --release 8 -Xlint:-options -encoding UTF-8 -classpath $platform -d $classes @sources
if ($LASTEXITCODE -ne 0) { throw "Java compilation failed ($LASTEXITCODE)." }
& $jar cf $classJar -C $classes .
if ($LASTEXITCODE -ne 0) { throw "Class archive failed ($LASTEXITCODE)." }
& $java -cp (Join-Path $tools.FullName 'lib/d8.jar') com.android.tools.r8.D8 --min-api 21 --lib $platform --output $dex $classJar
if ($LASTEXITCODE -ne 0) { throw "DEX compilation failed ($LASTEXITCODE)." }
& $aapt compile --dir $resources -o $resourceArchive
if ($LASTEXITCODE -ne 0) { throw "Android resource compilation failed ($LASTEXITCODE)." }
& $aapt link -o $unsigned -I $platform --manifest $androidManifest --min-sdk-version 21 --target-sdk-version 36 --version-code $build --version-name $version $resourceArchive
if ($LASTEXITCODE -ne 0) { throw "Android resource packaging failed ($LASTEXITCODE)." }

$native = [ordered]@{
    'arm64-v8a'   = @('aarch64-linux-android', 'aarch64-linux-android21')
    'armeabi-v7a' = @('armv7-linux-androideabi', 'armv7a-linux-androideabi21')
    'x86_64'      = @('x86_64-linux-android', 'x86_64-linux-android21')
}
$nativeTargetDir = Join-Path $root 'target/android-native'
$previousFlags = $env:CARGO_ENCODED_RUSTFLAGS
Push-Location -LiteralPath $root
try {
    foreach ($abi in $native.Keys) {
        $target, $triple = $native[$abi]
        $linkerVar = "CARGO_TARGET_$($target.Replace('-', '_').ToUpperInvariant())_LINKER"
        $previousLinker = [Environment]::GetEnvironmentVariable($linkerVar)
        $flags = @('-C', "link-arg=--target=$triple", '-C', 'link-arg=-Wl,-z,max-page-size=16384', '-C', 'strip=symbols')
        if ($RustSysroots) { $flags += @('--sysroot', (Join-Path $RustSysroots $target)) }
        [Environment]::SetEnvironmentVariable($linkerVar, $clang)
        try {
            $env:CARGO_ENCODED_RUSTFLAGS = $flags -join [char]0x1f
            & cargo build --locked --release --bin treescan --target $target --target-dir $nativeTargetDir
            if ($LASTEXITCODE -ne 0) { throw "Android scan engine build failed for $abi." }
        } finally {
            [Environment]::SetEnvironmentVariable($linkerVar, $previousLinker)
        }
    }
} finally {
    $env:CARGO_ENCODED_RUSTFLAGS = $previousFlags
    Pop-Location
}

if ($windows) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
$zip = [IO.Compression.ZipFile]::Open($unsigned, [IO.Compression.ZipArchiveMode]::Update)
try {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $dex 'classes.dex'), 'classes.dex')
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root 'LICENSE'), 'assets/LICENSE')
    foreach ($abi in $native.Keys) {
        $binary = Join-Path $nativeTargetDir "$($native[$abi][0])/release/treescan"
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $binary, "lib/$abi/libtreescan_scan.so", [IO.Compression.CompressionLevel]::NoCompression)
    }
} finally {
    $zip.Dispose()
}

$align = Join-Path $tools.FullName "zipalign$suffix"
& $align -P 16 -f 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { throw "APK alignment failed ($LASTEXITCODE)." }

$key = Join-Path $root 'target/android-preview.keystore'
if (!(Test-Path -LiteralPath $key)) {
    $pending = Join-Path $stage 'preview.keystore'
    & $keytool -genkeypair -keystore $pending -storetype PKCS12 -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=Android Debug,O=Android,C=US'
    if ($LASTEXITCODE -ne 0) { throw "Preview key generation failed ($LASTEXITCODE)." }
    try { [IO.File]::Move($pending, $key) } catch {
        if (!(Test-Path -LiteralPath $key)) { throw }
    }
}
$signer = Join-Path $tools.FullName 'lib/apksigner.jar'
& $java -jar $signer sign --ks $key --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out $signed $aligned
if ($LASTEXITCODE -ne 0) { throw "APK signing failed ($LASTEXITCODE)." }
& $java -jar $signer verify --verbose $signed
if ($LASTEXITCODE -ne 0) { throw "APK verification failed ($LASTEXITCODE)." }
& $align -P 16 -c 4 $signed
if ($LASTEXITCODE -ne 0) { throw "APK alignment verification failed ($LASTEXITCODE)." }

$out = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName
$packageVersion = if ($Official) { $version } else { "$version-build.$build" }
$archive = Join-Path $out "TreeScan-$packageVersion-android.apk"
Copy-Item -LiteralPath $signed -Destination $archive -Force
Get-Item -LiteralPath $archive
