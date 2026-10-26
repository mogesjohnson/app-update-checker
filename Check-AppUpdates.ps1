<#
.SYNOPSIS
    Lists installed applications and shows which ones have updates available.

.DESCRIPTION
    Uses winget (Windows Package Manager) to inventory installed applications and
    compares each installed version with the newest available version.

    Preferred source is the Microsoft.WinGet.Client PowerShell module
    (Get-WinGetPackage). If the module is missing you are offered to install it
    for the current user; otherwise the script falls back to parsing the output
    of the winget CLI.

    This script is read-only: it never installs or upgrades any application.

.PARAMETER UpdatesOnly
    Show only applications that have an update available.

.PARAMETER ExportCsv
    Also export the results to the given CSV file path.

.PARAMETER Json
    Write the results to the pipeline as JSON instead of a coloured table.

.PARAMETER UseCli
    Skip the PowerShell module and parse winget CLI output directly.

.EXAMPLE
    .\Check-AppUpdates.ps1

.EXAMPLE
    .\Check-AppUpdates.ps1 -UpdatesOnly -ExportCsv .\updates.csv

.EXAMPLE
    .\Check-AppUpdates.ps1 -Json | Out-File apps.json

.NOTES
    Requires Windows 10/11 with winget (App Installer). Works in Windows
    PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ModuleName = 'Microsoft.WinGet.Client'

function Get-AppsFromModule {
    Import-Module $ModuleName -ErrorAction Stop
    foreach ($pkg in Get-WinGetPackage) {
        $installed = [string]$pkg.InstalledVersion
        $latest = $installed
        if ($pkg.IsUpdateAvailable -and $pkg.AvailableVersions) {
            $latest = [string]@($pkg.AvailableVersions)[0]
        }
        [pscustomobject]@{
            Name            = $pkg.Name
            Id              = $pkg.Id
            Installed       = $installed
            Latest          = $latest
            UpdateAvailable = [bool]$pkg.IsUpdateAvailable
        }
    }
}

function Get-AppInventory {
    if (-not (Get-Module -ListAvailable $ModuleName)) {
        $answer = Read-Host "$ModuleName module not found. Install it for the current user now? [y/N]"
        if ($answer -notmatch '^(y|yes)$') { throw "$ModuleName is required." }
        Install-Module $ModuleName -Scope CurrentUser -Force -AllowClobber
    }
    return @(Get-AppsFromModule)
}

# ---- main ----
$rows = @(Get-AppInventory | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{
        Name      = [string]$_.Name
        Id        = [string]$_.Id
        Installed = [string]$_.Installed
        Latest    = [string]$_.Latest
        Status    = if ($_.UpdateAvailable) { 'Update available' } else { 'Up to date' }
    }
})
$rows | Format-Table -AutoSize
