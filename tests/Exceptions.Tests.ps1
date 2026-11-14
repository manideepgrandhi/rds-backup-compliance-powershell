# Exceptions.Tests.ps1 - compliance_exceptions.conf: the same file format as the Bash tools, strict validation before
# any AWS call, COMPLIANT (EXCEPTION), flags (expiring soon / no longer needed / exception expired), counts, unmatched
# entries, CSV / text / HTML output, the default file next to the script, the config key, -SaveData and -Merge.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ExNow = @{ RDS_BCR_EXC_NOW = '1791000000' }   # "today" for the expiry dates only = 2026-10-03 UTC
    $script:D = New-BcrTestDir 'exc'
    $script:Ok = Join-Path $D 'ok.conf'
    [System.IO.File]::WriteAllText($Ok, @'
# account_id | identifier | scope | expires | reason
111111111111 | legacy-mysql | backup | 2027-03-31 | Decommission in Q1 (CHG-1234)

111111111111 | reports-pg   | patch,backup | 2026-10-03 | Vendor app freeze | ticket A|B
  111111111111|Orders-Aurora-PG15|BACKUP|2027-01-01|<b>Old</b> migration window
111111111111 | shop-dr-mysql | backup | 2026-10-02 | =DR rebuild
111111111111 | gone-db | backup | 2027-01-01 | Retired server
111111111111 | billing-aurora-mysql | patch | 2027-01-01 | Patch-only exception (not applied by the backup tool)

'@)
    function RunJ { param([string[]]$A, [hashtable]$E = $ExNow) $r = Invoke-Bcr -Arguments ($A + @('-Format', 'json')) -Env $E; $j = ConvertFrom-BcrJsonText $r.Stdout; $j['_err'] = $r.Stderr; $j['_rc'] = $r.ExitCode; return $j }
    $script:Base = RunJ @('-ProfileName', 'prod', '-AllRegions')
    $script:On = RunJ @('-ProfileName', 'prod', '-AllRegions', '-Exceptions', $Ok)
}

Describe 'applied exceptions' {
    It 'without a file: no exception fields' {
        $Base.totals.ContainsKey('exceptions') | Should -BeFalse
        @($Base.rows | Where-Object { $_.ContainsKey('exception') }).Count | Should -Be 0
        $Base.totals.compliant | Should -Be 2; $Base.totals.non_compliant | Should -Be 4; $Base.totals.compliance.pct | Should -Be 33
    }
    It 'totals count excepted rows as compliant' {
        $t = $On.totals
        $t.compliant | Should -Be 4; $t.non_compliant | Should -Be 2; $t.not_yet_due | Should -Be 2
        $t.compliance.compliant | Should -Be 4; $t.compliance.of | Should -Be 6; $t.compliance.pct | Should -Be 67
    }
    It 'status COMPLIANT, real status kept in actual_status' {
        $x = @($On.rows | Where-Object exception -EQ 'yes' | ForEach-Object { "$($_.identifier)|$($_.status)|$($_.actual_status)" } | Sort-Object)
        $x | Should -Be @('legacy-mysql|COMPLIANT|NON-COMPLIANT', 'orders-aurora-pg15|COMPLIANT|COMPLIANT', 'reports-pg|COMPLIANT|NON-COMPLIANT')
    }
    It 'flags' {
        $f = @{}; foreach ($r in $On.rows | Where-Object exception -NE 'no') { $f[$r.identifier] = $r.exception_flag }
        $f.Count | Should -Be 4
        $f['legacy-mysql'] | Should -Be ''; $f['orders-aurora-pg15'] | Should -Be 'no longer needed'; $f['reports-pg'] | Should -Be 'expiring soon'; $f['shop-dr-mysql'] | Should -Be 'exception expired'
        $s = Get-BcrRow $On 'shop-dr-mysql'; $s.exception | Should -Be 'expired'; $s.status | Should -Be 'NON-COMPLIANT'
        $b = Get-BcrRow $On 'billing-aurora-mysql'; $b.exception | Should -Be 'no'; $b.status | Should -Be 'NON-COMPLIANT'
    }
    It 'reason may contain |; expiry kept' {
        $r = Get-BcrRow $On 'reports-pg'; $r.exception_reason | Should -Be 'Vendor app freeze | ticket A|B'; $r.exception_expires | Should -Be '2026-10-03'
    }
    It 'counts and the unmatched entry' {
        $e = $On.totals.exceptions
        $e.entries | Should -Be 5; $e.applied | Should -Be 3; $e.attention | Should -Be 2; $e.expiring_soon | Should -Be 1; $e.no_longer_needed | Should -Be 1; $e.expired | Should -Be 1
        @($e.unmatched).Count | Should -Be 1
        $e.unmatched[0].line | Should -Be 7; $e.unmatched[0].account | Should -Be '111111111111'; $e.unmatched[0].identifier | Should -Be 'gone-db'
    }
    It 'other rows unchanged' {
        foreach ($r in $On.rows | Where-Object exception -EQ 'no') {
            $b = Get-BcrRow $Base $r.identifier
            $r.status | Should -Be $b.status; $r.gaps | Should -Be $b.gaps; $r.warnings | Should -Be $b.warnings
        }
    }
    It 'log lines' {
        $On._err | Should -Match 'ok\.conf:7 \(111111111111 gone-db\) matched no server'
        $On._err | Should -Match 'shop-dr-mysql expired on 2026-10-02'
        $On._err | Should -Match 'Exceptions \(backup\): 3 applied \(counted as COMPLIANT\), 2 expiring soon or no longer needed, 1 expired, 1 unmatched'
        $On._err | Should -Match '(?m)non-compliant: 2$'
        $On._err | Should -Match 'Exceptions file .*ok\.conf: 6 entries'
    }
    It '-NonCompliantOnly still reports the unmatched entries' {
        $j = RunJ @('-ProfileName', 'prod', '-AllRegions', '-NonCompliantOnly', '-Exceptions', $Ok)
        @($j.rows | ForEach-Object identifier | Sort-Object) | Should -Be @('billing-aurora-mysql', 'shop-dr-mysql')
        @($j.totals.exceptions.unmatched | ForEach-Object identifier) | Should -Be @('gone-db')
    }
    It '-FailOnNonCompliant: 0 when every NON-COMPLIANT server has an exception, 5 otherwise' {
        $all = Join-Path $D 'all.conf'
        Set-Content -LiteralPath $all -Value (@($Base.rows | Where-Object status -EQ 'NON-COMPLIANT' | ForEach-Object { "$($_.account_id) | $($_.identifier) | backup | 2027-01-01 | all non-compliant" }) -join "`n")
        $j = RunJ @('-ProfileName', 'prod', '-AllRegions', '-FailOnNonCompliant', '-Exceptions', $all)
        $j._rc | Should -Be 0; $j.totals.non_compliant | Should -Be 0; $j.totals.exceptions.applied | Should -Be 4
        (RunJ @('-ProfileName', 'prod', '-AllRegions', '-FailOnNonCompliant', '-Exceptions', $Ok))._rc | Should -Be 5
    }
}

Describe 'exceptions in the files' {
    BeforeAll {
        $script:O = New-BcrTestDir 'excf'
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'csv,html,text', '-OutputDir', $O, '-Exceptions', $Ok) -Env $ExNow
        $script:C = Get-BcrFile $O '_100000\.csv$'
    }
    It 'CSV: 5 more columns at the end' { Get-BcrCsvHeader $C | Should -Match ',account_name,exception,exception_reason,exception_expires,exception_flag,actual_status$' }
    It 'CSV: COMPLIANT (EXCEPTION) on 3 rows, counted in the %' {
        $rows = Read-BcrCsv $C
        @($rows | Where-Object status -EQ 'COMPLIANT (EXCEPTION)').Count | Should -Be 3
        @($rows | Where-Object exception -EQ 'yes' | Where-Object counted_in_compliance_pct -EQ 'yes').Count | Should -Be 3
    }
    It 'CSV: expired row and the formula guard on the reason' {
        [System.IO.File]::ReadAllText($C) | Should -Match ([regex]::Escape('"expired","''=DR rebuild","2026-10-02","exception expired","NON-COMPLIANT"') + '\n')
    }
    It 'text: summary and Exceptions section' {
        $t = [System.IO.File]::ReadAllText((Get-BcrFile $O '\.txt$'))
        $t | Should -Match 'compliant 4 \(incl\. 3 exceptions\), non-compliant 2'
        $t | Should -Match '(?m)^Exceptions: 3 applied \(counted as compliant\); expiring soon or no longer needed: 2; expired: 1'
        $t | Should -Match 'line 7: 111111111111 gone-db matched no server'
        $t | Should -Match 'COMPLIANT \(EXCEPTION\)'
    }
    It 'HTML: exceptions in the page data, reason escaped' {
        $h = [System.IO.File]::ReadAllText((Get-BcrFile $O '\.html$'))
        $h | Should -Match '"exc":\{"entries":5'
        $h | Should -Not -Match '<b>Old</b>'
    }
}

Describe 'validation: a bad line stops the run before any AWS call' {
    It '<name>' -ForEach @(
        @{ name = 'missing field'; want = 'missing field'; line = '111111111111 | db1 | backup |  | r' }
        @{ name = 'too few fields'; want = 'expected 5 fields'; line = '111111111111 | db1 | backup | 2027-01-01' }
        @{ name = 'bad account'; want = 'account_id must be 12 digits'; line = '1111111111x1 | db1 | backup | 2027-01-01 | r' }
        @{ name = 'bad scope'; want = 'scope must be patch, backup or patch,backup'; line = '111111111111 | db1 | backups | 2027-01-01 | r' }
        @{ name = 'not a real date'; want = 'is not a valid date'; line = '111111111111 | db1 | backup | 2027-02-29 | r' }
        @{ name = 'date format'; want = 'expires must be a date YYYY-MM-DD'; line = '111111111111 | db1 | backup | 01-01-2027 | r' }
        @{ name = 'wildcard'; want = 'is not a DB instance / cluster identifier'; line = '111111111111 | * | backup | 2027-01-01 | r' }
        @{ name = 'duplicate'; want = 'duplicate entry for 111111111111 GOOD-db \(backup\), already on line 2'; line = '111111111111 | GOOD-db | patch,backup | 2027-01-01 | r' }
    ) {
        $f = Join-Path $D ("bad_" + ($name -replace '\W', '_') + '.conf')
        Set-Content -LiteralPath $f -Value "# header`n111111111111 | good-db | backup | 2027-01-01 | ok`n$line"
        $log = Join-Path $D ("calls_" + ($name -replace '\W', '_') + '.jsonl')
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Exceptions', $f) -Env @{ MOCK_LOG = $log }
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match ("Exceptions .*" + [regex]::Escape([System.IO.Path]::GetFileName($f)) + ":3: .*$want")
        @(Get-BcrMockLog $log).Count | Should -Be 0
    }
    It 'leap day and the same server in another scope are fine' {
        $f = Join-Path $D 'nodup.conf'
        Set-Content -LiteralPath $f -Value "111111111111 | db1 | backup | 2028-02-29 | leap day ok`n111111111111 | db1 | patch | 2027-01-01 | other scope, not a duplicate"
        (Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'json', '-Exceptions', $f)).ExitCode | Should -Be 0
    }
    It 'missing file: exit 1' {
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Exceptions', (Join-Path $D 'does-not-exist.conf'))
        $r.ExitCode | Should -Be 1; $r.Stderr | Should -Match 'Exceptions file not readable'
    }
}

Describe 'where the file comes from' {
    It 'default: compliance_exceptions.conf next to the script, absent = off' {
        $tc = New-BcrTestDir 'toolcopy'; $root = Get-BcrTestRoot
        Copy-Item -LiteralPath (Join-Path $root 'Invoke-RdsBackupCompliance.ps1') -Destination $tc
        Copy-Item -LiteralPath (Join-Path $root 'src'), (Join-Path $root 'assets') -Destination $tc -Recurse
        $s = Join-Path $tc 'Invoke-RdsBackupCompliance.ps1'
        $j = ConvertFrom-BcrJsonText (Invoke-Bcr -Script $s -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json') -Env $ExNow).Stdout
        $j.totals.ContainsKey('exceptions') | Should -BeFalse
        Copy-Item -LiteralPath $Ok -Destination (Join-Path $tc 'compliance_exceptions.conf')
        $j = ConvertFrom-BcrJsonText (Invoke-Bcr -Script $s -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json') -Env $ExNow).Stdout
        $j.totals.exceptions.applied | Should -Be 3
    }
    It 'config key exceptions =' {
        $all = Join-Path $D 'all2.conf'
        Set-Content -LiteralPath $all -Value (@($Base.rows | Where-Object status -EQ 'NON-COMPLIANT' | ForEach-Object { "$($_.account_id) | $($_.identifier) | backup | 2027-01-01 | all" }) -join "`n")
        $c = Join-Path $D 'c.conf'; Set-Content -LiteralPath $c -Value "exceptions = $all"
        $j = RunJ @('-ProfileName', 'prod', '-AllRegions', '-ConfigFile', $c)
        $j.totals.non_compliant | Should -Be 0; $j.totals.exceptions.applied | Should -Be 4
    }
    It '-SaveData files never carry exceptions; -Merge applies them at report time with zero AWS calls' {
        $s0 = New-BcrTestDir 'sd0'; $s1 = New-BcrTestDir 'sd1'
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json', '-SaveDataFile', (Join-Path $s0 'sd.json'))
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json', '-SaveDataFile', (Join-Path $s1 'sd.json'), '-Exceptions', $Ok) -Env $ExNow
        [System.IO.File]::ReadAllText((Join-Path $s1 'sd.json')) | Should -BeExactly ([System.IO.File]::ReadAllText((Join-Path $s0 'sd.json')))
        [System.IO.File]::ReadAllText((Join-Path $s1 'sd.json')) | Should -Not -Match 'exception'
        $log = Join-Path $D 'merge_calls.jsonl'
        $j = RunJ @('-Merge', (Join-Path $s0 'sd.json'), '-Exceptions', $Ok) -E @{ RDS_BCR_EXC_NOW = '1791000000'; MOCK_LOG = $log }
        $j.totals.compliant | Should -Be 4; $j.totals.exceptions.applied | Should -Be 3
        @(Get-BcrMockLog $log).Count | Should -Be 0
    }
}
