# Merge.Tests.ps1 - -SaveData then -Merge: offline, zero AWS calls, compliance evaluated again, newer collection wins,
# several accounts in one report, bad input (exit 3), and the merged file names.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Now = Get-BcrTestNow
    $script:D = New-BcrTestDir 'merge'
    $script:Data = Join-Path $D 'data'; New-Item -ItemType Directory -Path $Data | Out-Null
    foreach ($p in @(@('prod', '-AllRegions'), @('nonprod', '-Region', 'ap-south-1'), @('dev', '-Region', 'eu-west-1'))) {
        $r = Invoke-Bcr -Arguments (@('-ProfileName', $p[0]) + $p[1..($p.Count - 1)] + @('-SaveData', '-OutputDir', $Data, '-Format', 'json'))
        if ($r.ExitCode -ne 0) { throw $r.Stderr }
    }
    Get-ChildItem -LiteralPath $Data -Filter 'rds_backup_compliance_*' | Remove-Item
    $script:Direct = ConvertFrom-BcrJsonText (Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json')).Stdout
}

Describe '-Merge' {
    It 'one data file per account' {
        @(Get-ChildItem -LiteralPath $Data -File | ForEach-Object Name | Sort-Object) | Should -Be @('rds_backup_111111111111_20261114.json', 'rds_backup_222222222222_20261114.json', 'rds_backup_333333333333_20261114.json')
    }
    It 'a merged account gives the same report as a direct scan, with zero AWS calls' {
        $log = Join-Path $D 'calls.jsonl'
        $r = Invoke-Bcr -Arguments @('-Merge', (Join-Path $Data 'rds_backup_111111111111_20261114.json'), '-Format', 'json') -Env @{ MOCK_LOG = $log }
        $r.ExitCode | Should -Be 0
        @(Get-BcrMockLog $log).Count | Should -Be 0
        $m = ConvertFrom-BcrJsonText $r.Stdout
        ($m.rows | ConvertTo-Json -Depth 30) | Should -Be ($Direct.rows | ConvertTo-Json -Depth 30)
        ($m.totals | ConvertTo-Json -Depth 10) | Should -Be ($Direct.totals | ConvertTo-Json -Depth 10)
        ($m.orphaned_snapshots | ConvertTo-Json -Depth 10) | Should -Be ($Direct.orphaned_snapshots | ConvertTo-Json -Depth 10)
        $r.Stderr | Should -Match 'merged 1 file\(s\): 111111111111'
    }
    It 'compliance is evaluated again with the merge-time settings' {
        $m = ConvertFrom-BcrJsonText (Invoke-Bcr -Arguments @('-Merge', $Data, '-Format', 'json', '-Weekly', '6')).Stdout
        (Get-BcrRow $m 'orders-aurora-pg15').weekly.need | Should -Be 6
        (Get-BcrRow $m 'orders-aurora-pg15').status | Should -Be 'NON-COMPLIANT'
    }
    It 'a directory: every account, one HTML file named by -OutputDir FILE.html (html is the default format)' {
        $f = Join-Path $D 'all accounts.html'
        $r = Invoke-Bcr -Arguments @('-Merge', $Data, '-OutputDir', $f)
        $r.ExitCode | Should -Be 0
        $h = [System.IO.File]::ReadAllText($f)
        $h | Should -Match '<title>RDS backup compliance - prod-core \(111111111111\), 222222222222, 333333333333</title>'
        $r.Stderr | Should -Match 'merged 3 file\(s\): 111111111111, 222222222222, 333333333333'
    }
    It 'files are named after the accounts; more than 3 accounts: merged_N_accounts' {
        $o = New-BcrTestDir 'mo'
        $null = Invoke-Bcr -Arguments @('-Merge', $Data, '-Format', 'csv,json', '-OutputDir', $o)
        Get-BcrFile $o '^rds_backup_compliance_111111111111_222222222222_333333333333_20261114_100000\.csv$' | Should -Exist
        $d4 = New-BcrTestDir 'd4'; Copy-Item (Join-Path $Data '*.json') $d4
        $t = [System.IO.File]::ReadAllText((Join-Path $d4 'rds_backup_333333333333_20261114.json')).Replace('333333333333', '444444444444')
        [System.IO.File]::WriteAllText((Join-Path $d4 'rds_backup_444444444444_20261114.json'), $t)
        $o4 = New-BcrTestDir 'mo4'
        $r = Invoke-Bcr -Arguments @('-Merge', $d4, '-Format', 'csv', '-OutputDir', $o4)
        $r.ExitCode | Should -Be 0
        Get-BcrFile $o4 '^rds_backup_compliance_merged_4_accounts_20261114_100000\.csv$' | Should -Exist
        @(Read-BcrCsv (Get-BcrFile $o4 '_100000\.csv$') | ForEach-Object account_id | Sort-Object -Unique) | Should -Be @('111111111111', '222222222222', '333333333333', '444444444444')
    }
    It 'same account twice: the newer collection wins, the older one is reported' {
        $old = New-BcrTestDir 'old'
        $e = @{ RDS_BCR_NOW = [string]($Now - 7 * 86400); MOCK_NOW = [string]($Now - 7 * 86400) }
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-SaveDataFile', (Join-Path $old 'prod_old.json'), '-Format', 'json') -Env $e
        $r.ExitCode | Should -Be 0
        foreach ($order in @(@((Join-Path $old 'prod_old.json'), (Join-Path $Data 'rds_backup_111111111111_20261114.json')), @((Join-Path $Data 'rds_backup_111111111111_20261114.json'), (Join-Path $old 'prod_old.json')))) {
            $r = Invoke-Bcr -Arguments (@('-Merge') + $order + @('-Format', 'json'))
            $r.ExitCode | Should -Be 0
            $r.Stderr | Should -Match ('account 111111111111: .*prod_old\.json \(collected 2026-11-07 10:00 UTC\) ignored, a newer collection wins')
            $m = ConvertFrom-BcrJsonText $r.Stdout
            @($m.accounts).Count | Should -Be 1; $m.accounts[0].collected_epoch | Should -Be $Now
            @($m.rows).Count | Should -Be @($Direct.rows).Count
            ($m.rows | ConvertTo-Json -Depth 30) | Should -Be ($Direct.rows | ConvertTo-Json -Depth 30)
        }
    }
    It 'an old collection alone is evaluated as of its own data, at report time' {
        $old = New-BcrTestDir 'old2'
        $e = @{ RDS_BCR_NOW = [string]($Now - 7 * 86400); MOCK_NOW = [string]($Now - 7 * 86400) }
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-SaveDataFile', (Join-Path $old 'p.json'), '-Format', 'json') -Env $e
        $m = ConvertFrom-BcrJsonText (Invoke-Bcr -Arguments @('-Merge', (Join-Path $old 'p.json'), '-Format', 'json')).Stdout
        $m.accounts[0].collected_epoch | Should -Be ($Now - 7 * 86400)
        @($m.rows).Count | Should -Be 6
    }
    It 'bad input: exit 3' {
        $e = New-BcrTestDir 'empty'
        (Invoke-Bcr -Arguments @('-Merge', $e)).ExitCode | Should -Be 3
        (Invoke-Bcr -Arguments @('-Merge', (Join-Path $e 'nope.json'))).ExitCode | Should -Be 3
        $j = Join-Path $e 'other.json'; Set-Content -LiteralPath $j -Value '{"rows": []}'
        $r = Invoke-Bcr -Arguments @('-Merge', $j); $r.ExitCode | Should -Be 3; $r.Stderr | Should -Match 'Not a -SaveData file'
        $t = Join-Path $e 'broken.json'; Set-Content -LiteralPath $t -Value '{"schema": '
        (Invoke-Bcr -Arguments @('-Merge', $t)).ExitCode | Should -Be 3
    }
    It 'a directory with other JSON files: they are skipped with a warning' {
        $m = New-BcrTestDir 'mixed'; Copy-Item (Join-Path $Data 'rds_backup_222222222222_20261114.json') $m
        Set-Content -LiteralPath (Join-Path $m 'notes.json') -Value '[1,2]'
        $r = Invoke-Bcr -Arguments @('-Merge', $m, '-Format', 'json')
        $r.ExitCode | Should -Be 0; $r.Stderr | Should -Match 'skipping .*notes\.json'
    }
    It 'extra merge inputs after the first one are accepted' {
        $r = Invoke-Bcr -Arguments @('-Merge', (Join-Path $Data 'rds_backup_111111111111_20261114.json'), (Join-Path $Data 'rds_backup_222222222222_20261114.json'), '-Format', 'json')
        $r.ExitCode | Should -Be 0
        @((ConvertFrom-BcrJsonText $r.Stdout).accounts).Count | Should -Be 2
    }
}
