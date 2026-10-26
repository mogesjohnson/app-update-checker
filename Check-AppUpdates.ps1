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
    [switch]$UpdatesOnly,
    [string]$ExportCsv,
    [switch]$Json,
    [switch]$UseCli
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

function ConvertFrom-WingetTable {
    # Parses a winget text table using the column start positions of the header line.
    param([string[]]$Lines)

    # winget writes progress spinners with carriage returns; keep the final text of each line.
    $Lines = @($Lines | ForEach-Object { ([string]$_ -split "`r")[-1] })

    $sep = -1
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*-{10,}\s*$') { $sep = $i; break }
    }
    if ($sep -lt 1) { return }

    $header = $Lines[$sep - 1]
    $cols = @([regex]::Matches($header, '\S+') | ForEach-Object { [pscustomobject]@{ Name = $_.Value; Start = $_.Index } })
    if ($cols.Count -lt 3) { return }

    $availIdx = -1
    for ($c = 0; $c -lt $cols.Count; $c++) { if ($cols[$c].Name -eq 'Available') { $availIdx = $c } }
    if ($availIdx -lt 0 -and $cols.Count -ge 5) { $availIdx = 3 }

    for ($i = $sep + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { break }   # end of table
        if ($line.Length -le $cols[2].Start) { continue }    # not a data row

        $cells = for ($c = 0; $c -lt $cols.Count; $c++) {
            $start = $cols[$c].Start
            $end = if ($c + 1 -lt $cols.Count) { [Math]::Min($cols[$c + 1].Start, $line.Length) } else { $line.Length }
            if ($start -ge $line.Length -or $end -le $start) { '' } else { $line.Substring($start, $end - $start).Trim() }
        }
        $cells = @($cells)
        if (-not $cells[1]) { continue }

        [pscustomobject]@{
            Name      = $cells[0]
            Id        = $cells[1]
            Version   = $cells[2]
            Available = if ($availIdx -ge 0) { $cells[$availIdx] } else { '' }
        }
    }
}

function Get-AppsFromCli {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget was not found. Install "App Installer" from the Microsoft Store.'
    }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $list = ConvertFrom-WingetTable (winget list --accept-source-agreements 2>$null)
    $updates = @{}
    foreach ($u in ConvertFrom-WingetTable (winget upgrade --include-unknown --accept-source-agreements 2>$null)) {
        $updates[$u.Id] = $u
    }

    foreach ($p in $list) {
        $u = $updates[$p.Id]
        $latest = if ($u -and $u.Available) { $u.Available } elseif ($p.Available) { $p.Available } else { $p.Version }
        [pscustomobject]@{
            Name            = $p.Name
            Id              = $p.Id
            Installed       = $p.Version
            Latest          = $latest
            UpdateAvailable = [bool]$u
        }
    }
}

function Get-AppInventory {
    if (-not $UseCli) {
        if (-not (Get-Module -ListAvailable $ModuleName)) {
            $answer = Read-Host "$ModuleName module not found. Install it for the current user now? [y/N] (N = use winget CLI)"
            if ($answer -match '^(y|yes)$') {
                Install-Module $ModuleName -Scope CurrentUser -Force -AllowClobber
            }
        }
        if (Get-Module -ListAvailable $ModuleName) {
            try { return @(Get-AppsFromModule) }
            catch { Write-Warning "WinGet module failed ($($_.Exception.Message)); falling back to winget CLI." }
        }
    }
    return @(Get-AppsFromCli)
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 1) + '~'
}

function Write-AppTable($Rows) {
    $w = @{
        Name      = [Math]::Min(40, [Math]::Max(4, ($Rows | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum))
        Id        = [Math]::Min(40, [Math]::Max(2, ($Rows | ForEach-Object { $_.Id.Length } | Measure-Object -Maximum).Maximum))
        Installed = [Math]::Min(20, [Math]::Max(9, ($Rows | ForEach-Object { $_.Installed.Length } | Measure-Object -Maximum).Maximum))
        Latest    = [Math]::Min(20, [Math]::Max(6, ($Rows | ForEach-Object { $_.Latest.Length } | Measure-Object -Maximum).Maximum))
    }
    $fmt = "{0,-$($w.Name)}  {1,-$($w.Id)}  {2,-$($w.Installed)}  {3,-$($w.Latest)}  {4}"
    Write-Host ($fmt -f 'Name', 'Id', 'Installed', 'Latest', 'Status')
    Write-Host ($fmt -f ('-' * $w.Name), ('-' * $w.Id), ('-' * $w.Installed), ('-' * $w.Latest), ('-' * 16))
    foreach ($r in $Rows) {
        $color = if ($r.Status -eq 'Update available') { 'Yellow' } else { 'Green' }
        $line = $fmt -f (Limit-Text $r.Name $w.Name), (Limit-Text $r.Id $w.Id),
            (Limit-Text $r.Installed $w.Installed), (Limit-Text $r.Latest $w.Latest), $r.Status
        Write-Host $line -ForegroundColor $color
    }
}

# ---- main ----
# Dot-sourcing (. .\Check-AppUpdates.ps1) only loads the functions above, so tests can call them.
if ($MyInvocation.InvocationName -eq '.') { return }

$rows = @(Get-AppInventory | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{
        Name      = [string]$_.Name
        Id        = [string]$_.Id
        Installed = [string]$_.Installed
        Latest    = [string]$_.Latest
        Status    = if ($_.UpdateAvailable) { 'Update available' } else { 'Up to date' }
    }
})
$updates = @($rows | Where-Object { $_.Status -eq 'Update available' })
$shown = if ($UpdatesOnly) { $updates } else { $rows }

if ($ExportCsv) {
    $shown | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($shown.Count) row(s) to $ExportCsv" -ForegroundColor Cyan
}

if ($Json) {
    ConvertTo-Json -InputObject @($shown) -Depth 3
    return
}

if ($shown.Count -gt 0) { Write-AppTable $shown } else { Write-Host 'No applications to show.' }

Write-Host ''
Write-Host ("Summary: {0} apps checked, {1} update(s) available, {2} up to date." -f `
    $rows.Count, $updates.Count, ($rows.Count - $updates.Count))

if ($updates.Count -gt 0) {
    Write-Host ''
    Write-Host 'To update an app (this script does not install anything), run:' -ForegroundColor Cyan
    foreach ($u in $updates) { Write-Host "  winget upgrade --id $($u.Id)" }
}
