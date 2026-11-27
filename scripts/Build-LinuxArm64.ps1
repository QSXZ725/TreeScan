[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot '..'),
    [string]$OutputDirectory,
    [string]$Sysroot
)

& (Join-Path $PSScriptRoot 'Build-Linux.ps1') -Architecture arm64 -Workspace $Workspace -OutputDirectory $OutputDirectory -Sysroot $Sysroot
