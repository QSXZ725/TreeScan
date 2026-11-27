[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot '..'),
    [string]$Bundle,
    [string]$OutputDirectory,
    [string]$RuntimeDirectory,
    [ValidateSet('x64','arm64')]
    [string]$Architecture = 'x64',
    [switch]$Portable,
    [switch]$Official
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Workspace).ProviderPath
$manifest = [IO.File]::ReadAllText((Join-Path $root 'desktop\pubspec.yaml'))
$versionParts = [regex]::Match($manifest, '(?m)^version:[ \t]*(\d+\.\d+\.\d+)(?:\+([0-9]+))?[ \t]*\r?$')
$version = $versionParts.Groups[1].Value
if (-not $version) { throw 'The desktop manifest must declare a three-part version.' }
$buildNumber = [int]$versionParts.Groups[2].Value
$packageVersion = if ($Official) { $version } else { "$version-build.$buildNumber" }
if (-not $Bundle) { $Bundle = Join-Path $root "desktop\build\windows\$Architecture\runner\Release" }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$bundleRoot = (Resolve-Path -LiteralPath $Bundle).ProviderPath
foreach ($name in @('TreeScan.exe', 'TreeScan-CLI.exe', 'treescan.dll', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundleRoot $name) -PathType Leaf)) {
        throw "Build the Windows release bundle first. Missing $name."
    }
}

$machine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
function Confirm-Architecture([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Expected a Windows executable: $Path" }
        $reader.BaseStream.Position = 0x3C
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne $machine) {
            throw "Expected a Windows $Architecture executable: $Path"
        }
    } finally {
        $reader.Dispose()
    }
}
foreach ($name in @('TreeScan.exe', 'TreeScan-CLI.exe', 'treescan.dll', 'flutter_windows.dll')) {
    Confirm-Architecture (Join-Path $bundleRoot $name)
}

$executable = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $bundleRoot 'TreeScan.exe'))
if (($executable.ProductVersion -split '\+')[0] -ne $version -or $executable.FilePrivatePart -ne $buildNumber) {
    throw "Build TreeScan $version+$buildNumber before packaging. Found $($executable.FileVersion)."
}

$packageKind = if ($Portable) { 'portable' } else { 'msi' }
$payloadFolder = if ($Portable) { 'TreeScan' } else { 'files' }
$stage = Join-Path $root ("target\$packageKind-" + [Guid]::NewGuid().ToString('N'))
$files = Join-Path $stage $payloadFolder
$null = New-Item -ItemType Directory -Path $files -Force
Get-ChildItem -LiteralPath $bundleRoot -File -Recurse |
    Where-Object Extension -notin @('.pdb', '.lib', '.exp', '.ilk') |
    ForEach-Object {
        $relative = $_.FullName.Substring($bundleRoot.Length + 1)
        $copy = Join-Path $files $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copy))
        Copy-Item -LiteralPath $_.FullName -Destination $copy
    }

if (!$RuntimeDirectory) {
    $vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vcTools = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x86.x64' }
    $vs = & $vswhere -latest -products '*' -requires "Microsoft.VisualStudio.Component.VC.Tools.$vcTools" -property installationPath
    if (-not $vs) { throw 'Microsoft Visual Studio C++ tools are required to locate the redistributable runtime.' }
    $runtime = Get-ChildItem -Path "$vs\VC\Redist\MSVC\*\$Architecture\Microsoft.VC*.CRT" -Directory |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $runtime) { throw "The $Architecture Visual C++ app-local redistributable files are missing." }
    $RuntimeDirectory = $runtime.FullName
}
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll')) {
    $library = Join-Path $RuntimeDirectory $name
    Confirm-Architecture $library
    Copy-Item -LiteralPath $library -Destination $files -Force
}
if ($Architecture -eq 'x64') {
    $exceptionRuntime = Join-Path $RuntimeDirectory 'vcruntime140_1.dll'
    Confirm-Architecture $exceptionRuntime
    Copy-Item -LiteralPath $exceptionRuntime -Destination $files -Force
}

function Publish-Package([string]$Source, [string]$Suffix) {
    $output = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
    $destination = Join-Path $output.FullName "TreeScan-$packageVersion-windows-$Architecture$Suffix"
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    Get-Item -LiteralPath $destination
}

if ($Portable) {
    [IO.File]::WriteAllText((Join-Path $files 'TreeScan.portable'), '')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = Join-Path $stage 'TreeScan-portable.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $files, $archive, [IO.Compression.CompressionLevel]::Optimal, $true
    )
    Publish-Package $archive '-portable.zip'
    return
}

function New-TableRow {
    param([Parameter(ValueFromRemainingArguments)][AllowEmptyString()][string[]]$Fields)
    $Fields -join [char]9
}

function Import-MsiTable {
    param([string]$Name, [string[]]$Columns, [string[]]$Types, [string]$Key, [string[]]$Rows)
    $filename = "$Name.idt"
    $lines = @(
        ($Columns -join [char]9)
        ($Types -join [char]9)
        (New-TableRow $Name $Key)
    ) + $Rows
    [IO.File]::WriteAllLines((Join-Path $stage $filename), $lines, [Text.Encoding]::ASCII)
    $db.Import($stage, $filename)
}

function Get-ComponentGuid([string]$Path, [string]$Platform = $Architecture) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$id = ($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("TreeScan.$Platform/$Path")))[0..15]
        [Guid]::new($id).ToString('B').ToUpperInvariant()
    } finally {
        $hash.Dispose()
    }
}

$ddf = [Collections.Generic.List[string]]::new()
$ddf.AddRange([string[]]@(
    '.Set CabinetNameTemplate=payload.cab'
    '.Set DiskDirectoryTemplate=.'
    '.Set CompressionType=MSZIP'
    '.Set Cabinet=on'
    '.Set Compress=on'
    '.Set MaxDiskSize=0'
    '.Set RptFileName=payload.rpt'
    '.Set InfFileName=payload.inf'
))
$directories = [Collections.Generic.List[string]]::new()
$directories.Add((New-TableRow TARGETDIR '' SourceDir))
$directories.Add((New-TableRow LocalAppDataFolder TARGETDIR '.'))
$directories.Add((New-TableRow ProgramMenuFolder TARGETDIR '.'))
$directories.Add((New-TableRow UserPrograms LocalAppDataFolder Programs))
$directories.Add((New-TableRow INSTALLDIR UserPrograms TreeScan))
$directoryIds = @{ '' = 'INSTALLDIR' }
$components = [Collections.Generic.List[string]]::new()
$membership = [Collections.Generic.List[string]]::new()
$fileRows = [Collections.Generic.List[string]]::new()
$registry = [Collections.Generic.List[string]]::new()
$removals = [Collections.Generic.List[string]]::new()
$sequence = 0
$exe = $null

foreach ($file in Get-ChildItem -LiteralPath $files -File -Recurse | Sort-Object FullName) {
    $relative = $file.FullName.Substring($files.Length + 1)
    if ($relative -match '[^\x20-\x7e]' -or $file.Length -gt [int]::MaxValue) {
        throw "Unsupported MSI payload name or size: $relative"
    }
    $parent = ''
    $directory = [IO.Path]::GetDirectoryName($relative)
    if ($directory) {
        foreach ($part in $directory.Split('\')) {
            $child = if ($parent) { "$parent\$part" } else { $part }
            if (-not $directoryIds.ContainsKey($child)) {
                $identifier = 'D{0:000000}' -f $directoryIds.Count
                $directories.Add((New-TableRow $identifier $directoryIds[$parent] "$identifier|$part"))
                $directoryIds.Add($child, $identifier)
            }
            $parent = $child
        }
    }

    $sequence++
    $fileId = 'F{0:000000}' -f $sequence
    $componentId = "C$fileId"
    $registryId = "R$fileId"
    $dirId = $directoryIds[$parent]
    $components.Add((New-TableRow $componentId (Get-ComponentGuid $relative) $dirId 260 '' $registryId))
    $membership.Add((New-TableRow Main $componentId))
    $fileRows.Add((New-TableRow $fileId $componentId "$fileId|$($file.Name)" $file.Length '' '' 16384 $sequence))
    $registry.Add((New-TableRow $registryId 1 'Software\TreeScan\Installer' $fileId $relative $componentId))
    $ddf.Add(('"files\{0}" {1}' -f $relative, $fileId))
    if ($relative -eq 'TreeScan.exe') {
        $exe = @{ Id = $fileId; Component = $componentId }
    }
}
if ($null -eq $exe) { throw 'The release bundle contains no application executable.' }
$notificationId = 'TreeScan.Desktop'
$notificationActivator = '{CEF39DAD-BBC2-4E53-9EBA-449B2D1F2E52}'
$notificationKey = "Software\Classes\AppUserModelId\$notificationId"
$registry.Add((New-TableRow NotificationName 1 $notificationKey DisplayName TreeScan $exe.Component))
$registry.Add((New-TableRow NotificationIcon 1 $notificationKey IconUri '[INSTALLDIR]data\flutter_assets\assets\treescan-logo.png' $exe.Component))
$registry.Add((New-TableRow NotificationActivator 1 $notificationKey CustomActivator $notificationActivator $exe.Component))
$registry.Add((New-TableRow NotificationServer 1 "Software\Classes\CLSID\$notificationActivator\LocalServer32" '' ('"[#{0}]" -Embedding' -f $exe.Id) $exe.Component))
foreach ($dirId in $directoryIds.Values) {
    $removals.Add((New-TableRow "Remove$dirId" $exe.Component '' $dirId 2))
}

[IO.File]::WriteAllLines((Join-Path $stage 'payload.ddf'), $ddf, [Text.Encoding]::ASCII)
Push-Location -LiteralPath $stage
try {
    & makecab.exe /F payload.ddf | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makecab failed ($LASTEXITCODE)." }
} finally {
    Pop-Location
}

$setup = Join-Path $stage 'TreeScan.msi'
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.OpenDatabase($setup, 3)
try {
    $upgradeCode = '{86F09ECA-41CC-40D2-8E8D-AF23B55950FA}'
    $legacyPreview = Get-ComponentGuid 'Product/0.2.0' -Platform x64
    Import-MsiTable Property @('Property','Value') @('s72','l0') Property @(
        (New-TableRow ProductName TreeScan)
        (New-TableRow ProductVersion $version)
        (New-TableRow ProductLanguage 1033)
        (New-TableRow ProductCode (Get-ComponentGuid "Product/$packageVersion"))
        (New-TableRow UpgradeCode $upgradeCode)
        (New-TableRow Manufacturer TreeScan)
        (New-TableRow ARPNOMODIFY 1)
        (New-TableRow LIMITUI 1)
        (New-TableRow MSIDEPLOYMENTCOMPLIANT 1)
        (New-TableRow SecureCustomProperties 'TREESCAN_OLDER;TREESCAN_NEWER;TREESCAN_LEGACY')
    )
    Import-MsiTable Upgrade @('UpgradeCode','VersionMin','VersionMax','Language','Attributes','Remove','ActionProperty') @('s38','S20','S20','S255','i4','S255','s72') (New-TableRow UpgradeCode VersionMin VersionMax Language Attributes) @(
        (New-TableRow $upgradeCode '' $version '' 512 '' TREESCAN_OLDER)
        (New-TableRow $upgradeCode $version '' '' 2 '' TREESCAN_NEWER)
        if ([version]$version -lt [version]'0.2.0') {
            (New-TableRow $upgradeCode '0.2.0' '0.2.0' '' 768 '' TREESCAN_LEGACY)
        }
    )
    Import-MsiTable LaunchCondition @('Condition','Description') @('s255','l255') Condition @(
        (New-TableRow "Installed OR NOT TREESCAN_NEWER OR TREESCAN_NEWER = ""$legacyPreview""" 'A newer version of TreeScan is already installed.')
    )
    Import-MsiTable Directory @('Directory','Directory_Parent','DefaultDir') @('s72','S72','l255') Directory $directories
    Import-MsiTable Component @('Component','ComponentId','Directory_','Attributes','Condition','KeyPath') @('s72','S38','s72','i2','S255','S72') Component $components
    Import-MsiTable Feature @('Feature','Feature_Parent','Title','Description','Display','Level','Directory_','Attributes') @('s38','S38','L64','L255','I2','i2','S72','i2') Feature @(
        (New-TableRow Main '' TreeScan 'Desktop disk space analyzer' 1 1 INSTALLDIR 0)
    )
    Import-MsiTable FeatureComponents @('Feature_','Component_') @('s38','s72') (New-TableRow Feature_ Component_) $membership
    Import-MsiTable File @('File','Component_','FileName','FileSize','Version','Language','Attributes','Sequence') @('s72','s72','l255','i4','S72','S20','I2','i4') File $fileRows
    Import-MsiTable Registry @('Registry','Root','Key','Name','Value','Component_') @('s72','i2','l255','L255','L0','s72') Registry $registry
    Import-MsiTable RemoveFile @('FileKey','Component_','FileName','DirProperty','InstallMode') @('s72','s72','L255','s72','i2') FileKey $removals
    Import-MsiTable Media @('DiskId','LastSequence','DiskPrompt','Cabinet','VolumeLabel','Source') @('i2','i4','L64','S255','S32','S72') DiskId @(
        (New-TableRow 1 $sequence '' '#payload.cab' '' '')
    )
    Import-MsiTable Shortcut @('Shortcut','Directory_','Name','Component_','Target','Arguments','Description','Hotkey','Icon_','IconIndex','ShowCmd','WkDir') @('s72','s72','l128','s72','s255','S255','L255','I2','S72','I2','I2','S72') Shortcut @(
        (New-TableRow TreeScanMenu ProgramMenuFolder TreeScan $exe.Component "[#$($exe.Id)]" '' 'TreeScan' '' '' '' 1 INSTALLDIR)
    )
    Import-MsiTable MsiShortcutProperty @('MsiShortcutProperty','Shortcut_','PropertyKey','PropVariantValue') @('s72','s72','s255','s255') MsiShortcutProperty @(
        (New-TableRow TreeScanAppId TreeScanMenu System.AppUserModel.ID $notificationId)
    )
    $execute = [ordered]@{
        FindRelatedProducts=25; LaunchConditions=100
        CostInitialize=800; FileCost=900; CostFinalize=1000; InstallValidate=1400
        InstallInitialize=1500; RemoveExistingProducts=1520; ProcessComponents=1600; UnpublishFeatures=1800
        RemoveRegistryValues=2600; RemoveShortcuts=3200; RemoveFiles=3500; RemoveFolders=3600
        InstallFiles=4000; CreateShortcuts=4500; WriteRegistryValues=5000
        RegisterUser=6000; RegisterProduct=6100; PublishFeatures=6300; PublishProduct=6400
        InstallFinalize=6600
    }
    $admin = [ordered]@{
        CostInitialize=800; FileCost=900; CostFinalize=1000; InstallValidate=1400
        InstallInitialize=1500; InstallAdminPackage=3900; InstallFiles=4000; InstallFinalize=6600
    }
    $installUi = [ordered]@{
        FindRelatedProducts=25; LaunchConditions=100
        CostInitialize=800; FileCost=900; CostFinalize=1000; ExecuteAction=1300
    }
    $adminUi = [ordered]@{
        CostInitialize=800; FileCost=900; CostFinalize=1000; ExecuteAction=1300
    }
    $sequences = @{
        InstallExecuteSequence=$execute
        AdminExecuteSequence=$admin
        InstallUISequence=$installUi
        AdminUISequence=$adminUi
    }
    foreach ($table in $sequences.GetEnumerator()) {
        Import-MsiTable $table.Key @('Action','Condition','Sequence') @('s72','S255','I2') Action @(
            foreach ($entry in $table.Value.GetEnumerator()) { New-TableRow $entry.Key '' $entry.Value }
        )
    }
    Import-MsiTable ActionText @('Action','Description','Template') @('s72','L255','L255') Action @(
        (New-TableRow InstallFiles 'Copying TreeScan files' '[1]')
        (New-TableRow CreateShortcuts 'Creating the TreeScan Start menu shortcut' '[1]')
        (New-TableRow RemoveFiles 'Removing TreeScan files' '[1]')
    )

    $record = $installer.CreateRecord(2)
    $null = $record.GetType().InvokeMember('StringData', 'SetProperty', $null, $record, @(1, 'payload.cab'))
    $record.SetStream(2, (Join-Path $stage 'payload.cab'))
    $view = $db.OpenView('INSERT INTO `_Streams` (`Name`, `Data`) VALUES (?, ?)')
    try { $view.Execute($record) } finally { $view.Close() }

    $summary = $db.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $db, @(16))
    $template = if ($Architecture -eq 'arm64') { 'Arm64;1033' } else { 'x64;1033' }
    $summaryValues = @{
        1 = 1252
        2 = 'Installation Database'
        3 = 'TreeScan'
        4 = 'TreeScan'
        7 = $template
        9 = [Guid]::NewGuid().ToString('B').ToUpperInvariant()
        14 = 500
        15 = 10
        19 = 2
    }
    foreach ($entry in $summaryValues.GetEnumerator()) {
        $null = $summary.GetType().InvokeMember(
            'Property', 'SetProperty', $null, $summary, @([int]$entry.Key, $entry.Value)
        )
    }
    $summary.Persist()
    $db.Commit()
} finally {
    foreach ($name in @('summary','view','record','db','installer')) {
        $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($value)
        }
    }
}

Publish-Package $setup '.msi'
