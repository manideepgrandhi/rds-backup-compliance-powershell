# Cli.Tests.ps1 - parameters, -Help / -Version, validation and exit codes, the config file, read-only calls,
# -DryRun, -Verbose, -LogFile, -KeepWorkdir, file naming, the HTML file, -SaveData and nothing written into the repo.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    function Run { param([string[]]$A, [string]$S = 'fleet', [hashtable]$E = @{}, [string]$W) Invoke-Bcr -Arguments $A -Scenario $S -Env $E -WorkingDirectory $W }
    $script:RepoBefore = @(Get-ChildItem -LiteralPath (Get-BcrTestRoot) -Recurse -Force -File | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | ForEach-Object FullName | Sort-Object)
}

Describe 'help and version' {
    It '-Version' { $r = Run @('-Version'); $r.ExitCode | Should -Be 0; $r.Stdout.Trim() | Should -Be 'Invoke-RdsBackupCompliance.ps1 1.0.0' }
    It '-Help lists every parameter group and the read-only calls' {
        $r = Run @('-Help'); $r.ExitCode | Should -Be 0
        foreach ($p in '-ProfileName', '-AllRegions', '-WeeklyDays', '-MonthlyRule', '-ReplicaExemptEngines', '-Exceptions', '-ManualOlderThan', '-SnapshotPricePerGb', '-SaveData', '-Merge', '-AlertEmail', '-Parallel', '-DryRun', 'list-recovery-points-by-backup-vault', 'Exit codes') {
            $r.Stdout | Should -Match ([regex]::Escape($p))
        }
    }
    It 'Get-Help works on the script' {
        $h = Get-Help (Join-Path (Get-BcrTestRoot) 'Invoke-RdsBackupCompliance.ps1') -Full | Out-String
        $h | Should -Match 'Backup compliance report'
        $h | Should -Match '-AllRegions'
    }
}

Describe 'validation (exit 1 before any AWS call)' {
    BeforeAll { $script:Log = Join-Path (New-BcrTestDir 'v') 'calls.jsonl' }
    It '<name>' -ForEach @(
        @{ name = 'unknown parameter'; a = @('-Nope'); m = 'Unknown option: -Nope' }
        @{ name = 'several formats without -OutputDir'; a = @('-Region', 'us-east-1', '-Format', 'csv,html'); m = 'Several formats need -OutputDir' }
        @{ name = 'unknown format'; a = @('-Format', 'xml'); m = "Unknown format 'xml'" }
        @{ name = 'weekly days reversed'; a = @('-WeeklyDays', '70-60'); m = 'WeeklyDays' }
        @{ name = 'weekly not a number'; a = @('-Weekly', 'x'); m = 'Weekly' }
        @{ name = 'weekly and monthly ranges overlap'; a = @('-WeeklyDays', '25-40', '-MonthlyDays', '30-400'); m = 'MonthlyDays' }
        @{ name = 'tolerance too large'; a = @('-ToleranceDays', '4'); m = 'ToleranceDays' }
        @{ name = 'bad weekday'; a = @('-WeeklyWeekday', 'saturday'); m = 'WeeklyWeekday' }
        @{ name = 'bad monthly rule'; a = @('-MonthlyRule', 'last-sun'); m = 'MonthlyRule' }
        @{ name = '-Merge with -ProfileName'; a = @('-Merge', 'x.json', '-ProfileName', 'prod'); m = 'Merge' }
        @{ name = 'parallel 0'; a = @('-Parallel', '0'); m = 'Parallel' }
        @{ name = 'parallel x'; a = @('-Parallel', 'x'); m = 'Parallel' }
        @{ name = 'price not a number'; a = @('-SnapshotPricePerGb', 'cheap'); m = 'SnapshotPricePerGb' }
        @{ name = 'weekly retention not a number'; a = @('-WeeklyRetentionDays', 'x'); m = 'WeeklyRetentionDays' }
        @{ name = 'unknown time zone'; a = @('-Tz', 'Nowhere/Zone'); m = 'Unknown time zone' }
        @{ name = 'bad region'; a = @('-Region', 'us east'); m = 'region' }
        @{ name = '-SaveDataFile not .json'; a = @('-SaveDataFile', 'x.txt'); m = '\.json' }
        @{ name = '-AlertEmail without SMTP server'; a = @('-AlertEmail', 'a@example.com'); m = 'AlertSmtpServer' }
        @{ name = '-AlertTest without -AlertEmail'; a = @('-AlertTest'); m = 'AlertEmail' }
        @{ name = 'config file missing'; a = @('-ConfigFile', 'does-not-exist.conf'); m = 'Config file not readable' }
    ) {
        $r = Run ($a + @('-ProfileName', 'prod')) -E @{ MOCK_LOG = $Log }
        if ($a -contains '-Merge') { $r = Run $a -E @{ MOCK_LOG = $Log } }
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match '\[ERROR\]'
        $r.Stderr | Should -Match $m
        @(Get-BcrMockLog $Log).Count | Should -Be 0
    }
    It 'no region: exit 2' { (Run @('-ProfileName', 'prod')).ExitCode | Should -Be 2 }
    It 'aws CLI missing: exit 2' {
        $r = Run @('-ProfileName', 'prod', '-Region', 'us-east-1') -E @{ PATH = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
        $r.ExitCode | Should -Be 2; $r.Stderr | Should -Match 'aws CLI not found'
    }
}

Describe 'config file' {
    BeforeAll { $script:D = New-BcrTestDir 'conf' }
    It 'CRLF, comments, both key spellings, parameters win over the file' {
        $c = Join-Path $D 'my conf.conf'
        [System.IO.File]::WriteAllText($c, "weekly = 6`r`n# comment`r`nregion=us-east-1`r`nidentifier = orders-*`r`nformat=json`r`n")
        $r = Run @('-ProfileName', 'prod', '-ConfigFile', $c); $r.ExitCode | Should -Be 0
        (Get-BcrRow (ConvertFrom-BcrJsonText $r.Stdout) 'orders-aurora-pg15').weekly.need | Should -Be 6
        $r = Run @('-ProfileName', 'prod', '-ConfigFile', $c, '-Weekly', '4')
        (Get-BcrRow (ConvertFrom-BcrJsonText $r.Stdout) 'orders-aurora-pg15').weekly.need | Should -Be 4
        $c2 = Join-Path $D 'ret.conf'
        Set-Content -LiteralPath $c2 -Value "WEEKLY_RETENTION_DAYS=35`nmonthly_retention_days=365`nretention-tolerance-days=1`nregion=us-east-1`nidentifier=orders-*`nformat=json"
        (Get-BcrRow (ConvertFrom-BcrJsonText (Run @('-ProfileName', 'prod', '-ConfigFile', $c2)).Stdout) 'orders-aurora-pg15').retention_mismatch | Should -Be ''
    }
    It 'snapshot price, profile, all-regions, parallel in the file' {
        $c = Join-Path $D 'p.conf'; Set-Content -LiteralPath $c -Value "snapshot_price_per_gb = 0.1`nregion=us-east-1`nformat=json"
        (ConvertFrom-BcrJsonText (Run @('-ProfileName', 'prod', '-ConfigFile', $c)).Stdout).orphan_totals.est_monthly_usd | Should -Be 70
        $c = Join-Path $D 'par.conf'; Set-Content -LiteralPath $c -Value "profile = prod`nall-regions = yes`nparallel = 2`nformat = json"
        $r = Run @('-ConfigFile', $c); $r.ExitCode | Should -Be 0; $r.Stderr | Should -Match 'up to 2 at a time'
    }
    It 'unknown key and credentials are refused with file:line' {
        $c = Join-Path $D 'bad.conf'; Set-Content -LiteralPath $c -Value "# x`nbogus=1"
        $r = Run @('-ConfigFile', $c); $r.ExitCode | Should -Be 1; $r.Stderr | Should -Match "bad\.conf:2: unknown key 'bogus'"
        $c = Join-Path $D 'cred.conf'; Set-Content -LiteralPath $c -Value 'aws_secret_access_key = abc'
        $r = Run @('-ConfigFile', $c); $r.ExitCode | Should -Be 1; $r.Stderr | Should -Match 'credentials are not accepted'
    }
    It 'the sample config changes nothing (every baseline commented)' {
        $ex = Join-Path (Get-BcrTestRoot) 'rds_backup_compliance_report.conf.example'
        [System.IO.File]::ReadAllLines($ex) | Where-Object { $_ -match '^[a-z_-]+\s*=' } | Should -BeNullOrEmpty
        $a = ConvertFrom-BcrJsonText (Run @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2', '-Format', 'json')).Stdout
        $b = ConvertFrom-BcrJsonText (Run @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2', '-Format', 'json', '-ConfigFile', $ex)).Stdout
        ($b.thresholds | ConvertTo-Json -Depth 5) | Should -Be ($a.thresholds | ConvertTo-Json -Depth 5)
        (@($b.rows | ForEach-Object { "$($_.identifier)=$($_.status)" }) -join ';') | Should -Be (@($a.rows | ForEach-Object { "$($_.identifier)=$($_.status)" }) -join ';')
    }
}

Describe 'read-only AWS access' {
    BeforeAll {
        $script:Log = Join-Path (New-BcrTestDir 'ro') 'calls.jsonl'
        $script:R = Run @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json') -E @{ MOCK_LOG = $Log }
        $script:Calls = @(Get-BcrMockLog $Log)
    }
    It 'only describe / list / get calls' {
        $R.ExitCode | Should -Be 0
        foreach ($c in $Calls) { $op = @($c | Where-Object { -not $_.StartsWith('--') })[1]; $op | Should -Match '^(describe-|list-|get-caller-identity|get$)' }
    }
    It 'snapshots with --include-shared, also in a region without databases' {
        @($Calls | Where-Object { $_ -contains 'describe-db-snapshots' }) | ForEach-Object { $_ | Should -Contain '--include-shared' }
        @($Calls | Where-Object { $_ -contains 'describe-db-cluster-snapshots' -and $_ -contains 'ca-central-1' }).Count | Should -Be 1
    }
    It 'global clusters only where there are clusters; backup vaults only where there are databases' {
        @($Calls | Where-Object { $_ -contains 'describe-global-clusters' } | ForEach-Object { $_[[array]::IndexOf($_, '--region') + 1] } | Sort-Object) | Should -Be @('us-east-1', 'us-west-2')
        @($Calls | Where-Object { $_ -contains 'list-backup-vaults' -and $_ -contains 'ca-central-1' }).Count | Should -Be 0
    }
    It 'AWS calls line' { $R.Stderr | Should -Match "AWS calls: $($Calls.Count) \(0 failed\)" }
    It '-DryRun prints the calls and calls nothing' {
        $l2 = Join-Path (New-BcrTestDir 'dry') 'calls.jsonl'
        $r = Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-DryRun') -E @{ MOCK_LOG = $l2 }
        $r.ExitCode | Should -Be 0
        @(Get-BcrMockLog $l2).Count | Should -Be 0
        $r.Stdout | Should -Match 'DRY-RUN: aws rds describe-db-clusters'
        $r.Stdout | Should -Match 'DRY-RUN: aws iam list-account-aliases'
        $r.Stdout | Should -Match 'DRY-RUN: aws backup list-backup-vaults'
    }
}

Describe 'files, logs and verbose' {
    BeforeAll {
        $script:O = New-BcrTestDir 'files'
        $script:Lg = Join-Path $O 'run.log'
        $script:R = Run @('-ProfileName', 'prod', '-AllRegions', '-Format', 'csv,html,json,text', '-OutputDir', $O, '-SaveData', '-LogFile', $Lg)
        $script:Html = [System.IO.File]::ReadAllText((Get-BcrFile $O '\.html$'))
    }
    It 'every format with account and UTC stamp in the name' {
        foreach ($e in 'csv', 'html', 'json', 'txt') { Get-BcrFile $O "^rds_backup_compliance_111111111111_20261114_100000\.$e$" | Should -Exist }
    }
    It 'region summary; empty regions not listed one by one' {
        $R.Stderr | Should -Match '(?m)111111111111: 5 regions scanned, 2 empty: ap-south-1, eu-west-1$'
        $R.Stderr | Should -Not -Match 'ap-south-1: \(empty\)'
        $R.Stderr | Should -Match '\[[0-9]/5\] us-east-1: [0-9]+ clusters'
    }
    It '-Verbose lists the empty regions too' {
        $r = Run @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json', '-Verbose')
        $r.Stderr | Should -Match '\[[0-9]/5\] ap-south-1: \(empty\)'
        $r.Stderr | Should -Match '5 regions scanned, 2 empty'
    }
    It '-LogFile gets the log lines' {
        $t = [System.IO.File]::ReadAllText($Lg)
        $t | Should -Match '\[INFO\] account 111111111111 \(profile prod\): 5 region\(s\)'
        $t | Should -Match 'resources: 8, non-compliant: 4'
    }
    It 'HTML: account in the title, no empty region, no script tag breakout' {
        $Html | Should -Match '<title>RDS backup compliance - prod-core \(111111111111\)</title>'
        $Html | Should -Not -Match 'ap-south-1'
        ([regex]::Matches($Html, '</script>')).Count | Should -Be 2
        $Html | Should -Match '<script id="data" type="application/json">'
    }
    It 'HTML header follows a changed config' {
        $d = New-BcrTestDir 'hc'
        $null = Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Daily', '9', '-Weekly', '3', '-WeeklyRetentionDays', '33', '-Monthly', '6', '-MonthlyRule', 'first-mon', '-Format', 'html', '-OutputDir', $d)
        $h = [System.IO.File]::ReadAllText((Get-BcrFile $d '\.html$'))
        $h | Should -Match '>Daily: last 9 days, newest within [0-9]*h, retention [0-9]*d<'
        $h | Should -Match '>Weekly: every Saturday, last 3, retention 33d '
        $h | Should -Match '>Monthly: first Monday, last 6 months, retention '
        $h | Should -Not -Match 'h-yearly'
    }
    It '-OutputDir FILE.html names the HTML file' {
        $d = New-BcrTestDir 'of'; $f = Join-Path $d 'my report.html'
        $r = Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-OutputDir', $f)
        $r.ExitCode | Should -Be 0; $f | Should -Exist
    }
    It 'relative -OutputDir is shown as a clean absolute path' {
        $d = New-BcrTestDir 'rel'; New-Item -ItemType Directory -Path (Join-Path $d 'sub') | Out-Null
        $r = Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv', '-OutputDir', './sub//../sub/') -W $d
        $r.Stderr | Should -Match '(?m)^Output \(3 files\):$'
        $r.Stderr | Should -Match ('(?m)^  ' + [regex]::Escape((Join-Path (Join-Path $d 'sub') 'rds_backup_compliance_111111111111_20261114_100000_backups.csv')) + '$')
    }
    It '-SaveData file: own schema, no ARNs, account name, snapshot-only regions' {
        $sd = ConvertFrom-BcrJsonText ([System.IO.File]::ReadAllText((Join-Path $O 'rds_backup_111111111111_20261114.json')))
        $sd.schema | Should -Be 'rds_backup_compliance_ps_data'; $sd.schema_version | Should -Be 1
        $sd.accounts[0].account | Should -Be '111111111111'; $sd.accounts[0].name | Should -Be 'prod-core'
        @($sd.regions | Where-Object status -EQ 'empty').Count | Should -Be 2
        @($sd.regions | Where-Object status -EQ 'snapshots only' | ForEach-Object region) | Should -Be @('ca-central-1')
        @($sd.orphans | ForEach-Object id | Sort-Object) | Should -Be @('analytics-aurora-final', 'crm-mysql-before-delete', 'eu-app-copy', 'orders-aurora-pg15-dr-copy', 'reports-pg-west', 'retired-oracle-final', 'vendor-copy', 'vendor-share-1')
        @($sd.resources | Where-Object { $_.ContainsKey('arn') }).Count | Should -Be 0
        [System.IO.File]::ReadAllText((Join-Path $O 'rds_backup_111111111111_20261114.json')) | Should -Not -Match 'arn:aws:rds'
    }
    It '-SaveDataFile with two accounts adds _<account>' {
        $d = New-BcrTestDir 'sdf'
        $r = Run @('-ProfileName', 'prod,nonprod', '-Region', 'us-east-1,ap-south-1', '-SaveDataFile', (Join-Path $d 'raw.json'), '-Format', 'json')
        $r.ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $d -File | ForEach-Object Name | Sort-Object) | Should -Be @('raw_111111111111.json', 'raw_222222222222.json')
    }
    It '-KeepWorkdir keeps the raw responses' {
        $r = Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-KeepWorkdir', '-Format', 'json')
        $m = [regex]::Match($r.Stderr, 'workdir kept: (.+)'); $m.Success | Should -BeTrue
        $w = $m.Groups[1].Value.Trim()
        @(Get-ChildItem -LiteralPath $w -File).Count | Should -BeGreaterThan 3
        Remove-Item -LiteralPath $w -Recurse -Force
    }
    It 'unwritable output: exit 4' {
        $d = New-BcrTestDir 'ro'; $f = Join-Path $d 'file'; Set-Content -LiteralPath $f -Value x
        (Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv', '-OutputDir', (Join-Path $f 'sub'))).ExitCode | Should -Be 4
    }
}

Describe 'repository hygiene' {
    It 'samples and examples use the fake account numbers only' {
        $root = Get-BcrTestRoot
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'samples') -File -Recurse) + @(Get-Item (Join-Path $root '*.example'))
        foreach ($f in $files) {
            foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f.FullName), '(?<![0-9])[0-9]{12}(?![0-9])')) { $m.Value | Should -BeIn '111111111111', '222222222222', '333333333333', '444444444444', '888888888888', '999999999999' }
        }
    }
    It 'nothing written into the repository by the tests' {
        $after = @(Get-ChildItem -LiteralPath (Get-BcrTestRoot) -Recurse -Force -File | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | ForEach-Object FullName | Sort-Object)
        @(Compare-Object $RepoBefore $after | Where-Object { $_.InputObject -notmatch '__pycache__|testResults\.xml' }).Count | Should -Be 0
    }
}
