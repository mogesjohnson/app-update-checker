# Pester 5 tests for Check-AppUpdates.ps1. winget and the WinGet module are always mocked,
# so these tests never touch the real package manager and run on any OS with PowerShell.

BeforeAll {
    $ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Check-AppUpdates.ps1'
    $FixtureDir = Join-Path $PSScriptRoot 'fixtures'

    function Get-Fixture([string]$Name) {
        Get-Content -LiteralPath (Join-Path $FixtureDir $Name) -Encoding UTF8
    }

    # Stand-ins so Mock has a command to replace where winget or the module is not installed.
    function winget { throw 'real winget must not run in tests' }
    function Get-WinGetPackage { throw 'real Get-WinGetPackage must not run in tests' }

    . $ScriptPath
    # The script sets these inside Invoke-AppUpdateCheck; run the functions under the same rules.
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
}

Describe 'ConvertFrom-WingetTable' {
    It 'parses a winget list table' {
        $rows = @(ConvertFrom-WingetTable (Get-Fixture 'winget-list.txt'))
        $rows.Count | Should -Be 6
        $rows[0].Name | Should -Be '7-Zip 23.01 (x64)'
        $rows[0].Id | Should -Be '7zip.7zip'
        $rows[0].Version | Should -Be '23.01'
        $rows[0].Available | Should -Be '24.08'
        $rows[1].Id | Should -Be 'Git.Git'
        $rows[1].Available | Should -Be ''
    }

    It 'keeps names that winget truncated with an ellipsis' {
        $rows = @(ConvertFrom-WingetTable (Get-Fixture 'winget-list.txt'))
        $vc = $rows | Where-Object Id -eq 'Microsoft.VCRedist.2015+.x64'
        $vc.Name | Should -Be ('Microsoft Visual C++ 2015-2022 Redist' + [char]0x2026)
        $vc.Version | Should -Be '14.40.33810.0'
    }

    It 'parses a row that ends after the Version column' {
        $rows = @(ConvertFrom-WingetTable (Get-Fixture 'winget-list.txt'))
        $arp = $rows | Where-Object Name -eq 'Contoso Legacy Tool'
        $arp.Id | Should -Be 'ARP\Machine\X64\ContosoLegacy'
        $arp.Version | Should -Be '1.0'
        $arp.Available | Should -Be ''
    }

    It 'stops at the blank line that ends a winget upgrade table' {
        $rows = @(ConvertFrom-WingetTable (Get-Fixture 'winget-upgrade.txt'))
        $rows.Id | Should -Be @('7zip.7zip', 'Google.Chrome', 'Microsoft.VCRedist.2015+.x64')
        $rows[1].Available | Should -Be '130.0.6723.70'
    }

    It 'keeps only the text after the last carriage return (progress spinner)' {
        $lines = @(Get-Fixture 'winget-list.txt')
        $lines[0] = "   - `r   \ `r   | `r" + $lines[0]
        $spun = @(ConvertFrom-WingetTable $lines)
        $plain = @(ConvertFrom-WingetTable (Get-Fixture 'winget-list.txt'))
        ($spun | ConvertTo-Json) | Should -Be ($plain | ConvertTo-Json)
    }

    It 'handles spinner lines before the header' {
        $lines = @("   - `r   \ `r") + @(Get-Fixture 'winget-list.txt')
        @(ConvertFrom-WingetTable $lines).Count | Should -Be 6
    }

    It 'returns an empty Available when the column is missing' {
        $rows = @(ConvertFrom-WingetTable (Get-Fixture 'winget-list-no-available.txt'))
        $rows.Count | Should -Be 2
        $rows.Id | Should -Be @('Git.Git', 'Microsoft.VisualStudioCode')
        $rows | ForEach-Object { $_.Available | Should -Be '' }
    }

    It 'uses the fourth column as Available for a localized five-column header' {
        $lines = @(
            'Nom           ID             Version   Disponible Source',
            '------------------------------------------------------',
            '7-Zip         7zip.7zip      23.01     24.08      winget'
        )
        $row = ConvertFrom-WingetTable $lines
        $row.Available | Should -Be '24.08'
    }

    It 'skips short rows that end before the Version column' {
        $lines = @(Get-Fixture 'winget-list-no-available.txt')
        $lines = @($lines[0], $lines[1], 'wrapped text', $lines[2], $lines[3])
        @(ConvertFrom-WingetTable $lines).Id | Should -Be @('Git.Git', 'Microsoft.VisualStudioCode')
    }

    It 'cuts columns by display width when names have double-width characters' {
        # winget pads East Asian wide and fullwidth characters as two columns.
        $rows = @(ConvertFrom-WingetTable (Get-Fixture 'winget-list-wide.txt'))
        $rows.Id | Should -Be @('EPSON.PCFAXDriver', 'Git.Git', 'LINE.LINE', 'Hancom.HancomOffice', '7zip.7zip')
        $rows.Version | Should -Be @('1.12.00', '2.47.0', '9.4.2.3600', '12.0.0.535', '23.01')
        $rows.Available | Should -Be @('1.13.00', '', '', '', '24.08')
        $driver = -join [char[]](0x30C9, 0x30E9, 0x30A4, 0x30D0, 0x30FC)
        $rows[0].Name | Should -Be "Epson PC-FAX$driver"
    }

    It 'reads a header written in double-width characters' {
        $rows = @(ConvertFrom-WingetTable (Get-Fixture 'winget-list-ja.txt'))
        $rows.Id | Should -Be @('EPSON.PCFAXDriver', 'Microsoft.WindowsNotepad')
        $rows.Version | Should -Be @('1.12.00', '11.2410.21.0')
        $rows[0].Available | Should -Be '1.13.00'
    }

    It 'returns nothing when there is no table' {
        @(ConvertFrom-WingetTable (Get-Fixture 'winget-upgrade-none.txt')).Count | Should -Be 0
        @(ConvertFrom-WingetTable @()).Count | Should -Be 0
    }
}

Describe 'Get-AppsFromCli' {
    BeforeEach {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock winget {
            $calls.Add(($args -join ' '))
            switch ($args[0]) {
                'list' { Get-Fixture 'winget-list.txt' }
                'upgrade' { Get-Fixture 'winget-upgrade.txt' }
            }
        }
    }

    It 'merges winget list and winget upgrade' {
        $apps = @(Get-AppsFromCli)
        $apps.Count | Should -Be 6
        $zip = $apps | Where-Object Id -eq '7zip.7zip'
        $zip.Installed | Should -Be '23.01'
        $zip.Latest | Should -Be '24.08'
        $zip.UpdateAvailable | Should -BeTrue
        $git = $apps | Where-Object Id -eq 'Git.Git'
        $git.Latest | Should -Be '2.47.0'
        $git.UpdateAvailable | Should -BeFalse
        ($apps | Where-Object UpdateAvailable).Id | Should -Be @('7zip.7zip', 'Google.Chrome', 'Microsoft.VCRedist.2015+.x64')
    }

    It 'prefers the Available version from winget upgrade' {
        Mock winget {
            $lines = @(Get-Fixture 'winget-list.txt')
            if ($args[0] -eq 'upgrade') { $lines = $lines -replace '24\.08', '24.09' }
            $lines
        }
        (Get-AppsFromCli | Where-Object Id -eq '7zip.7zip').Latest | Should -Be '24.09'
    }

    It 'uses the installed version as Latest for apps without a source' {
        (Get-AppsFromCli | Where-Object Name -eq 'Contoso Legacy Tool').Latest | Should -Be '1.0'
    }

    It 'only calls winget with read-only listing arguments' {
        $null = Get-AppsFromCli
        $calls | Should -Be @(
            'list --accept-source-agreements',
            'upgrade --include-unknown --accept-source-agreements'
        )
    }

    It 'matches upgrades by Id and installed version when an Id is installed twice' {
        Mock winget {
            $header = @(
                'Name             Id                 Version   Available Source',
                '---------------------------------------------------------------'
            )
            switch ($args[0]) {
                'list' {
                    $header
                    '.NET Runtime 8   Microsoft.DotNet.8 8.0.8     8.0.11    winget'
                    '.NET Runtime 8   Microsoft.DotNet.8 8.0.11              winget'
                }
                'upgrade' {
                    $header
                    '.NET Runtime 8   Microsoft.DotNet.8 8.0.8     8.0.11    winget'
                }
            }
        }
        $apps = @(Get-AppsFromCli)
        $apps.Count | Should -Be 2
        $old = $apps | Where-Object Installed -eq '8.0.8'
        $new = $apps | Where-Object Installed -eq '8.0.11'
        $old.UpdateAvailable | Should -BeTrue
        $old.Latest | Should -Be '8.0.11'
        $new.UpdateAvailable | Should -BeFalse
        $new.Latest | Should -Be '8.0.11'
    }

    It 'throws when winget is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
        { Get-AppsFromCli } | Should -Throw '*winget was not found*'
        $calls.Count | Should -Be 0
    }
}

Describe 'Get-AppsFromCli version matching for duplicate Ids' {
    BeforeAll {
        # Builds a fixed-width winget table: Name, Id, Version, Available, Source.
        function Format-WingetTable([object[]]$Rows) {
            $fmt = '{0,-42}{1,-24}{2,-16}{3,-14}{4}'
            ($fmt -f 'Name', 'Id', 'Version', 'Available', 'Source')
            ('-' * 100)
            foreach ($r in $Rows) { ($fmt -f $r[0], $r[1], $r[2], $r[3], 'winget').TrimEnd() }
        }
        function Use-WingetOutput([object[]]$List, [object[]]$Upgrade) {
            $script:listTable = @(Format-WingetTable $List)
            $script:upgradeTable = @(Format-WingetTable $Upgrade)
            Mock winget { if ($args[0] -eq 'list') { $script:listTable } else { $script:upgradeTable } }
        }
    }

    It 'matches when winget upgrade adds trailing .0 parts' {
        Use-WingetOutput -List @(
            , @('.NET Runtime 8', 'Microsoft.DotNet.8', '8.0.8', '')
            , @('.NET Runtime 8', 'Microsoft.DotNet.8', '8.0.11', '')
        ) -Upgrade @(
            , @('.NET Runtime 8', 'Microsoft.DotNet.8', '8.0.8.0', '8.0.11')
        )
        $apps = @(Get-AppsFromCli)
        ($apps | Where-Object Installed -eq '8.0.8').UpdateAvailable | Should -BeTrue
        ($apps | Where-Object Installed -eq '8.0.11').UpdateAvailable | Should -BeFalse
    }

    It 'matches a version that one table truncated with an ellipsis' {
        $cut = '14.40.338' + [char]0x2026
        Use-WingetOutput -List @(
            , @('VC++ 2015-2022 x64', 'Microsoft.VCRedist.x64', '14.38.33130.0', '')
            , @('VC++ 2015-2022 x64', 'Microsoft.VCRedist.x64', '14.40.33810.0', '')
        ) -Upgrade @(
            , @('VC++ 2015-2022 x64', 'Microsoft.VCRedist.x64', $cut, '14.42.34433.0')
        )
        $apps = @(Get-AppsFromCli)
        ($apps | Where-Object Installed -eq '14.40.33810.0').Latest | Should -Be '14.42.34433.0'
        ($apps | Where-Object Installed -eq '14.40.33810.0').UpdateAvailable | Should -BeTrue
        ($apps | Where-Object Installed -eq '14.38.33130.0').UpdateAvailable | Should -BeFalse
    }

    It 'ignores the less-than marker winget puts before some versions' {
        Use-WingetOutput -List @(
            , @('Tool', 'Contoso.Tool', '< 2.0', '')
            , @('Tool', 'Contoso.Tool', '3.0', '')
        ) -Upgrade @(
            , @('Tool', 'Contoso.Tool', '2.0', '3.0')
        )
        $apps = @(Get-AppsFromCli)
        ($apps | Where-Object Installed -eq '< 2.0').UpdateAvailable | Should -BeTrue
        ($apps | Where-Object Installed -eq '3.0').UpdateAvailable | Should -BeFalse
    }

    It 'falls back to the Id for a single installed copy whose version reads differently' {
        Use-WingetOutput -List @(, @('Tool', 'Contoso.Tool', '2.0-beta', '')) -Upgrade @(, @('Tool', 'Contoso.Tool', '2.0 beta', '3.0'))
        $app = Get-AppsFromCli
        $app.UpdateAvailable | Should -BeTrue
        $app.Latest | Should -Be '3.0'
    }

    It 'keeps same-Id rows with different names apart (OLE DB 18 and 19)' {
        Use-WingetOutput -List @(
            , @('Microsoft OLE DB Driver for SQL Server', 'Microsoft.msoledbsql', '18.7.2.0', '')
            , @('Microsoft OLE DB Driver 19 for SQL Server', 'Microsoft.msoledbsql', '19.3.5.0', '')
        ) -Upgrade @(
            , @('Microsoft OLE DB Driver for SQL Server', 'Microsoft.msoledbsql', '18.7.2.0', '18.7.4.0')
        )
        $apps = @(Get-AppsFromCli)
        $apps.Count | Should -Be 2
        $v18 = $apps | Where-Object Installed -eq '18.7.2.0'
        $v19 = $apps | Where-Object Installed -eq '19.3.5.0'
        $v18.Name | Should -Be 'Microsoft OLE DB Driver for SQL Server'
        $v18.UpdateAvailable | Should -BeTrue
        $v18.Latest | Should -Be '18.7.4.0'
        $v19.Name | Should -Be 'Microsoft OLE DB Driver 19 for SQL Server'
        $v19.UpdateAvailable | Should -BeFalse
        $v19.Latest | Should -Be '19.3.5.0'
    }
}

Describe 'Get-AppsFromCli held updates' {
    It 'marks an app held when list shows a newer version that upgrade skips' {
        $script:listTable = @(
            '{0,-20}{1,-20}{2,-10}{3,-10}{4}' -f 'Name', 'Id', 'Version', 'Available', 'Source'
            '-' * 66
            '{0,-20}{1,-20}{2,-10}{3,-10}{4}' -f 'Pinned App', 'Pinned.App', '1.0', '2.0', 'winget'
            '{0,-20}{1,-20}{2,-10}{3,-10}{4}' -f 'Other App', 'Other.App', '1.0', '1.0.0', 'winget'
        )
        Mock winget { if ($args[0] -eq 'list') { $script:listTable } else { 'No installed package found matching input criteria.' } }
        $apps = @(Get-AppsFromCli)
        $apps[0].Held | Should -BeTrue
        $apps[0].UpdateAvailable | Should -BeFalse
        $apps[0].Latest | Should -Be '2.0'
        $apps[1].Held | Should -BeFalse
    }
}

Describe 'Get-AppsFromModule with an Id installed twice' {
    It 'maps each installed copy on its own' {
        Mock Import-Module { } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' }
        Mock Get-WinGetPackage {
            [pscustomobject]@{ Name = 'Microsoft OLE DB Driver for SQL Server'; Id = 'Microsoft.msoledbsql'; InstalledVersion = '18.7.2.0'; IsUpdateAvailable = $true; AvailableVersions = @('19.3.5.0', '18.7.4.0') }
            [pscustomobject]@{ Name = 'Microsoft OLE DB Driver 19 for SQL Server'; Id = 'Microsoft.msoledbsql'; InstalledVersion = '19.3.5.0'; IsUpdateAvailable = $false; AvailableVersions = @('19.3.5.0') }
        }
        $apps = @(Get-AppsFromModule)
        $apps.Count | Should -Be 2
        $apps[0].UpdateAvailable | Should -BeTrue
        $apps[0].Latest | Should -Be '19.3.5.0'
        $apps[1].UpdateAvailable | Should -BeFalse
        $apps[1].Latest | Should -Be '19.3.5.0'
    }
}

Describe 'Get-AppsFromModule' {
    BeforeEach {
        Mock Import-Module { } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' }
        Mock Get-WinGetPackage {
            [pscustomobject]@{ Name = '7-Zip'; Id = '7zip.7zip'; InstalledVersion = '23.01'; IsUpdateAvailable = $true; AvailableVersions = @('24.08', '24.07') }
            [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; InstalledVersion = '2.47.0'; IsUpdateAvailable = $false; AvailableVersions = @('2.47.0') }
            [pscustomobject]@{ Name = 'Local'; Id = 'ARP\Machine\X64\Local'; InstalledVersion = '1.0'; IsUpdateAvailable = $false; AvailableVersions = @() }
        }
    }

    It 'maps module packages to inventory rows' {
        $apps = @(Get-AppsFromModule)
        $apps.Count | Should -Be 3
        $apps[0].Name | Should -Be '7-Zip'
        $apps[0].Installed | Should -Be '23.01'
        $apps[0].Latest | Should -Be '24.08'
        $apps[0].UpdateAvailable | Should -BeTrue
        $apps[1].Latest | Should -Be '2.47.0'
        $apps[1].UpdateAvailable | Should -BeFalse
        $apps[2].Latest | Should -Be '1.0'
        Should -Invoke Import-Module -Times 1 -Exactly
    }
}

Describe 'Get-AppInventory' {
    BeforeEach {
        Mock Get-AppsFromCli { [pscustomobject]@{ Name = 'cli' } }
        Mock Get-AppsFromModule { [pscustomobject]@{ Name = 'module' } }
        Mock Install-Module { }
        Mock Read-Host { 'n' }
        Mock Test-InteractiveSession { $true }
        Mock Write-Notice { }
    }

    It 'uses the module when it is installed' {
        Mock Get-Module { [pscustomobject]@{ Name = 'Microsoft.WinGet.Client' } } -ParameterFilter { $ListAvailable }
        (Get-AppInventory).Name | Should -Be 'module'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'falls back to the CLI when the module is missing and the user answers N' {
        Mock Get-Module { } -ParameterFilter { $ListAvailable }
        (Get-AppInventory).Name | Should -Be 'cli'
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'skips the module and the prompt with -UseCli' {
        $UseCli = $true
        Mock Get-Module { } -ParameterFilter { $ListAvailable }
        (Get-AppInventory).Name | Should -Be 'cli'
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Get-Module -Times 0 -Exactly
    }

    It 'falls back to the CLI when the module install fails after answering y' {
        Mock Get-Module { } -ParameterFilter { $ListAvailable }
        Mock Read-Host { 'y' }
        Mock Install-Module { throw 'No match was found for the specified search criteria' }
        (Get-AppInventory).Name | Should -Be 'cli'
        Should -Invoke Install-Module -Times 1 -Exactly
        Should -Invoke Write-Notice -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not install' }
    }

    It 'uses the module after a successful install' {
        $script:installed = $false
        Mock Get-Module { if ($script:installed) { [pscustomobject]@{ Name = 'Microsoft.WinGet.Client' } } } -ParameterFilter { $ListAvailable }
        Mock Read-Host { 'y' }
        Mock Install-Module { $script:installed = $true }
        (Get-AppInventory).Name | Should -Be 'module'
    }

    It 'does not prompt with -Json and says why on the notice channel' {
        $Json = $true
        Mock Get-Module { } -ParameterFilter { $ListAvailable }
        (Get-AppInventory).Name | Should -Be 'cli'
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Write-Notice -Times 1 -Exactly -ParameterFilter { $Message -match 'module not found' }
    }

    It 'does not prompt when the session is not interactive' {
        Mock Test-InteractiveSession { $false }
        Mock Get-Module { } -ParameterFilter { $ListAvailable }
        (Get-AppInventory).Name | Should -Be 'cli'
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Write-Notice -Times 1 -Exactly
    }
}

Describe 'Write-Notice' {
    It 'writes to stderr, not the output or warning streams, under -Json' {
        $Json = $true
        $saved = [Console]::Error
        $err = New-Object System.IO.StringWriter
        try {
            [Console]::SetError($err)
            $out = @(Write-Notice 'hello' 3>&1)
        } finally { [Console]::SetError($saved) }
        $out.Count | Should -Be 0
        $err.ToString() | Should -Match 'WARNING: hello'
    }

    It 'uses the warning stream otherwise' {
        $Json = $false
        $out = @(Write-Notice 'hello' 3>&1)
        "$($out[0])" | Should -Be 'hello'
    }
}

Describe 'Running non-interactively in a child process' {
    BeforeAll {
        # Start the same PowerShell that runs the tests (pwsh or Windows PowerShell 5.1) with
        # a fake winget first on PATH that prints the fixtures.
        $exe = (Get-Process -Id $PID).Path
        $shimDir = Join-Path $TestDrive 'shim'
        $null = New-Item -ItemType Directory -Path $shimDir -Force
        Copy-Item (Join-Path $FixtureDir 'winget-list.txt') (Join-Path $shimDir 'list.txt')
        Copy-Item (Join-Path $FixtureDir 'winget-upgrade.txt') (Join-Path $shimDir 'upgrade.txt')
        if ($env:OS -eq 'Windows_NT') {
            Set-Content -Path (Join-Path $shimDir 'winget.cmd') -Encoding Ascii -Value @(
                '@echo off'
                'if "%1"=="list" type "%~dp0list.txt"'
                'if "%1"=="upgrade" type "%~dp0upgrade.txt"'
            )
        } else {
            $sh = Join-Path $shimDir 'winget'
            [IO.File]::WriteAllText($sh, "#!/bin/sh`ncat `"`$(dirname `"`$0`")/`$1.txt`"`n")
            & chmod +x $sh
        }
        $moduleInstalled = [bool](Get-Module -ListAvailable Microsoft.WinGet.Client)

        function Invoke-Child([string[]]$Arguments) {
            $in = Join-Path $TestDrive 'in.txt'
            Set-Content -Path $in -Value 'N' -Encoding Ascii
            $outFile = Join-Path $TestDrive 'out.txt'
            $errFile = Join-Path $TestDrive 'err.txt'
            $savedPath = $env:PATH
            try {
                $env:PATH = $shimDir + [IO.Path]::PathSeparator + $env:PATH
                $p = Start-Process -FilePath $exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
                    -RedirectStandardInput $in -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            } finally { $env:PATH = $savedPath }
            [pscustomobject]@{
                ExitCode = $p.ExitCode
                Out      = [string](Get-Content -LiteralPath $outFile -Raw)
                Err      = [string](Get-Content -LiteralPath $errFile -Raw)
            }
        }
    }

    It "keeps stdout pure JSON when 'N' is piped in with -Json" {
        $r = Invoke-Child @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"", '-Json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'Install it|module not found'
        $apps = @(($r.Out | ConvertFrom-Json) | ForEach-Object { $_ })
        $apps.Count | Should -BeGreaterThan 0
        if (-not $moduleInstalled) {
            $apps.Count | Should -Be 6
            $r.Err | Should -Match 'WARNING: Microsoft\.WinGet\.Client module not found'
        }
    }

    It 'skips the prompt under -NonInteractive' {
        $r = Invoke-Child @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'Install it for the current user'
        $r.Out | Should -Match 'Summary: '
    }

    It 'sends the CSV export message to stderr under -Json' {
        $csv = Join-Path $TestDrive 'apps.csv'
        $r = Invoke-Child @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"", '-UseCli', '-Json', '-ExportCsv', "`"$csv`"")
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'Exported'
        @(($r.Out | ConvertFrom-Json) | ForEach-Object { $_ }).Count | Should -Be 6
        $r.Err | Should -Match 'Exported 6 row\(s\)'
        Test-Path $csv | Should -BeTrue
    }

    It 'leaves the caller session settings alone when run through a scriptblock or iex' {
        # The README one-liners run the script text in the caller's session. Strict mode and
        # ErrorActionPreference = Stop must not stay switched on there afterwards.
        $driver = Join-Path $TestDrive 'driver.ps1'
        Set-Content -Path $driver -Encoding Ascii -Value @(
            '$ErrorActionPreference = ''Continue'''
            '$s = [IO.File]::ReadAllText($env:AUC_SCRIPT)'
            '$null = & ([scriptblock]::Create($s)) -UseCli -Json'
            '"scriptblock eap=$ErrorActionPreference"'
            'try { $null = $notSetAnywhere; ''scriptblock strict=off'' } catch { ''scriptblock strict=on'' }'
            '$null = $s | Invoke-Expression'
            '"iex eap=$ErrorActionPreference"'
            'try { $null = $notSetAnywhere2; ''iex strict=off'' } catch { ''iex strict=on'' }'
        )
        $env:AUC_SCRIPT = $ScriptPath
        try {
            $r = Invoke-Child @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$driver`"")
        } finally { Remove-Item Env:AUC_SCRIPT }
        $r.ExitCode | Should -Be 0
        $lines = @($r.Out -split '\r?\n' | Where-Object { $_ -match '^(scriptblock|iex) ' })
        $lines | Should -Be @('scriptblock eap=Continue', 'scriptblock strict=off', 'iex eap=Continue', 'iex strict=off')
    }

    It 'reports a -NonInteractive session as not interactive' {
        $cmd = ". '$ScriptPath'; Test-InteractiveSession"
        & $exe -NoProfile -NonInteractive -Command $cmd | Should -Be 'False'
    }
}

Describe 'Limit-Text' {
    It 'returns text that fits unchanged' {
        Limit-Text 'abc' 5 | Should -Be 'abc'
        Limit-Text 'abcde' 5 | Should -Be 'abcde'
    }

    It 'truncates long text to the limit with a tilde' {
        Limit-Text 'abcdefgh' 5 | Should -Be 'abcd~'
    }

    It 'handles empty text' {
        Limit-Text '' 5 | Should -Be ''
    }
}

Describe 'Check-AppUpdates.ps1 end to end' {
    BeforeEach {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock winget {
            $calls.Add(($args -join ' '))
            switch ($args[0]) {
                'list' { Get-Fixture 'winget-list.txt' }
                'upgrade' { Get-Fixture 'winget-upgrade.txt' }
            }
        }
        function ConvertFrom-JsonArray([string[]]$Text) {
            $parsed = ($Text -join "`n") | ConvertFrom-Json
            @($parsed | ForEach-Object { $_ })
        }
    }

    AfterEach {
        # Listing only: never a targeted upgrade, never an install.
        $calls | ForEach-Object {
            $_ | Should -Match '^(list|upgrade) '
            $_ | Should -Not -Match '--id|install'
        }
    }

    It 'writes every app as JSON with -UseCli -Json' {
        $apps = ConvertFrom-JsonArray (& $ScriptPath -UseCli -Json)
        $apps.Count | Should -Be 6
        $apps.Name | Should -Be ($apps.Name | Sort-Object)
        ($apps | Where-Object Id -eq 'Google.Chrome').Status | Should -Be 'Update available'
        ($apps | Where-Object Id -eq 'Git.Git').Status | Should -Be 'Up to date'
        $calls.Count | Should -Be 2
    }

    It 'writes only apps with updates with -UpdatesOnly' {
        $apps = ConvertFrom-JsonArray (& $ScriptPath -UseCli -Json -UpdatesOnly)
        $apps.Id | Should -Be @('7zip.7zip', 'Google.Chrome', 'Microsoft.VCRedist.2015+.x64')
        $apps[0].Installed | Should -Be '23.01'
        $apps[0].Latest | Should -Be '24.08'
    }

    It 'prints the table, a summary and upgrade hints' {
        $out = & $ScriptPath -UseCli 6>&1 | Out-String
        $out | Should -Match 'Summary: 6 apps checked, 3 update\(s\) available, 3 up to date\.'
        $out | Should -Match '  winget upgrade --id 7zip\.7zip'
        $out | Should -Match 'Up to date'
    }

    It 'says there is nothing to show with -UpdatesOnly when every app is up to date' {
        Mock winget {
            $calls.Add(($args -join ' '))
            switch ($args[0]) {
                'list' { Get-Fixture 'winget-list-no-available.txt' }
                'upgrade' { Get-Fixture 'winget-upgrade-none.txt' }
            }
        }
        $out = & $ScriptPath -UseCli -UpdatesOnly 6>&1 | Out-String
        $out | Should -Match 'No applications to show\.'
        $out | Should -Match 'Summary: 2 apps checked, 0 update\(s\) available, 2 up to date\.'
        # An empty JSON array; Windows PowerShell 5.1 writes it with a blank line inside.
        (& $ScriptPath -UseCli -UpdatesOnly -Json | Out-String).Trim() | Should -Match '^\[\s*\]$'
    }

    It 'exports the shown rows to CSV' {
        $csv = Join-Path $TestDrive 'updates.csv'
        $null = & $ScriptPath -UseCli -UpdatesOnly -ExportCsv $csv 6>&1
        $rows = @(Import-Csv $csv)
        $rows.Count | Should -Be 3
        $rows[0].PSObject.Properties.Name | Should -Be @('Name', 'Id', 'Installed', 'Latest', 'Status')
    }

    It 'reports a pinned app as Update held, outside -UpdatesOnly and the update count' {
        $pinned = '{0,-39}{1,-35}{2,-17}{3,-15}{4}' -f 'Pinned App', 'Pinned.App', '1.0', '2.0', 'winget'
        $heldList = @(Get-Fixture 'winget-list.txt') + $pinned
        Mock winget {
            $calls.Add(($args -join ' '))
            if ($args[0] -eq 'list') { $heldList } else { Get-Fixture 'winget-upgrade.txt' }
        }
        $apps = ConvertFrom-JsonArray (& $ScriptPath -UseCli -Json)
        $app = $apps | Where-Object Id -eq 'Pinned.App'
        $app.Status | Should -Be 'Update held'
        $app.Latest | Should -Be '2.0'
        (ConvertFrom-JsonArray (& $ScriptPath -UseCli -Json -UpdatesOnly)).Id | Should -Not -Contain 'Pinned.App'
        $out = & $ScriptPath -UseCli 6>&1 | Out-String
        $out | Should -Match 'Summary: 7 apps checked, 3 update\(s\) available, 1 held, 3 up to date\.'
        $out | Should -Not -Match '--id Pinned\.App'
    }
}
