# Csv.Tests.ps1 - every CSV file: names, exact columns (same as the Bash tool), rows, quoting, the formula guard,
# Excel-safe cells, the second time-zone column, and where each file is written.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Dir = New-BcrTestDir 'csv'
    $script:Res = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'csv,html,json,text', '-OutputDir', $Dir, '-ManualOlderThan', '90', '-SaveData')
    $script:Stamp = '20261114_100000'
    $script:Base = "rds_backup_compliance_111111111111_$Stamp"
    $script:Csv = Join-Path $Dir "$Base.csv"; $script:BCsv = Join-Path $Dir "${Base}_backups.csv"
    $script:OCsv = Join-Path $Dir "${Base}_orphaned_snapshots.csv"; $script:MCsv = Join-Path $Dir "${Base}_manual_older_than_90d.csv"
    $script:Json = ConvertFrom-BcrJsonText ([System.IO.File]::ReadAllText((Join-Path $Dir "$Base.json")))
    $h = 'account_id,region,identifier,type,engine,engine_version,global_cluster,global_role,retention_days,created_utc,age_days,backup_window,copy_tags_to_snapshot,last_automated_utc,last_automated_ist'
    foreach ($k in 'daily', 'weekly', 'monthly') { $h += ",${k}_status,${k}_found,${k}_expected,${k}_target,${k}_missing,${k}_full_on" }
    $h += ',status,not_yet_due,gaps,warnings,weekly_retention,monthly_retention,backup_plans'
    $h += ',retention_mismatch_count,retention_mismatch,excess_daily,excess_weekly,excess_monthly,excess,over_retention_count,over_retention,counted_in_compliance_pct,pitr_enabled,pitr_since_utc,account_name'
    $script:MainHeader = $h
    $script:ExcelDate = '^\s*(\d{1,4}[/-]\d{1,2}([/-]\d{1,4})?|\d{1,2}[ -](Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*([ -]\d{2,4})?|(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[ -]\d{1,4})\s*$'
}

Describe 'files written with -Format csv and -OutputDir' {
    It 'exit 0 and the four CSV files plus the other formats and the data file' {
        $Res.ExitCode | Should -Be 0
        $names = @(Get-ChildItem -LiteralPath $Dir -File | ForEach-Object Name | Sort-Object)
        $names | Should -Be (@("$Base.csv", "$Base.html", "$Base.json", "$Base.txt", "${Base}_backups.csv", "${Base}_manual_older_than_90d.csv", "${Base}_orphaned_snapshots.csv", 'rds_backup_111111111111_20261114.json') | Sort-Object)
    }
    It 'Output block lists every file with its full path' {
        $Res.Stderr | Should -Match '(?m)^Output \(8 files\):$'
        foreach ($f in Get-ChildItem -LiteralPath $Dir -File) { $Res.Stderr | Should -Match ('(?m)^  ' + [regex]::Escape($f.FullName) + '$') }
        $Res.Stderr | Should -Match 'manual snapshots older than 90 days: [0-9]+'
    }
    It 'UTF-8 without BOM, LF line ends, every cell quoted' {
        foreach ($f in $Csv, $BCsv, $OCsv, $MCsv) {
            $b = [System.IO.File]::ReadAllBytes($f)
            ($b[0] -eq 0xEF) | Should -BeFalse
            [System.IO.File]::ReadAllText($f) | Should -Not -Match "`r"
            foreach ($l in [System.IO.File]::ReadAllLines($f)) { $l | Should -Match '^"([^"]|"")*"(,"([^"]|"")*")*$' }
        }
    }
}

Describe 'main compliance CSV (<prefix>_<account>_<stamp>.csv)' {
    BeforeAll { $script:Rows = Read-BcrCsv $Csv }
    It 'columns (same as Bash v1.6.0)' { Get-BcrCsvHeader $Csv | Should -BeExactly $MainHeader }
    It 'one row per resource, same order as the JSON report' {
        $Rows.Count | Should -Be 8
        @($Rows | ForEach-Object identifier) | Should -Be @($Json.rows | ForEach-Object identifier)
    }
    It 'every status present; counted_in_compliance_pct' {
        @($Rows | ForEach-Object status | Sort-Object -Unique) | Should -Be @('COMPLIANT', 'NON-COMPLIANT', 'NOT YET DUE')
        foreach ($r in $Rows) { $r.counted_in_compliance_pct | Should -Be $(if ($r.status -eq 'NOT YET DUE') { 'no' } else { 'yes' }) }
    }
    It 'row values match the JSON report' {
        foreach ($r in $Rows) {
            $j = Get-BcrRow $Json $r.identifier
            $r.status | Should -Be $j.status; $r.gaps | Should -Be $j.gaps; $r.warnings | Should -Be $j.warnings
            $r.daily_status | Should -Be $j.daily.st; $r.weekly_status | Should -Be $j.weekly.st; $r.monthly_status | Should -Be $j.monthly.st
            $r.account_name | Should -Be 'prod-core'; $r.account_id | Should -Be '111111111111'
        }
    }
    It 'weekly numbers and the missing Saturday as an ISO date' {
        $b = $Rows | Where-Object identifier -EQ 'billing-aurora-mysql'
        $b.weekly_status | Should -Be 'FAIL'; $b.weekly_found | Should -Be '4'; $b.weekly_expected | Should -Be '5'; $b.weekly_target | Should -Be '5'
        $b.weekly_missing | Should -Be '2026-11-07 Sat'
    }
    It 'building up: found / expected below the target, full-on date' {
        $f = $Rows | Where-Object identifier -EQ 'fresh-pg'
        $f.daily_found | Should -Be $f.daily_expected; $f.daily_expected | Should -BeIn '4', '5'; $f.daily_target | Should -Be '7'
        $f.daily_full_on | Should -Be '2026-11-16 Mon'
        $f.not_yet_due | Should -Match 'daily full on'
    }
    It 'N/A periods keep the status with empty numbers' {
        $d = $Rows | Where-Object identifier -EQ 'orders-dr-pg15'
        $d.weekly_status | Should -Be 'N/A'; $d.weekly_found | Should -Be ''; $d.excess_weekly | Should -Be ''
    }
    It 'excess / retention columns' {
        ($Rows | Where-Object identifier -EQ 'reports-pg').excess_weekly | Should -BeIn '3', '4'
        $o = $Rows | Where-Object identifier -EQ 'orders-aurora-pg15'
        $o.retention_mismatch | Should -Match '^weekly point has 35d, expected 30d \(x[45]\)$'
        ($Rows | Where-Object identifier -EQ 'legacy-mysql').over_retention_count | Should -Be '2'
    }
    It 'count columns are plain integers; no cell Excel would read as a date' {
        foreach ($r in $Rows) {
            foreach ($k in 'daily', 'weekly', 'monthly') { foreach ($c in 'found', 'expected', 'target') { $r."${k}_$c" | Should -Match '^\d*$' } }
            foreach ($c in 'retention_mismatch_count', 'excess_daily', 'excess_weekly', 'excess_monthly', 'over_retention_count') { $r.$c | Should -Match '^\d*$' }
            foreach ($p in $r.PSObject.Properties) { $p.Value | Should -Not -Match $ExcelDate }
        }
    }
    It 'no yearly columns at -Yearly 0' { Get-BcrCsvHeader $Csv | Should -Not -Match 'yearly' }
    It 'global primary then secondary on consecutive rows' {
        $ids = @($Rows | ForEach-Object identifier); $i = [array]::IndexOf($ids, 'orders-aurora-pg15')
        $ids[$i + 1] | Should -Be 'orders-dr-pg15'; $Rows[$i].global_role | Should -Be 'primary'; $Rows[$i + 1].global_role | Should -Be 'secondary'
    }
}

Describe 'backups CSV (_backups.csv)' {
    BeforeAll { $script:B = Read-BcrCsv $BCsv }
    It 'columns = the in-page Backups export (18, ending in source_status, backup_type, schedule)' {
        Get-BcrCsvHeader $BCsv | Should -BeExactly 'account_id,region,identifier,type,kind,snapshot_or_recovery_point,created_utc,created_ist,age_days,status,size_gb,rule,retention_days,expires_utc,vault,source_status,backup_type,schedule'
    }
    It 'manual, automated and AWS Backup kinds with classes' {
        @($B | ForEach-Object kind | Sort-Object -Unique) | Should -Be @('automated', 'backup', 'manual')
        @($B | ForEach-Object rule | Sort-Object -Unique) | Should -Contain 'weekly'
        @($B | ForEach-Object rule | Sort-Object -Unique) | Should -Contain 'monthly'
        @($B | ForEach-Object rule | Sort-Object -Unique) | Should -Contain 'mismatch'
    }
    It 'automated rows: rule daily; manual rows: no rule, numeric age' {
        ($B | Where-Object kind -EQ 'automated' | Select-Object -First 1).rule | Should -Be 'daily'
        $m = $B | Where-Object kind -EQ 'manual' | Select-Object -First 1
        $m.rule | Should -Be ''; $m.age_days | Should -Match '^\d+$'
    }
    It 'source_status: EXISTING, ORPHANED and SHARED rows' {
        $c = $B | Where-Object snapshot_or_recovery_point -EQ 'crm-mysql-before-delete'
        $c.source_status | Should -Be 'ORPHANED'; $c.backup_type | Should -Be 'manual'; $c.schedule | Should -Be 'not_counted'
        ($B | Where-Object snapshot_or_recovery_point -EQ 'vendor-share-1').source_status | Should -Be 'SHARED'
        @($B | Where-Object { $_.kind -ne 'manual' -and $_.kind -ne 'shared' } | ForEach-Object source_status | Sort-Object -Unique) | Should -Be @('EXISTING')
    }
    It 'no EC2 recovery point; account-level ordering' {
        [System.IO.File]::ReadAllText($BCsv) | Should -Not -Match 'ami-0abc'
        @($B | ForEach-Object account_id | Sort-Object -Unique) | Should -Be @('111111111111')
    }
    It 'every snapshot of the JSON report is a row' {
        $n = 0; foreach ($r in $Json.rows) { $n += @($r.snapshots).Count }
        $B.Count | Should -BeGreaterOrEqual $n
    }
}

Describe 'orphaned snapshots CSV (_orphaned_snapshots.csv)' {
    BeforeAll { $script:O = Read-BcrCsv $OCsv }
    It 'columns' { Get-BcrCsvHeader $OCsv | Should -BeExactly 'account_id,region,snapshot_id,type,source_id,engine,engine_version,created_utc,created_ist,age_days,size_gb,est_monthly_usd,encrypted,kms_key' }
    It 'only ORPHANED snapshots, oldest first' {
        @($O | ForEach-Object snapshot_id) | Should -Be @('retired-oracle-final', 'analytics-aurora-final', 'crm-mysql-before-delete', 'reports-pg-west')
        [System.IO.File]::ReadAllText($OCsv) | Should -Not -Match 'vendor|eu-app|dr-copy|gone-db|docs-final'
    }
    It 'a deleted source: size, estimate, encryption, KMS key' {
        $a = $O | Where-Object snapshot_id -EQ 'analytics-aurora-final'
        $a.type | Should -Be 'cluster'; $a.source_id | Should -Be 'analytics-aurora'; $a.engine | Should -Be 'aurora-postgresql'; $a.engine_version | Should -Be '14.9'
        $a.size_gb | Should -Be '500'; $a.est_monthly_usd | Should -Be '10.5'; $a.encrypted | Should -Be 'true'; $a.kms_key | Should -Match '^arn:aws:kms:'
        $a.created_utc | Should -Be '2025-10-10 10:00 UTC'; $a.created_ist | Should -Be '2025-10-10 15:30 IST'; $a.age_days | Should -Be '400'
    }
    It 'same-name source in another region is orphaned' {
        $r = $O | Where-Object snapshot_id -EQ 'reports-pg-west'; $r.region | Should -Be 'us-west-2'; $r.source_id | Should -Be 'reports-pg'
    }
    It 'totals match the JSON report and the log line' {
        $Json.orphan_totals.summary | Should -Be '4 orphaned snapshots, 1.8 TB, ~$38/month (estimate)'
        $Json.orphan_totals.shared | Should -Be 2; $Json.orphan_totals.unverified | Should -Be 1
        $Res.Stderr | Should -Match '4 orphaned snapshots, 1\.8 TB, ~\$38/month \(estimate\)'
        $s = 0.0; foreach ($o in $O) { $s += [double]$o.est_monthly_usd }; [math]::Round($s, 2) | Should -Be $Json.orphan_totals.est_monthly_usd
    }
}

Describe 'manual snapshots older than N days (_manual_older_than_<N>d.csv)' {
    BeforeAll { $script:M = Read-BcrCsv $MCsv }
    It 'columns' { Get-BcrCsvHeader $MCsv | Should -BeExactly 'account_id,region,identifier,type,engine,snapshot,created_utc,created_ist,age_days,status,size_gb,source_status' }
    It 'only manual snapshots older than 90 days, oldest first' {
        $M.Count | Should -BeGreaterThan 0
        foreach ($r in $M) { [int]$r.age_days | Should -BeGreaterThan 90 }
        $ages = @($M | ForEach-Object { [int]$_.age_days }); $ages | Should -Be @($ages | Sort-Object -Descending)
        @($M | ForEach-Object source_status | Sort-Object -Unique) | Should -Contain 'ORPHANED'
        @($M | ForEach-Object source_status | Sort-Object -Unique) | Should -Contain 'EXISTING'
        @($M | Where-Object snapshot -Match '^rds:').Count | Should -Be 0
    }
    It 'row count matches the log line' { $Res.Stderr | Should -Match "manual snapshots older than 90 days: $($M.Count)" }
    It 'written to the current directory without -OutputDir' {
        $d = New-BcrTestDir 'mo'
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-ManualOlderThan', '30', '-Format', 'csv') -WorkingDirectory $d
        $r.ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $d -File | ForEach-Object Name) | Should -Be @("rds_backup_compliance_111111111111_${Stamp}_manual_older_than_30d.csv")
        $r.Stdout | Should -Match ('^"' + [regex]::Escape(($MainHeader -replace ',', '","')) + '"')
    }
}

Describe 'CSV options' {
    It 'csv on stdout without -OutputDir: the compliance CSV only, no side files' {
        $d = New-BcrTestDir 'so'
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv') -WorkingDirectory $d
        ($r.Stdout -split "`n")[0] | Should -BeExactly ('"' + ($MainHeader -replace ',', '","') + '"')
        @(Get-ChildItem -LiteralPath $d -File).Count | Should -Be 0
    }
    It '-Tz America/New_York names the second time column after the zone' {
        $d = New-BcrTestDir 'tz'
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv', '-OutputDir', $d, '-Tz', 'America/New_York')
        Get-BcrCsvHeader (Get-BcrFile $d '_100000\.csv$') | Should -Match 'last_automated_utc,last_automated_est,'
        $b = Get-BcrFile $d '_backups\.csv$'
        Get-BcrCsvHeader $b | Should -Match 'created_utc,created_est,'
        ([System.IO.File]::ReadAllLines($b)[1]) | Should -Match '"2026-11-14 05:00 UTC","2026-11-14 00:00 EST"'
        Get-BcrCsvHeader (Get-BcrFile $d '_orphaned_snapshots\.csv$') | Should -Match 'created_utc,created_est,'
    }
    It '-Tz UTC: both time columns in UTC (as the Bash tool)' {
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv', '-Tz', 'UTC')
        ($r.Stdout -split "`n")[0] | Should -Match '"last_automated_utc","last_automated_utc"'
    }
    It '-Prefix changes every file name' {
        $d = New-BcrTestDir 'px'
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv', '-OutputDir', $d, '-Prefix', 'acme_backups')
        @(Get-ChildItem -LiteralPath $d -File | ForEach-Object Name | Sort-Object) | Should -Be (@("acme_backups_111111111111_$Stamp.csv", "acme_backups_111111111111_${Stamp}_backups.csv", "acme_backups_111111111111_${Stamp}_orphaned_snapshots.csv") | Sort-Object)
    }
    It '-SnapshotPricePerGb changes the estimate' {
        $d = New-BcrTestDir 'pr'
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv', '-OutputDir', $d, '-SnapshotPricePerGb', '0.05')
        ((Read-BcrCsv (Get-BcrFile $d '_orphaned_snapshots\.csv$')) | Where-Object snapshot_id -EQ 'analytics-aurora-final').est_monthly_usd | Should -Be '25'
    }
    It 'two accounts: one file set named after both accounts' {
        $d = New-BcrTestDir 'two'
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod,nonprod', '-Region', 'us-east-1,ap-south-1', '-Format', 'csv', '-OutputDir', $d)
        $rows = Read-BcrCsv (Join-Path $d "rds_backup_compliance_111111111111_222222222222_$Stamp.csv")
        @($rows | ForEach-Object account_id | Sort-Object -Unique) | Should -Be @('111111111111', '222222222222')
        @((Read-BcrCsv (Join-Path $d "rds_backup_compliance_111111111111_222222222222_${Stamp}_orphaned_snapshots.csv")) | ForEach-Object account_id | Sort-Object -Unique) | Should -Be @('111111111111', '222222222222')
    }
    It 'yearly columns at -Yearly 1' {
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-Format', 'csv', '-Yearly', '1')
        ($r.Stdout -split "`n")[0] | Should -Match '"monthly_full_on","yearly_status","yearly_found","yearly_expected","yearly_target","yearly_missing","yearly_full_on","status"'
        ($r.Stdout | ConvertFrom-Csv | Where-Object identifier -EQ 'orders-aurora-pg15').yearly_found | Should -Be '2'
    }
}
