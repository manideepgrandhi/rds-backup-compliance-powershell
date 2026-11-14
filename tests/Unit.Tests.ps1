# Unit.Tests.ps1 - helpers that mirror jq / Bash behaviour, tested in the module's scope (no AWS, no child process).
BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/RdsBackupCompliance.psm1') -Force }

Describe 'jq-compatible helpers' {
    It 'Round-Jq rounds half away from zero; J prints whole numbers without .0' {
        InModuleScope RdsBackupCompliance {
            Round-Jq 2.5 | Should -Be 3; Round-Jq -2.5 | Should -Be -3; Round-Jq 0.49 | Should -Be 0
            J 5.0 | Should -BeExactly '5'; J 10.5 | Should -BeExactly '10.5'; J 0.021 | Should -BeExactly '0.021'
        }
    }
    It 'Sort-JqBy is stable and orders like jq (null < false < true < numbers < strings, ordinal strings)' {
        InModuleScope RdsBackupCompliance {
            @(Sort-JqBy @('b', 'B', 'a', 10, 2, $true, $false, $null) { , $_ }) | Should -Be @($null, $false, $true, 2, 10, 'B', 'a', 'b')
            $x = @(@{ k = 1; n = 'first' }, @{ k = 0; n = 'x' }, @{ k = 1; n = 'second' })
            @(Sort-JqBy $x { $_.k } | ForEach-Object { $_.n }) | Should -Be @('x', 'first', 'second')
            @(Get-JqUnique @('b', 'a', 'b')) | Should -Be @('a', 'b')
        }
    }
    It 'Get-Or and Get-At follow jq // and negative indexes' {
        InModuleScope RdsBackupCompliance {
            Get-Or $null 'x' | Should -Be 'x'; Get-Or $false 'x' | Should -Be 'x'; Get-Or 0 'x' | Should -Be 0; Get-Or '' 'x' | Should -Be ''
            Get-At @(1, 2, 3) -1 | Should -Be 3; Get-At @(1, 2, 3) 5 | Should -BeNullOrEmpty
        }
    }
}

Describe 'CSV cells' {
    It 'every cell quoted, quotes doubled, formula guard on = + @ -' {
        InModuleScope RdsBackupCompliance {
            Format-BcrCsvRow @('a"b', '=SUM(A1)', '+1', '@x', '-2', 5, $null, 'ok') | Should -BeExactly '"a""b","''=SUM(A1)","''+1","''@x","''-2","5","","ok"'
        }
    }
}

Describe 'time' {
    It 'UTC and IST formatting, day of week, epoch parsing' {
        InModuleScope RdsBackupCompliance {
            $script:Cfg = @{ tz_offset = 19800; tz_label = 'IST' }
            Format-BcrUtc 1794650400 | Should -Be '2026-11-14 10:00 UTC'
            Format-BcrLoc 1794650400 | Should -Be '2026-11-14 15:30 IST'
            Get-Dow (Get-Day 1794650400) | Should -Be 6
            ConvertTo-BcrEpoch '2026-10-01T08:30:00.123000+05:30' | Should -Be (ConvertTo-BcrEpoch '2026-10-01T03:00:00Z')
        }
    }
    It 'second time zone: <z>' -ForEach @(
        @{ z = 'Asia/Kolkata'; o = 19800; l = 'IST' }, @{ z = 'UTC'; o = 0; l = 'UTC' }, @{ z = 'Asia/Calcutta'; o = 19800; l = 'IST' }
    ) {
        InModuleScope RdsBackupCompliance -Parameters @{ z = $z; o = $o; l = $l } {
            param($z, $o, $l)
            $t = Get-BcrTz $z 1794650400
            $t.offset | Should -Be $o; $t.label | Should -Be $l
        }
    }
}

Describe 'exceptions file parser' {
    It 'parses fields, scopes and reasons with |' {
        InModuleScope RdsBackupCompliance {
            $script:O = New-BcrOptions; $script:Run = @{ Now = 1794650400 }
            $f = Join-Path ([System.IO.Path]::GetTempPath()) ('exc_' + [guid]::NewGuid().ToString('N') + '.conf')
            [System.IO.File]::WriteAllText($f, "# c`n111111111111 | Db-One | Patch,BACKUP | 2027-01-31 | why | ticket`n")
            try {
                $e = @(Import-BcrExceptions $f '.')
                $e.Count | Should -Be 1
                $e[0].account | Should -Be '111111111111'; $e[0].identifier | Should -Be 'Db-One'; $e[0].expires | Should -Be '2027-01-31'
                $e[0].reason | Should -Be 'why | ticket'; @($e[0].scopes | Sort-Object) | Should -Be @('backup', 'patch'); $e[0].line | Should -Be 2
            }
            finally { Remove-Item -LiteralPath $f }
        }
    }
}
