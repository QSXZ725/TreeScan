[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Apk,
    [Parameter(Mandatory)][string]$OutputFile,
    [Parameter(Mandatory)][string]$JavaHome,
    [Parameter(Mandatory)][string]$BuildTools,
    [string]$Keystore,
    [string]$KeyAlias = 'treescan'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$env:TREESCAN_ANDROID_STORE_PASSWORD) {
    throw 'Set TREESCAN_ANDROID_STORE_PASSWORD to the release keystore password.'
}
$encodedKey = $env:TREESCAN_ANDROID_KEYSTORE_BASE64
if (!$Keystore -and !$encodedKey) {
    throw 'Provide a release keystore or set TREESCAN_ANDROID_KEYSTORE_BASE64.'
}

$inputApk = (Resolve-Path -LiteralPath $Apk).Path
$destination = [IO.Path]::GetFullPath($OutputFile)
$windows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$suffix = if ($windows) { '.exe' } else { '' }
$java = Join-Path $JavaHome "bin/java$suffix"
$signer = Join-Path $BuildTools 'lib/apksigner.jar'
$align = Join-Path $BuildTools "zipalign$suffix"
$staging = Join-Path ([IO.Path]::GetTempPath()) ('treescan-sign-' + [Guid]::NewGuid().ToString('N'))
$temporaryKey = Join-Path $staging 'release.p12'
$signed = Join-Path $staging 'signed.apk'
[void][IO.Directory]::CreateDirectory($staging)

try {
    if (!$windows) {
        & chmod 700 $staging
        if ($LASTEXITCODE -ne 0) { throw 'Could not protect the signing directory.' }
    }
    if ($Keystore) {
        $key = (Resolve-Path -LiteralPath $Keystore).Path
    } else {
        $key = $temporaryKey
        $keyBytes = [Convert]::FromBase64String($encodedKey)
        try {
            [IO.File]::WriteAllBytes($key, $keyBytes)
        } finally {
            [Array]::Clear($keyBytes, 0, $keyBytes.Length)
        }
    }
    Remove-Item Env:TREESCAN_ANDROID_KEYSTORE_BASE64 -ErrorAction SilentlyContinue
    $keyPassword = if ($env:TREESCAN_ANDROID_KEY_PASSWORD) {
        'env:TREESCAN_ANDROID_KEY_PASSWORD'
    } else {
        'env:TREESCAN_ANDROID_STORE_PASSWORD'
    }
    & $java -jar $signer sign --ks $key --ks-key-alias $KeyAlias `
        --ks-pass env:TREESCAN_ANDROID_STORE_PASSWORD --key-pass $keyPassword --out $signed $inputApk
    if ($LASTEXITCODE -ne 0) { throw "APK signing failed ($LASTEXITCODE)." }
    & $java -jar $signer verify --verbose --print-certs $signed
    if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed ($LASTEXITCODE)." }
    & $align -P 16 -c 4 $signed
    if ($LASTEXITCODE -ne 0) { throw "APK alignment verification failed ($LASTEXITCODE)." }

    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.File]::Copy($signed, $destination, $true)
    Get-Item -LiteralPath $destination
} finally {
    $env:TREESCAN_ANDROID_KEYSTORE_BASE64 = $encodedKey
    foreach ($file in @($temporaryKey, $signed, "$signed.idsig")) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    [IO.Directory]::Delete($staging)
}
