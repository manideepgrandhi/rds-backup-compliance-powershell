# Parity.Tests.ps1 - side by side with the Bash tool (rds_backup_compliance_report.sh v1.6.0) on the same mock fleet
# and frozen clock: every output file (compliance CSV, _backups.csv, _orphaned_snapshots.csv, _manual_older_than_<N>d.csv,
# JSON, text, HTML page data) must be identical; only the tool version may differ (tests/parity/compare.py).
# Runs when RDS_BCR_BASH_DIR points at a clone of manideepgrandhi/rds-backup-compliance (CI on Linux); skipped otherwise.
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:NoBash = -not (Get-BcrBashDir)
    $script:Cases = @(
        @{ name = 'prod + nonprod + dev, all formats, manual > 7d, yearly 2'; b = @('-P', 'prod,nonprod,dev', '-A', '--manual-older-than', '7', '--yearly', '2'); p = @('-ProfileName', 'prod,nonprod,dev', '-AllRegions', '-ManualOlderThan', '7', '-Yearly', '2') }
        @{ name = 'changed schedule (weekly 3, monthly 6, first-mon, sun, tolerance 2)'; b = @('-P', 'prod', '-A', '--weekly', '3', '--monthly', '6', '--monthly-rule', 'first-mon', '--weekly-weekday', 'sun', '--tolerance-days', '2'); p = @('-ProfileName', 'prod', '-AllRegions', '-Weekly', '3', '-Monthly', '6', '-MonthlyRule', 'first-mon', '-WeeklyWeekday', 'sun', '-ToleranceDays', '2') }
        @{ name = 'non-compliant only, UTC'; b = @('-P', 'prod,nonprod', '-A', '--non-compliant-only', '--tz', 'UTC'); p = @('-ProfileName', 'prod,nonprod', '-AllRegions', '-NonCompliantOnly', '-Tz', 'UTC') }
        @{ name = 'replica exemptions'; b = @('-P', 'prod,dev', '-A', '--replica-exempt-engines', 'aurora-*,oracle-*'); p = @('-ProfileName', 'prod,dev', '-AllRegions', '-ReplicaExemptEngines', 'aurora-*,oracle-*') }
        @{ name = 'strict retention settings'; b = @('-P', 'prod', '-r', 'us-east-1', '--weekly-retention-days', '35', '--monthly-retention-days', '400', '--daily-retention-days', '2', '--retention-tolerance-days', '0'); p = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-WeeklyRetentionDays', '35', '-MonthlyRetentionDays', '400', '-DailyRetentionDays', '2', '-RetentionToleranceDays', '0') }
        @{ name = 'filters and price'; b = @('-P', 'prod', '-A', '-e', 'aurora-*', '-i', 'orders-*,analytics-*', '--snapshot-price-per-gb', '0.05'); p = @('-ProfileName', 'prod', '-AllRegions', '-Engine', 'aurora-*', '-Identifier', 'orders-*,analytics-*', '-SnapshotPricePerGb', '0.05') }
        @{ name = 'scenario backupdeny'; s = 'backupdeny'; b = @('-P', 'prod', '-A'); p = @('-ProfileName', 'prod', '-AllRegions') }
        @{ name = 'scenario globaldeny'; s = 'globaldeny'; b = @('-P', 'prod', '-A'); p = @('-ProfileName', 'prod', '-AllRegions') }
        @{ name = 'scenario snapdeny'; s = 'snapdeny'; b = @('-P', 'prod', '-A'); p = @('-ProfileName', 'prod', '-AllRegions') }
        @{ name = 'scenario rpquirks'; s = 'rpquirks'; b = @('-P', 'prod', '-A'); p = @('-ProfileName', 'prod', '-AllRegions') }
        @{ name = 'scenario empty'; s = 'empty'; b = @('-P', 'prod', '-A'); p = @('-ProfileName', 'prod', '-AllRegions') }
    )
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Py = Get-BcrPython
    function Compare-Dirs { param([string]$A, [string]$B) $o = & $Py (Join-Path $PSScriptRoot 'parity/compare.py') $A $B; return @{ ok = ($LASTEXITCODE -eq 0); out = ($o -join "`n") } }
    $script:Exc = Join-Path (New-BcrTestDir 'pexc') 'ok.conf'
    [System.IO.File]::WriteAllText($Exc, "111111111111 | legacy-mysql | backup | 2027-03-31 | Decommission in Q1 (CHG-1234)`n111111111111 | reports-pg | patch,backup | 2026-10-03 | Vendor app freeze | ticket A|B`n111111111111|Orders-Aurora-PG15|BACKUP|2027-01-01|<b>Old</b> migration window`n111111111111 | shop-dr-mysql | backup | 2026-10-02 | =DR rebuild`n111111111111 | gone-db | backup | 2027-01-01 | Retired server`n")
}

Describe 'same output as the Bash tool' -Skip:$NoBash {
    It '<name>' -ForEach $Cases {
        $sc = if ($s) { $s } else { 'fleet' }
        $bd = New-BcrTestDir 'pb'; $pd = New-BcrTestDir 'pp'
        $rb = Invoke-BcrBash -Arguments ($b + @('-F', 'csv,html,json,text', '-o', $bd)) -Scenario $sc
        $rp = Invoke-Bcr -Arguments ($p + @('-Format', 'csv,html,json,text', '-OutputDir', $pd)) -Scenario $sc
        $rp.ExitCode | Should -Be $rb.ExitCode
        $c = Compare-Dirs $bd $pd
        $c.ok | Should -BeTrue -Because $c.out
    }
    It 'exceptions (all files and the log lines)' {
        $e = @{ RDS_BCR_EXC_NOW = '1791000000' }
        $bd = New-BcrTestDir 'pbe'; $pd = New-BcrTestDir 'ppe'
        $rb = Invoke-BcrBash -Arguments @('-P', 'prod,nonprod', '-A', '-F', 'csv,html,json,text', '-o', $bd, '--exceptions', $Exc, '--manual-older-than', '90') -Env $e
        $rp = Invoke-Bcr -Arguments @('-ProfileName', 'prod,nonprod', '-AllRegions', '-Format', 'csv,html,json,text', '-OutputDir', $pd, '-Exceptions', $Exc, '-ManualOlderThan', '90') -Env $e
        $c = Compare-Dirs $bd $pd; $c.ok | Should -BeTrue -Because $c.out
        $norm = { param($t, $dir) @(($t -split "`n") | Where-Object { $_ -match '\[(INFO|WARN|WARNING|ERROR)\]' } | ForEach-Object { ($_ -replace '^[0-9: -]+', '').Replace($dir, 'OUT') -replace '\(\d+s\)$', '' }) -join "`n" }
        (& $norm $rp.Stderr $pd) | Should -BeExactly (& $norm $rb.Stderr $bd)
    }
    It 'merge: Bash --save-data + --merge vs -SaveData + -Merge' {
        $sb = New-BcrTestDir 'sb'; $sp = New-BcrTestDir 'sp'
        foreach ($x in @(@('prod', '-A'), @('nonprod', '-r', 'ap-south-1'), @('dev', '-r', 'eu-west-1'))) {
            $null = Invoke-BcrBash -Arguments (@('-P', $x[0]) + $x[1..($x.Count - 1)] + @('--save-data', (Join-Path $sb "$($x[0]).json"), '-F', 'json'))
            $pa = @('-ProfileName', $x[0]) + $(if ($x[1] -eq '-A') { @('-AllRegions') } else { @('-Region', $x[2]) })
            $null = Invoke-Bcr -Arguments ($pa + @('-SaveDataFile', (Join-Path $sp "$($x[0]).json"), '-Format', 'json'))
        }
        $bd = New-BcrTestDir 'pbm'; $pd = New-BcrTestDir 'ppm'
        $null = Invoke-BcrBash -Arguments @('--merge', $sb, '-F', 'csv,html,json,text', '-o', $bd)
        $null = Invoke-Bcr -Arguments @('-Merge', $sp, '-Format', 'csv,html,json,text', '-OutputDir', $pd)
        $c = Compare-Dirs $bd $pd; $c.ok | Should -BeTrue -Because $c.out
    }
    It 'text report on stdout' {
        $rb = Invoke-BcrBash -Arguments @('-P', 'prod', '-r', 'us-east-1,us-west-2')
        $rp = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2')
        $rp.Stdout | Should -BeExactly $rb.Stdout
    }
}
