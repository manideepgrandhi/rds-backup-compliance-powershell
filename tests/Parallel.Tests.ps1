# Parallel.Tests.ps1 - -Parallel N: the same report as one-by-one, whatever order regions finish in; progress lines;
# never more than N regions at a time; a failing region does not stop the others (parallel and serial).
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Slow = @{ MOCK_SLEEP = 'ap-south-1=1,ca-central-1=0.5' }
    function Norm { param([string]$T) $j = ConvertFrom-BcrJsonText $T; $j.Remove('generated_utc'); $j.Remove('generated_local'); return ($j | ConvertTo-Json -Depth 60) }
    $script:P1 = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Parallel', '1', '-Format', 'json') -Env $Slow
    $script:P4 = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Parallel', '4', '-Format', 'json') -Env $Slow
    $script:P4v = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Parallel', '4', '-Format', 'json', '-Verbose') -Env $Slow
    $script:P2v = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Parallel', '2', '-Format', 'json', '-Verbose') -Env @{ MOCK_SLEEP = 'ap-south-1=1' }
}

Describe '-Parallel' {
    It 'parallel output identical to one-by-one (slow first region finishes last)' {
        $P1.ExitCode | Should -Be 0; $P4.ExitCode | Should -Be 0
        Norm $P4.Stdout | Should -BeExactly (Norm $P1.Stdout)
        Norm $P2v.Stdout | Should -BeExactly (Norm $P1.Stdout)
    }
    It 'one-by-one: no parallel lines' { $P1.Stderr | Should -Not -Match 'started|at a time|regions in order' }
    It 'default 4 at a time; quiet without -Verbose' {
        $P4.Stderr | Should -Match 'scanning 5 regions, up to 4 at a time'
        $P4.Stderr | Should -Not -Match 'started|regions in order|\(empty\)'
        $P4.Stderr | Should -Match '(?m)111111111111: 5 regions scanned, 2 empty: ap-south-1, eu-west-1$'
        ([regex]::Match($P1.Stderr, 'regions scanned.*').Value) | Should -Be ([regex]::Match($P4.Stderr, 'regions scanned.*').Value)
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'json')
        $r.Stderr | Should -Match 'up to 4 at a time'
    }
    It '-Verbose: started lines and regions in order' {
        $P4v.Stderr | Should -Match '\[1/5\] ap-south-1: started'
        $P4v.Stderr | Should -Match '\[5/5\] us-west-2: started'
        $P4v.Stderr | Should -Match '(?m)regions in order: ap-south-1: done \(0 resources\); ca-central-1: done \(0 resources\); eu-west-1: done \(0 resources\); us-east-1: done \(6 resources\); us-west-2: done \(2 resources\)$'
    }
    It 'regions are reported as they finish (slow ap-south-1 after us-east-1)' {
        $l = $P4v.Stderr -split "`n"
        $a = [array]::FindIndex($l, [Predicate[string]] { param($x) $x -match 'us-east-1: 3 clusters' })
        $b = [array]::FindIndex($l, [Predicate[string]] { param($x) $x -match 'ap-south-1: \(empty\)' })
        $a | Should -BeGreaterThan -1; $b | Should -BeGreaterThan $a
    }
    It 'never more than N regions running at once' {
        $run = 0; $max = 0
        foreach ($x in $P2v.Stderr -split "`n") {
            if ($x -match ': started$') { $run++; if ($run -gt $max) { $max = $run } }
            elseif ($x -match ': calls finished$') { $run-- }
        }
        $max | Should -Be 2
    }
}

Describe 'a failing region does not stop the others' {
    It '<mode>' -ForEach @(@{ mode = 'parallel'; p = '4' }, @{ mode = 'one by one'; p = '1' }) {
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Parallel', $p, '-Format', 'json') -Scenario 'regioncrash'
        $r.ExitCode | Should -Be 0
        $j = ConvertFrom-BcrJsonText $r.Stdout
        $w = $j.regions | Where-Object region -EQ 'us-west-2'
        $w.status | Should -Be 'error'; $w.errors[0] | Should -BeLike 'region scan failed*'
        @($j.rows | Where-Object region -EQ 'us-east-1').Count | Should -Be 6
        (Get-BcrRow $j 'orders-aurora-pg15').status | Should -Be 'COMPLIANT'
        $r.Stderr | Should -Match '\[ERROR\] \[5/5\] us-west-2: failed'
        $r.Stderr | Should -Match '(?m)5 regions scanned, 2 empty: ap-south-1, eu-west-1; 1 failed: us-west-2$'
    }
}
