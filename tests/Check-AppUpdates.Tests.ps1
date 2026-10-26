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

    It 'throws when winget is not installed' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
        { Get-AppsFromCli } | Should -Throw '*winget was not found*'
        $calls.Count | Should -Be 0
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
}
