# app-update-checker

A PowerShell script for Windows 11 that lists your installed applications, works out
which ones have updates available, and shows the installed version beside the newer one.

It is **read-only**: it never installs or upgrades anything. It only prints the
`winget upgrade --id <Id>` command you can run yourself.

## Requirements

- **Windows 10 or 11.** The script needs winget, which exists only on Windows.
- **winget** (Windows Package Manager), part of the "App Installer" app from the Microsoft Store.
  It is preinstalled on Windows 11 and current Windows 10. Check with:

  ```powershell
  winget --version
  ```

  If that fails, install or update "App Installer" from the Microsoft Store.
- **Windows PowerShell 5.1** (built into Windows) or **PowerShell 7+** (`pwsh`). Check with
  `$PSVersionTable.PSVersion`.
- Optional: the `Microsoft.WinGet.Client` PowerShell module. See
  [The module prompt](#the-module-prompt) below.

## Get the script

Either clone the repository:

```powershell
git clone https://github.com/mogesjohnson/app-update-checker.git
cd app-update-checker
```

or download only the script into the current folder:

> **Note:** the download links and one-liners in this README point at the `main` branch.
> The fixes described here (wide-character names, no prompt under `-Json`, the `Update held`
> status, and so on) reach those links only after their pull requests are merged into `main`.

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/mogesjohnson/app-update-checker/main/Check-AppUpdates.ps1 -OutFile Check-AppUpdates.ps1
Unblock-File .\Check-AppUpdates.ps1
```

## Execution policy

Windows blocks unsigned scripts by default (`Restricted`), and marks downloaded files as
coming from the internet. Pick one:

- Run it once without changing any setting (works in a new or existing console):

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Check-AppUpdates.ps1
  # or, with PowerShell 7:
  pwsh -ExecutionPolicy Bypass -File .\Check-AppUpdates.ps1
  ```

- Or allow local scripts for your user, then run it directly:

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  Unblock-File .\Check-AppUpdates.ps1   # needed for a downloaded file under RemoteSigned
  .\Check-AppUpdates.ps1
  ```

No administrator rights are needed.

## The module prompt

The script prefers the `Microsoft.WinGet.Client` module (`Get-WinGetPackage`), which gives
exact versions. If the module is not installed, you did not pass `-UseCli` or `-Json`, and
the session is interactive, it asks:

```text
Microsoft.WinGet.Client module not found. Install it for the current user now? [y/N] (N = use winget CLI)
```

- `y` or `yes` runs `Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber`
  from the PowerShell Gallery (it may ask you to allow the NuGet provider), then uses the module.
- Anything else (or just Enter) uses the winget CLI instead: it parses
  `winget list` and `winget upgrade --include-unknown`.
- `-UseCli` skips the module and the prompt entirely. Use it for unattended runs.

The script never asks, and uses the CLI with a warning instead, when:

- `-Json` is set, so that only JSON reaches stdout, or
- nobody can answer: input is piped or redirected (`'N' | ...`), PowerShell was started with
  `-NonInteractive`, or it runs as a service or scheduled task without a desktop.

If the install after `y` fails (offline, blocked gallery, policy), or the module is installed
but fails, the script prints a warning and falls back to the CLI.

## Usage

```powershell
.\Check-AppUpdates.ps1 [-UpdatesOnly] [-ExportCsv <path>] [-Json] [-UseCli]
```

| Option | What it does |
| --- | --- |
| `-UpdatesOnly` | Show only apps that have an update available |
| `-ExportCsv <path>` | Also save the shown rows to a CSV file (UTF-8; columns Name, Id, Installed, Latest, Status) |
| `-Json` | Write the shown rows as a JSON array to the pipeline instead of the coloured table and summary |
| `-UseCli` | Skip the module and its prompt; parse winget CLI output |

Examples:

```powershell
# Everything, as a coloured table
.\Check-AppUpdates.ps1

# Only apps with updates, without the module prompt
.\Check-AppUpdates.ps1 -UpdatesOnly -UseCli

# Save all rows to CSV (the table is still printed)
.\Check-AppUpdates.ps1 -ExportCsv .\apps.csv

# Only updates, as JSON in a file
.\Check-AppUpdates.ps1 -UpdatesOnly -Json | Out-File updates.json

# Read the JSON back as objects
.\Check-AppUpdates.ps1 -Json -UseCli | ConvertFrom-Json

# Built-in help
Get-Help .\Check-AppUpdates.ps1 -Full
```

One-liners without saving the file:

```powershell
# Recommended: runs in its own scope and accepts options
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mogesjohnson/app-update-checker/main/Check-AppUpdates.ps1))) -UpdatesOnly -UseCli

# Shortest form, no options possible
irm https://raw.githubusercontent.com/mogesjohnson/app-update-checker/main/Check-AppUpdates.ps1 | iex
```

Prefer the scriptblock form. `irm | iex` runs the script text directly in your session, so
afterwards its functions and option variables (`$Json`, `$UseCli`, ...) are still defined
there. The script keeps strict mode and `$ErrorActionPreference = 'Stop'` inside its own
function, so neither form changes those settings in your session.

The first winget run on a machine may take a while to update its sources. The script accepts
the source agreements (`--accept-source-agreements`) so it does not stop to ask.

## Output

Rows with updates are yellow, up-to-date rows are green. Apps are sorted by name.

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

- With `-UpdatesOnly` and nothing to update you get `No applications to show.` and the summary.
- With `-ExportCsv` the script also prints `Exported <n> row(s) to <path>`.
- With `-Json` you get only the JSON array (`[]` when empty), for example:

  ```json
  [
    {
      "Name": "7-Zip",
      "Id": "7zip.7zip",
      "Installed": "23.01",
      "Latest": "24.08",
      "Status": "Update available"
    }
  ]
  ```

  Windows PowerShell 5.1 indents JSON differently from PowerShell 7; the content is the same.

## Notes

- Apps not installed through a winget source show their installed version as "Latest".
- The CLI fallback parses fixed-width columns from the header line; very long names may be
  truncated by winget itself, so the module path is more accurate.
- The script never installs or upgrades apps. The only thing it can install is the
  `Microsoft.WinGet.Client` module, and only after you answer `y`.

## Testing

The tests use [Pester 5](https://pester.dev) and mock winget and the WinGet module, so they
need neither and never change anything on the machine. They run on Windows PowerShell 5.1
and PowerShell 7 (including PowerShell 7 on Linux or macOS).

Install Pester 5 once for your user. Windows PowerShell 5.1 ships an old Pester 3, hence
`-SkipPublisherCheck`, and the version range keeps you on Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Scope CurrentUser -Force -SkipPublisherCheck
```

From the repository root, run:

```powershell
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99
Invoke-Pester -Path .\tests -Output Detailed
```

Expected: every test shows `[+]` and the last line reads
`Tests Passed: <n>, Failed: 0, Skipped: 0, ...`.

Optional lint, the same as CI:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

No output means no issues. CI (`.github/workflows/ci.yml`) runs the tests in both PowerShell
versions and the linter on `windows-latest` for every pull request and every push to `main`.

## License

MIT © Moges Johnson
