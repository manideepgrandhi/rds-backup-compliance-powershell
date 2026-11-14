# Compliance.Tests.ps1 - the backup rules on the mock fleet: daily / weekly / monthly / yearly, tolerance, "so far",
# strict retention, excess, over-retention, roles, replica exemptions, filters, scenarios (denied calls, empty, crash).
BeforeDiscovery { }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    function Run { param([string[]]$A, [string]$S = 'fleet', [hashtable]$E = @{}) Invoke-Bcr -Arguments $A -Scenario $S -Env $E }
    function RunJson { param([string[]]$A, [string]$S = 'fleet', [hashtable]$E = @{}) $r = Run ($A + @('-Format', 'json')) $S $E; if ($r.ExitCode -notin 0, 5) { throw "exit $($r.ExitCode): $($r.Stderr)" }; $j = ConvertFrom-BcrJsonText $r.Stdout; $j['_err'] = $r.Stderr; return $j }
    $script:Fleet = RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2')
    $script:Np = RunJson @('-ProfileName', 'nonprod', '-Region', 'ap-south-1')
}

Describe 'fleet (prod, us-east-1 + us-west-2)' {
    It 'totals and compliance %' {
        $t = $Fleet.totals
        $t.resources | Should -Be 8; $t.compliant | Should -Be 2; $t.non_compliant | Should -Be 4; $t.not_yet_due | Should -Be 2; $t.unknown | Should -Be 0
        $t.compliance.compliant | Should -Be 2; $t.compliance.of | Should -Be 6; $t.compliance.pct | Should -Be 33
    }
    It 'thresholds are the Bash defaults' {
        $h = $Fleet.thresholds
        $h.weekly_min_days | Should -Be 25; $h.weekly_max_days | Should -Be 40; $h.monthly_min_days | Should -Be 300; $h.monthly_max_days | Should -Be 400
        $h.weekly | Should -Be 'auto'; $h.monthly | Should -Be 12; $h.yearly | Should -Be 0; $h.weekly_weekday | Should -Be 6; $h.monthly_weekday | Should -Be 0; $h.tolerance_days | Should -Be 1
    }
    It 'global primary: compliant, all schedules met, yearly OFF' {
        $r = Get-BcrRow $Fleet 'orders-aurora-pg15'
        $r.status | Should -Be 'COMPLIANT'; $r.global_role | Should -Be 'primary'; $r.global_cluster | Should -Be 'orders-global'
        $r.daily.have | Should -Be 7; $r.weekly.have | Should -Be $r.weekly.need; $r.weekly.need | Should -BeIn 4, 5
        $r.monthly.have | Should -Be 12; $r.monthly.need | Should -Be 12; $r.yearly.st | Should -Be 'OFF'
        $r.warnings | Should -BeLike "retention doesn't match: 2 recovery points (2555d, never expires) not counted*"
        $r.gaps | Should -Be ''
        $r.automated | Should -Be 7; $r.manual | Should -Be 4; $r.age_days | Should -Be 1000
    }
    It 'settings: window, copy tags, plans, schedules' {
        $r = Get-BcrRow $Fleet 'orders-aurora-pg15'
        $r.settings.backup_window | Should -Be '03:00-03:30'; $r.settings.copy_tags | Should -BeFalse
        $r.settings.weekly_retention | Should -Be '35d'; $r.settings.monthly_retention | Should -Be '365d'
        $r.settings.plans | Should -Be 'prod-rds-plan / monthly-first-sun, prod-rds-plan / weekly-sat'
        $r.settings.schedules | Should -Match 'SAT'
        (Get-BcrRow $Fleet 'reports-pg').settings.copy_tags | Should -BeTrue
    }
    It 'missing weekly point named (Sat 07 Nov)' {
        $r = Get-BcrRow $Fleet 'billing-aurora-mysql'
        $r.status | Should -Be 'NON-COMPLIANT'; $r.weekly.st | Should -Be 'FAIL'
        $r.gaps | Should -Be 'weekly 4/5 missing Sat 07 Nov'
    }
    It 'NOT YET DUE with "so far" counts and full-on dates' {
        $r = Get-BcrRow $Fleet 'new-aurora-pg16'
        $r.status | Should -Be 'NOT YET DUE'; $r.daily.st | Should -Be 'OK'; $r.weekly.st | Should -Be 'DUE'; $r.monthly.st | Should -Be 'DUE'
        $r.weekly.have | Should -Be $r.weekly.need; $r.weekly.need | Should -BeLessThan $r.weekly.target
        $r.not_yet_due | Should -Match '^weekly full on [0-9]{2} [A-Z][a-z]{2} 20[0-9]{2}; monthly full on '
        $r.weekly.full_on | Should -Be '24 Nov 2026'
        $f = Get-BcrRow $Fleet 'fresh-pg'
        $f.status | Should -Be 'NOT YET DUE'; $f.daily.st | Should -Be 'DUE'; $f.daily.target | Should -Be 7; $f.daily.full_on | Should -Be '16 Nov 2026'; $f.age_days | Should -Be 5
    }
    It 'daily: retention too short, newest too old' {
        (Get-BcrRow $Fleet 'reports-pg').gaps | Should -Match 'retention 3d < 7d'
        (Get-BcrRow $Fleet 'legacy-mysql').gaps | Should -Match 'last automated 74h ago'
    }
    It 'global secondary: daily only' {
        $r = Get-BcrRow $Fleet 'orders-dr-pg15'
        $r.status | Should -Be 'COMPLIANT'; $r.global_role | Should -Be 'secondary'; $r.weekly.st | Should -Be 'N/A'; $r.yearly.st | Should -Be 'N/A'; $r.daily.st | Should -Be 'OK'
        $s = Get-BcrRow $Fleet 'shop-dr-mysql'
        $s.status | Should -Be 'NON-COMPLIANT'; $s.global_cluster | Should -Be 'shop-global'; $s.gaps | Should -Match '^daily'
    }
    It 'DocumentDB / Neptune and cluster members are not listed' {
        $ids = @($Fleet.rows | ForEach-Object identifier)
        $ids | Should -Not -Contain 'docs-cluster'
        @($ids | Where-Object { $_ -match '-1$' }).Count | Should -Be 0
    }
    It 'no ARN or tag fields in rows' {
        $keys = @($Fleet.rows | ForEach-Object { $_.Keys } | Sort-Object -Unique)
        @($keys | Where-Object { $_ -match '(^|_)arn$|^env|owner|^app|notes?$' }).Count | Should -Be 0
    }
    It 'strict retention: weekly 35d counted but flagged, monthly 365d as expected' {
        $r = Get-BcrRow $Fleet 'orders-aurora-pg15'
        $r.retention_mismatch | Should -Be "weekly point has 35d, expected 30d (x$($r.weekly.have))"
        $r.retention_mismatch_count | Should -Be $r.weekly.have
        $m = @($r.recovery_points | Where-Object { $_.ret -eq 365 -and $_.counted })
        $m.Count | Should -BeGreaterThan 0
        $m | ForEach-Object { $_.reason | Should -Match 'retention 365d as expected$' }
        $w = @($r.recovery_points | Where-Object { $_.ret -eq 35 -and $_.counted })
        $w.Count | Should -Be $r.weekly.have
        $w | ForEach-Object { $_.reason | Should -Match '^weekly: counts for Sat [0-9]{2} [A-Z][a-z]{2}, but weekly point has 35d, expected 30d$' }
    }
    It 'recovery point list: date, ret, class, counted, reason' {
        $r = Get-BcrRow $Fleet 'orders-aurora-pg15'
        foreach ($p in $r.recovery_points) { foreach ($k in 'date', 'ret', 'class', 'counted', 'reason') { $p.ContainsKey($k) | Should -BeTrue } }
        $r.recovery_points[0].date | Should -Match '^20[0-9]{2}-[0-9]{2}-[0-9]{2} [A-Z][a-z]{2}$'
    }
    It 'excess backups and over-retention' {
        $r = Get-BcrRow $Fleet 'reports-pg'
        $r.excess | Should -Match '^weekly .*expected 4-5\)$'; $r.excess_counts.weekly | Should -BeIn 3, 4; $r.excess_counts.daily | Should -Be 0
        $l = Get-BcrRow $Fleet 'legacy-mysql'
        $l.over_retention | Should -Match '^holds 7 automated backups for 7d retention; 2 older than 7d, oldest rds:legacy-mysql-'
        $l.over_retention_count | Should -Be 2
        (Get-BcrRow $Fleet 'new-aurora-pg16').over_retention_count | Should -Be 13
        $d = Get-BcrRow $Fleet 'orders-dr-pg15'
        $d.excess | Should -Be ''; $d.over_retention | Should -Be ''; $d.retention_mismatch | Should -Be ''
    }
    It 'global members sorted together (primary then secondary)' {
        $ids = @($Fleet.rows | ForEach-Object identifier)
        $p = [array]::IndexOf($ids, 'orders-aurora-pg15'); $ids[$p + 1] | Should -Be 'orders-dr-pg15'
    }
    It 'region progress lines' {
        $Fleet._err | Should -Match '\[1/2\] us-east-1: 3 clusters, 3 instances, [0-9]+ snapshots, [0-9]+ recovery points, 4 without source \([0-9]+s\)'
        $Fleet._err | Should -Match '\[2/2\] us-west-2: 2 clusters, 0 instances, [0-9]+ snapshots, 0 recovery points'
    }
}

Describe 'text report' {
    BeforeAll { $script:T = Run @('-ProfileName', 'prod', '-Region', 'us-east-1') }
    It 'header with account name and UTC / IST time' {
        $T.ExitCode | Should -Be 0
        $l = $T.Stdout -split "`n"
        $l[0] | Should -Be 'RDS backup compliance - account prod-core (111111111111)'
        $l[1] | Should -Be 'Generated 2026-11-14 10:00 UTC / 2026-11-14 15:30 IST'
        ($l[0..3] -join "`n") | Should -Not -Match 'us-east-1'
        $T.Stdout | Should -Match '(?m)^Compliance: 25% \(1 of 4\), 2 not yet due not counted$'
        $T.Stdout | Should -Not -Match 'YEARLY'
    }
}

Describe 'thresholds and options' {
    It '-Weekly 6 needs 6 Saturdays' {
        $r = Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-Weekly', '6')) 'orders-aurora-pg15'
        $r.weekly.have | Should -Be 5; $r.weekly.need | Should -Be 6; $r.weekly.st | Should -Be 'FAIL'; $r.gaps | Should -Match '^weekly 5/6 missing Sat '
    }
    It '-WeeklyDays 40-60: 35d points are not weekly' {
        $r = Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-WeeklyDays', '40-60')) 'orders-aurora-pg15'
        $r.weekly.have | Should -Be 0; $r.warnings | Should -Match '35d'
        @($r.recovery_points | Where-Object { $_.ret -eq 35 }) | ForEach-Object { $_.reason | Should -Match '^retention 35d is outside the weekly range 40-60d \(expected 30d\) and the monthly range' }
    }
    It '-MonthlyMaxDays 300 / -MonthlyDays 360-370' {
        $r = Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-MonthlyMaxDays', '300')) 'orders-aurora-pg15'
        $r.monthly.have | Should -Be 0; $r.warnings | Should -Match '365d'
        $r = Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-MonthlyDays', '360-370')) 'orders-aurora-pg15'
        $r.monthly.have | Should -Be 12; $r.status | Should -Be 'COMPLIANT'
    }
    It '-Yearly 1 counts long-retention points; CSV / text get yearly columns' {
        $r = Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-Yearly', '1')) 'orders-aurora-pg15'
        $r.yearly.have | Should -Be 2; $r.yearly.st | Should -Be 'OK'; $r.warnings | Should -Be ''
        (Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-Yearly', '1', '-Format', 'csv')).Stdout | Should -Match '"monthly_full_on","yearly_status","yearly_found","yearly_expected","yearly_target","yearly_missing","yearly_full_on","status"'
        (Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-Yearly', '1')).Stdout | Should -Match "MONTHLY`tYEARLY`tSTATUS"
    }
    It 'tolerance: a Sunday point counts for Saturday at 1 day, not at 0' {
        $r = Get-BcrRow $Np 'hr-aurora-pg'
        $r.status | Should -Be 'COMPLIANT'; $r.weekly.st | Should -Be 'OK'
        $r = Get-BcrRow (RunJson @('-ProfileName', 'nonprod', '-Region', 'ap-south-1', '-ToleranceDays', '0')) 'hr-aurora-pg'
        $r.status | Should -Be 'NON-COMPLIANT'; $r.gaps | Should -Match '^weekly [34]/[45] missing Sat '
    }
    It 'missing months named; plans from recovery points' {
        $r = Get-BcrRow $Np 'payroll-sqlserver'
        $r.status | Should -Be 'NON-COMPLIANT'; $r.gaps | Should -Be 'monthly 10/12 missing Jun 2026, Sep 2026'
        $r.settings.plans | Should -Be '1a2b3c4d-plan / rule-monthly-first-sun, 1a2b3c4d-plan / rule-weekly-sat'; $r.settings.schedules | Should -Be ''
    }
    It '-WeeklyWeekday sun with tolerance 0' {
        $r = Get-BcrRow (RunJson @('-ProfileName', 'nonprod', '-Region', 'ap-south-1', '-WeeklyWeekday', 'sun', '-ToleranceDays', '0')) 'hr-aurora-pg'
        $r.weekly.have | Should -BeLessOrEqual 1
        @($r.recovery_points | Where-Object { $_.class -eq 'weekly' -and -not $_.counted }) | ForEach-Object { $_.reason | Should -Match 'not within ±0d of a checked Sunday' }
    }
    It '-Daily 14 and -DailyMaxAge 80' {
        $j = RunJson @('-ProfileName', 'nonprod', '-Region', 'ap-south-1', '-Daily', '14')
        (Get-BcrRow $j 'hr-aurora-pg').daily.st | Should -Be 'OK'; (Get-BcrRow $j 'payroll-sqlserver').daily.st | Should -Be 'FAIL'
        (Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'legacy-*', '-DailyMaxAge', '80')) 'legacy-mysql').gaps | Should -Not -Match 'last automated'
    }
    It 'strict retention settings' {
        (Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-WeeklyRetentionDays', '35')) 'orders-aurora-pg15').retention_mismatch | Should -Be ''
        (Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-RetentionToleranceDays', '5')) 'orders-aurora-pg15').retention_mismatch | Should -Be ''
        $r = Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-MonthlyRetentionDays', '400')) 'orders-aurora-pg15'
        $r.retention_mismatch | Should -Match 'monthly point has 365d, expected 400d \(x12\)'; $r.status | Should -Be 'COMPLIANT'
        (Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'reports-pg', '-DailyRetentionDays', '2')) 'reports-pg').retention_mismatch | Should -Match '^daily retention 3d, expected 2d'
    }
    It '-MonthlyRule first-mon' {
        $j = RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*', '-MonthlyRule', 'first-mon')
        $j.thresholds.monthly_weekday | Should -Be 1
        (Get-BcrRow $j 'orders-aurora-pg15').monthly.st | Should -Be 'FAIL'
    }
}

Describe 'roles and replica exemptions' {
    It 'oracle-* exempts the Oracle read replica only' {
        $j = RunJson @('-ProfileName', 'prod,dev', '-Region', 'us-west-2,eu-west-1', '-ReplicaExemptEngines', 'oracle-*')
        $o = Get-BcrRow $j 'erp-oracle-rr'; $o.status | Should -Be 'COMPLIANT'; $o.daily.st | Should -Be 'N/A'; $o.weekly.st | Should -Be 'N/A'
        $s = Get-BcrRow $j 'shop-dr-mysql'; $s.status | Should -Be 'NON-COMPLIANT'; $s.daily.st | Should -Not -Be 'N/A'
        (Get-BcrRow $j 'orders-dr-pg15').daily.st | Should -Be 'OK'
    }
    It 'aurora-* exempts Aurora secondaries (config key, both globs)' {
        $d = New-BcrTestDir 'ex'; $c = Join-Path $d 'ex.conf'; Set-Content -LiteralPath $c -Value 'replica-exempt-engines=oracle-*,aurora-*'
        $j = RunJson @('-ProfileName', 'prod,dev', '-Region', 'us-west-2,eu-west-1', '-ConfigFile', $c)
        $s = Get-BcrRow $j 'shop-dr-mysql'; $s.status | Should -Be 'COMPLIANT'; $s.daily.st | Should -Be 'N/A'
        (Get-BcrRow $j 'erp-oracle-rr').daily.st | Should -Be 'N/A'
        $j.thresholds.replica_exempt_engines | Should -Be @('oracle-*', 'aurora-*')
    }
    It 'replica without exemption: daily only' {
        $j = RunJson @('-ProfileName', 'dev', '-Region', 'eu-west-1')
        $o = Get-BcrRow $j 'erp-oracle-rr'; $o.weekly.st | Should -Be 'N/A'; $o.monthly.st | Should -Be 'N/A'; $o.daily.st | Should -Not -Be 'N/A'
    }
}

Describe 'filters and selection' {
    It '-Engine aurora-* filters rows and orphaned snapshots' {
        $j = RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Engine', 'aurora-*')
        @($j.rows | Where-Object { -not $_.engine.StartsWith('aurora-') }).Count | Should -Be 0
        @($j.orphaned_snapshots | ForEach-Object source_id) | Should -Be @('analytics-aurora')
    }
    It '-Identifier is a case-insensitive glob' {
        @((RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'REPORTS-*')).rows | ForEach-Object identifier) | Should -Be @('reports-pg')
    }
    It '-NonCompliantOnly' {
        $j = RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-NonCompliantOnly')
        @($j.rows | ForEach-Object status | Sort-Object -Unique) | Should -Be @('NON-COMPLIANT')
    }
    It '-FailOnNonCompliant: 5 with a NON-COMPLIANT row, 0 without' {
        (Run @('-ProfileName', 'prod', '-Region', 'us-east-1', '-FailOnNonCompliant')).ExitCode | Should -Be 5
        (Run @('-ProfileName', 'nonprod', '-Region', 'ap-south-1', '-Identifier', 'hr-*', '-FailOnNonCompliant')).ExitCode | Should -Be 0
    }
    It 'default region from the profile (aws configure get region)' {
        (Run @('-ProfileName', 'nonprod', '-Format', 'json')).ExitCode | Should -Be 2
        $j = RunJson @('-ProfileName', 'nonprod') -E @{ MOCK_DEFAULT_REGION = 'ap-south-1' }
        @($j.rows).Count | Should -Be 2
    }
    It 'several profiles; a broken one is skipped' {
        (Run @('-ProfileName', 'broken', '-Region', 'us-east-1')).ExitCode | Should -Be 2
        $j = RunJson @('-ProfileName', 'prod,broken', '-Region', 'us-east-1')
        @($j.accounts).Count | Should -Be 1
    }
}

Describe 'account names' {
    It 'alias for prod, silent fallback when denied, config map wins' {
        $j = RunJson @('-ProfileName', 'prod,nonprod', '-Region', 'us-east-1,ap-south-1')
        ($j.accounts | Where-Object account -EQ '111111111111').name | Should -Be 'prod-core'
        ($j.accounts | Where-Object account -EQ '222222222222').name | Should -Be ''
        $j._err | Should -Not -Match 'AccessDenied|list-account-aliases'
        @($j.rows | Where-Object account_id -EQ '111111111111' | ForEach-Object account_name | Sort-Object -Unique) | Should -Be @('prod-core')
        $d = New-BcrTestDir 'an'; $c = Join-Path $d 'n.conf'
        Set-Content -LiteralPath $c -Value "111111111111 = prod-payments   # comment`n222222222222 = `"np x`""
        $j = RunJson @('-ProfileName', 'prod,nonprod', '-Region', 'us-east-1,ap-south-1', '-ConfigFile', $c)
        @($j.accounts | ForEach-Object name | Sort-Object) | Should -Be @('np x', 'prod-payments')
        $j = RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1') -E @{ MOCK_ALIAS_DENY = '1' }
        $j.accounts[0].name | Should -Be ''
    }
}

Describe 'scenarios' {
    It 'AWS Backup denied: UNKNOWN, region in error' {
        $j = RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2') 'backupdeny'
        $r = Get-BcrRow $j 'orders-aurora-pg15'; $r.status | Should -Be 'UNKNOWN'; $r.weekly.st | Should -Be 'UNKNOWN'; $r.gaps | Should -Match 'unreadable'
        (Get-BcrRow $j 'orders-dr-pg15').status | Should -Be 'COMPLIANT'
        (Get-BcrRow $j 'billing-aurora-mysql').status | Should -Be 'UNKNOWN'
        $j._err | Should -Match '\[1/2\] us-east-1: .* - ERROR: .*list-backup-vaults'
        @($j.regions | Where-Object status -EQ 'error').Count | Should -Be 2
    }
    It 'global clusters denied: role unknown' {
        $j = RunJson @('-ProfileName', 'prod', '-Region', 'us-west-2') 'globaldeny'
        $r = Get-BcrRow $j 'orders-dr-pg15'; $r.global_role | Should -Be 'unknown'; $r.weekly.st | Should -Be 'FAIL'
        $j._err | Should -Match 'describe-global-clusters: \(AccessDenied\)'
    }
    It 'instance snapshots denied: daily UNKNOWN for instances only' {
        $j = RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1') 'snapdeny'
        (Get-BcrRow $j 'reports-pg').daily.st | Should -Be 'UNKNOWN'
        (Get-BcrRow $j 'orders-aurora-pg15').status | Should -Be 'COMPLIANT'
    }
    It 'empty account' {
        $j = RunJson @('-ProfileName', 'prod', '-AllRegions') 'empty'
        @($j.rows).Count | Should -Be 0; @($j.regions).Count | Should -Be 0
    }
    It 'recovery point quirks: no lifecycle / AVAILABLE / continuous' {
        $r = Get-BcrRow (RunJson @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Identifier', 'orders-*') 'rpquirks') 'orders-aurora-pg15'
        $r.weekly.have | Should -Be $r.weekly.need; $r.weekly.need | Should -BeGreaterOrEqual 4; $r.weekly.st | Should -Be 'OK'
        @($r.recovery_points | Where-Object { $_.class -eq 'weekly' -and $_.counted -and $_.status -eq 'AVAILABLE' -and $_.ret -eq 35 }).Count | Should -Be $r.weekly.have
        @($r.recovery_points | Where-Object { $_.reason -match '^continuous backup' -and -not $_.counted }).Count | Should -Be 1
    }
}
