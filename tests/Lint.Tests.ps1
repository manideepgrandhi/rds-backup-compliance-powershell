# Lint.Tests.ps1 - PSScriptAnalyzer (no Error findings; settings in PSScriptAnalyzerSettings.psd1) and file hygiene.
BeforeDiscovery { $script:NoPssa = -not (Get-Module -ListAvailable PSScriptAnalyzer) }
BeforeAll { $script:Root = Split-Path -Parent $PSScriptRoot }

Describe 'PSScriptAnalyzer' -Skip:$NoPssa {
    It 'no Error-severity findings in the tool, its module and the tests' {
        $r = @(Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings (Join-Path $Root 'PSScriptAnalyzerSettings.psd1') -Severity Error)
        ($r | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'no Warning findings in src and the wrapper' {
        $r = @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'src') -Recurse -Settings (Join-Path $Root 'PSScriptAnalyzerSettings.psd1')) + @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'Invoke-RdsBackupCompliance.ps1') -Settings (Join-Path $Root 'PSScriptAnalyzerSettings.psd1'))
        ($r | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) -join "`n" | Should -BeNullOrEmpty
    }
}

Describe 'files' {
    It 'every .ps1 / .psm1 parses' {
        foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -Include '*.ps1', '*.psm1' | Where-Object FullName -NotMatch 'node_modules') {
            $err = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
            @($err).Count | Should -Be 0 -Because $f.FullName
        }
    }
    It 'the page script is the Bash tool''s (escaping helper present)' {
        $js = [System.IO.File]::ReadAllText((Join-Path $Root 'assets/backup_page.js'))
        $js | Should -Match 'var esc = function'
        $js | Should -Match 'var alabel = function'
    }
    It 'the real exceptions file and generated reports are git-ignored' {
        $gi = [System.IO.File]::ReadAllText((Join-Path $Root '.gitignore'))
        foreach ($p in 'compliance_exceptions.conf', '__pycache__', 'node_modules') { $gi | Should -Match ([regex]::Escape($p)) }
    }
}
