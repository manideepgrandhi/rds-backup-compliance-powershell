# Browser.Tests.ps1 - the HTML page in headless Chrome (node + puppeteer-core): filters, tabs, the in-page CSV export
# (compared with the CSV file), exceptions, cross-tab links, duplicate identifiers, and a tampered -Merge file that must
# not inject HTML / JS. The page script (assets/backup_page.js) and the checks are the Bash tool's.
# Skipped when node / puppeteer-core / Chrome are missing, unless RDS_BCR_REQUIRE_BROWSER=1 (CI).
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:NoBrowser = -not (Test-BcrBrowser) -and $env:RDS_BCR_REQUIRE_BROWSER -ne '1'
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:D = New-BcrTestDir 'browser'
    $script:Single = Join-Path $D 'single'; $script:Data = Join-Path $D 'data'
    $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'csv,html', '-OutputDir', $Single)
    foreach ($p in @(@('prod', '-AllRegions'), @('nonprod', '-Region', 'ap-south-1'), @('dev', '-Region', 'eu-west-1'))) {
        $null = Invoke-Bcr -Arguments (@('-ProfileName', $p[0]) + $p[1..($p.Count - 1)] + @('-SaveData', '-OutputDir', $Data, '-Format', 'json'))
    }
    Get-ChildItem -LiteralPath $Data -Filter 'rds_backup_compliance_*' | Remove-Item
    $script:Merged = Join-Path $D 'all accounts.html'
    $null = Invoke-Bcr -Arguments @('-Merge', $Data, '-OutputDir', $Merged)
    # same identifiers in a second account, one resource with no backups at all
    $prod = Join-Path $Data 'rds_backup_111111111111_20261114.json'
    $dup = [System.IO.File]::ReadAllText($prod).Replace('111111111111', '444444444444') | ConvertFrom-Json -AsHashtable -Depth 100
    $dup.resources[0].snapshots = @()
    $script:Dup444 = Join-Path $D 'dup444.json'; [System.IO.File]::WriteAllText($Dup444, ($dup | ConvertTo-Json -Depth 100))
    $script:DupHtml = Join-Path $D 'dup ids.html'
    $null = Invoke-Bcr -Arguments @('-Merge', $prod, $Dup444, '-OutputDir', $DupHtml)
    if (-not (Test-BcrBrowser)) { if ($env:RDS_BCR_REQUIRE_BROWSER -eq '1') { throw 'node + puppeteer-core + Chrome required (RDS_BCR_REQUIRE_BROWSER=1)' } }
}

Describe 'HTML page in headless Chrome' -Skip:$NoBrowser {
    It 'single account: every page check, CSV export identical to the CSV file' {
        $h = Get-BcrFile $Single '\.html$'; $c = Get-BcrFile $Single '_100000\.csv$'
        $r = Invoke-BcrNode 'browser_check.js' @($h) @{ CSV_CMP = $c }
        $r.Out | Should -Match '"checks":[0-9]+'
        $r.Out | Should -Match '"fails":\[\]'
        $r.ExitCode | Should -Be 0
    }
    It 'merged report (3 accounts)' {
        $r = Invoke-BcrNode 'browser_check.js' @($Merged)
        $r.Out | Should -Match '"checks":[0-9]+'
        $r.ExitCode | Should -Be 0 -Because $r.Out
    }
    It 'cross-tab links, Back button, deep links: <name>' -ForEach @(@{ name = 'single'; k = 'single' }, @{ name = 'merged'; k = 'merged' }, @{ name = 'duplicate identifiers'; k = 'dup' }) {
        $h = switch ($k) { 'single' { Get-BcrFile $Single '\.html$' } 'merged' { $Merged } 'dup' { $DupHtml } }
        $r = Invoke-BcrNode 'link_check.js' @($h)
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match '"fails":\[\]'
    }
    It 'exceptions: column, quick filter, pop-up, CSV' {
        $ex = Join-Path $D 'ok.conf'
        [System.IO.File]::WriteAllText($ex, "111111111111 | legacy-mysql | backup | 2027-03-31 | Decommission in Q1 (CHG-1234)`n111111111111 | reports-pg | patch,backup | 2026-10-03 | Vendor app freeze | ticket A|B`n111111111111|Orders-Aurora-PG15|BACKUP|2027-01-01|<b>Old</b> migration window`n111111111111 | shop-dr-mysql | backup | 2026-10-02 | =DR rebuild`n111111111111 | gone-db | backup | 2027-01-01 | Retired server`n")
        $o = Join-Path $D 'exc'
        $null = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-AllRegions', '-Format', 'csv,html', '-OutputDir', $o, '-Exceptions', $ex) -Env @{ RDS_BCR_EXC_NOW = '1791000000' }
        $h = Get-BcrFile $o '\.html$'
        $r = Invoke-BcrNode 'browser_exceptions.js' @($h)
        $r.ExitCode | Should -Be 0 -Because $r.Out
        $r = Invoke-BcrNode 'browser_check.js' @($h) @{ CSV_CMP = (Get-BcrFile $o '_100000\.csv$') }
        $r.ExitCode | Should -Be 0 -Because $r.Out
    }
    It 'a tampered -Merge file cannot inject HTML / JS' {
        $x = '"><img src=x data-xss=1 onerror="window.__xss=1">'
        $t = [System.IO.File]::ReadAllText((Join-Path $Data 'rds_backup_111111111111_20261114.json')) | ConvertFrom-Json -AsHashtable -Depth 100
        foreach ($r in $t.resources) { foreach ($s in $r.snapshots) { $s.kind = [string]$s.kind + $x } }
        $t.accounts[0].name = '</title><script>window.__xss=2</script>'
        $xd = Join-Path $D 'xss in'; New-Item -ItemType Directory -Path $xd | Out-Null
        $f = Join-Path $xd 'prod.json'; [System.IO.File]::WriteAllText($f, ($t | ConvertTo-Json -Depth 100))
        [System.IO.File]::ReadAllText($f) | Should -Match 'data-xss'
        $o = Join-Path $D 'xss out'
        (Invoke-Bcr -Arguments @('-Merge', $f, '-Format', 'html', '-OutputDir', $o)).ExitCode | Should -Be 0
        $h = Get-BcrFile $o '\.html$'
        ([regex]::Matches([System.IO.File]::ReadAllText($h), '</script>')).Count | Should -Be 2
        $r = Invoke-BcrNode 'xss_check.js' @($h)
        $r.ExitCode | Should -Be 0 -Because $r.Out
    }
}
