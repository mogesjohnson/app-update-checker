# app-update-checker

A PowerShell script for Windows 11 that lists your installed applications, works out
which ones have updates available, and shows the installed version beside the newer one.

It is **read-only**: it never installs or upgrades anything. It only prints the
`winget upgrade --id <Id>` command you can run yourself.

## Requirements

- Windows 10/11 with **winget** (the "App Installer" app from the Microsoft Store; preinstalled on Windows 11)
- Windows PowerShell 5.1 or PowerShell 7+
- Optional but recommended: the `Microsoft.WinGet.Client` PowerShell module.
  If it is missing, the script offers to install it for the current user
  (`Install-Module Microsoft.WinGet.Client -Scope CurrentUser`). Answer **N** to
  fall back to parsing `winget list` / `winget upgrade --include-unknown` output.

## Usage

One-liner (download and run, no clone needed):

```powershell
irm https://raw.githubusercontent.com/mogesjohnson/app-update-checker/main/Check-AppUpdates.ps1 | iex
```

Or clone and run with options:

```powershell
git clone https://github.com/mogesjohnson/app-update-checker.git
cd app-update-checker
powershell -ExecutionPolicy Bypass -File .\Check-AppUpdates.ps1
```

| Option | What it does |
| --- | --- |
| `-UpdatesOnly` | Show only apps that need updating |
| `-ExportCsv <path>` | Also save the results to a CSV file |
| `-Json` | Output JSON instead of the coloured table |
| `-UseCli` | Skip the module and parse winget CLI output |

Examples:

```powershell
.\Check-AppUpdates.ps1 -UpdatesOnly
.\Check-AppUpdates.ps1 -ExportCsv .\apps.csv
.\Check-AppUpdates.ps1 -UpdatesOnly -Json | Out-File updates.json
Get-Help .\Check-AppUpdates.ps1 -Full
```

## Sample output

Rows with updates are yellow, up-to-date rows are green.

```text
Name                 Id                           Installed     Latest        Status
-------------------  ---------------------------  ------------  ------------  ----------------
7-Zip                7zip.7zip                    23.01         24.08         Update available
Git                  Git.Git                      2.47.0        2.47.0        Up to date
Google Chrome        Google.Chrome                129.0.6668    130.0.6723    Update available
Visual Studio Code   Microsoft.VisualStudioCode   1.94.2        1.94.2        Up to date

Summary: 4 apps checked, 2 update(s) available, 2 up to date.

To update an app (this script does not install anything), run:
  winget upgrade --id 7zip.7zip
  winget upgrade --id Google.Chrome
```

## Notes

- Apps not installed through a winget source show their installed version as "Latest".
- The CLI fallback parses fixed-width columns from the header line; very long names may be
  truncated by winget itself, so the module path is more accurate.

## License

MIT © Moges Johnson
