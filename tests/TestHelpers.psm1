# tests/TestHelpers.psm1 - shared plumbing for the Pester tests.
#   * every run is a child pwsh process that goes through the mock AWS CLI (tests/mock/aws, Python 3; on Windows
#     tests/mock/win/aws.cmd calls it) with fake credentials, no network and a frozen clock
#     (RDS_BCR_NOW / MOCK_NOW = 2026-11-14 10:00 UTC, a Saturday)
#   * no bash needed: works the same on Windows and Linux
#   * the Bash tool is only used by Parity.Tests.ps1, when RDS_BCR_BASH_DIR points at a clone of rds-backup-compliance

$script:Root = Split-Path -Parent $PSScriptRoot
$script:Now = 1794650400   # 2026-11-14 10:00 UTC (Saturday)
$script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

function Get-BcrTestRoot { return $script:Root }
function Get-BcrTestNow { return $script:Now }
# Get-BcrMockDir: the directory that must come first on PATH so `aws` is the mock
function Get-BcrMockDir { if ($IsWindows) { return Join-Path $PSScriptRoot 'mock/win' } return Join-Path $PSScriptRoot 'mock' }
# Get-BcrPython: python3 (Linux / macOS) or python (Windows)
function Get-BcrPython { foreach ($n in 'python3', 'python') { $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { return $c.Source } }; return $null }

# New-BcrTestDir: a fresh empty directory (under the Pester TestDrive when there is one)
function New-BcrTestDir {
    param([string]$Name = 'd')
    $base = if (Test-Path 'TestDrive:\') { (Get-PSDrive TestDrive).Root } else { [System.IO.Path]::GetTempPath() }
    $d = Join-Path $base ($Name + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return (Resolve-Path -LiteralPath $d).ProviderPath
}

# Get-BcrChildEnv: the environment of a child run (mock first on PATH, fake credentials, no AWS config, frozen clock)
function Get-BcrChildEnv {
    param([string]$Scenario = 'fleet', [hashtable]$Env = @{})
    $e = [ordered]@{}
    foreach ($kv in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $e[[string]$kv.Key] = [string]$kv.Value }
    foreach ($k in @($e.Keys)) { if ($k -match '^(AWS_|MOCK_|RDS_BCR_)') { $e.Remove($k) } }
    $pathKey = @($e.Keys | Where-Object { $_ -ieq 'PATH' })[0]; if (-not $pathKey) { $pathKey = 'PATH' }
    $e[$pathKey] = (Get-BcrMockDir) + [System.IO.Path]::PathSeparator + $e[$pathKey]
    $none = Join-Path ([System.IO.Path]::GetTempPath()) 'rbc-no-aws-config'
    if (-not (Test-Path -LiteralPath $none)) { [System.IO.File]::WriteAllText($none, '') }
    $e['AWS_ACCESS_KEY_ID'] = 'fake'; $e['AWS_SECRET_ACCESS_KEY'] = 'fake'; $e['AWS_CONFIG_FILE'] = $none; $e['AWS_SHARED_CREDENTIALS_FILE'] = $none
    $e['AWS_EC2_METADATA_DISABLED'] = 'true'; $e['AWS_ENDPOINT_URL'] = 'http://127.0.0.1:9'
    $e['MOCK_NOW'] = [string]$script:Now; $e['RDS_BCR_NOW'] = [string]$script:Now; $e['MOCK_SCENARIO'] = $Scenario
    $e['PYTHONUTF8'] = '1'; $e['PYTHONIOENCODING'] = 'utf-8'
    foreach ($k in $Env.Keys) { $t = if ($k -ieq 'PATH') { $pathKey } else { $k }; if ($null -eq $Env[$k]) { $e.Remove($t) } else { $e[$t] = [string]$Env[$k] } }   # PATH = replaces it (mock included)
    return $e
}

# Invoke-Bcr: run Invoke-RdsBackupCompliance.ps1 in a child pwsh. Returns @{ ExitCode; Stdout; Stderr }
#   -Arguments  parameter list as strings ('-ProfileName', 'prod', ...); -Scenario mock scenario; -Env extra env
#   ($null value = unset); -WorkingDirectory; -Script another .ps1 (a copy of the tool)
function Invoke-Bcr {
    param([string[]]$Arguments = @(), [string]$Scenario = 'fleet', [hashtable]$Env = @{}, [string]$WorkingDirectory, [string]$Script)
    if (-not $Script) { $Script = Join-Path $script:Root 'Invoke-RdsBackupCompliance.ps1' }
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).ProviderPath }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $Script) + $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.Environment.Clear()
    $ce = Get-BcrChildEnv -Scenario $Scenario -Env $Env
    foreach ($k in $ce.Keys) { $psi.Environment[$k] = $ce[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $er = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Stdout = ($o.Result -replace "`r`n", "`n"); Stderr = ($er.Result -replace "`r`n", "`n") }
}

# Get-BcrBashDir: a clone of the Bash tool (RDS_BCR_BASH_DIR) for the parity tests, or $null (Linux / macOS only)
function Get-BcrBashDir {
    $d = $env:RDS_BCR_BASH_DIR
    if ($IsWindows -or -not $d -or -not (Test-Path -LiteralPath (Join-Path $d 'rds_backup_compliance_report.sh'))) { return $null }
    if (-not (Get-Command bash -ErrorAction SilentlyContinue) -or -not (Get-Command jq -ErrorAction SilentlyContinue)) { return $null }
    return $d
}
# Invoke-BcrBash: run the Bash tool with the same mock, clock and environment (tests/parity/date freezes `date`)
function Invoke-BcrBash {
    param([string[]]$Arguments = @(), [string]$Scenario = 'fleet', [hashtable]$Env = @{})
    $psi = [System.Diagnostics.ProcessStartInfo]::new('bash')
    $psi.ArgumentList.Add((Join-Path (Get-BcrBashDir) 'rds_backup_compliance_report.sh')); foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.Environment.Clear()
    $ce = Get-BcrChildEnv -Scenario $Scenario -Env $Env
    $ce['PATH'] = (Join-Path $PSScriptRoot 'parity') + ':' + $ce['PATH']
    foreach ($k in $ce.Keys) { $psi.Environment[$k] = $ce[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $er = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Stdout = $o.Result; Stderr = $er.Result }
}

# ConvertFrom-BcrJsonText: report JSON as nested hashtables
function ConvertFrom-BcrJsonText { param([string]$Text) return ($Text | ConvertFrom-Json -AsHashtable -Depth 100) }
# Get-BcrRow: one row of a JSON report by identifier
function Get-BcrRow { param($Report, [string]$Id) return @($Report.rows | Where-Object { $_.identifier -eq $Id })[0] }
# Get-BcrFile: the single file in Dir whose name matches the regex
function Get-BcrFile {
    param([string]$Dir, [string]$Pattern)
    $f = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -match $Pattern })
    if ($f.Count -ne 1) { throw "expected 1 file matching $Pattern in $Dir, found $($f.Count): $(($f.Name) -join ', ')" }
    return $f[0].FullName
}
# Get-BcrCsvHeader: the header line of a CSV file, quotes removed
function Get-BcrCsvHeader { param([string]$Path) return ([System.IO.File]::ReadAllLines($Path)[0] -replace '"', '') }
# Read-BcrCsv: CSV rows as objects
function Read-BcrCsv { param([string]$Path) return @(Import-Csv -LiteralPath $Path -Encoding utf8) }
# Get-BcrMockLog: the AWS CLI calls the mock recorded (one string array per call)
function Get-BcrMockLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(foreach ($l in [System.IO.File]::ReadAllLines($Path)) { if ($l) { , [string[]]@($l | ConvertFrom-Json) } })
}
# Test-BcrBrowser: node + puppeteer-core + Chrome available for the headless page checks
function Get-BcrChrome {
    if ($env:CHROME -and (Test-Path -LiteralPath $env:CHROME)) { return $env:CHROME }
    foreach ($c in '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', 'C:\Program Files\Google\Chrome\Application\chrome.exe') { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
function Test-BcrBrowser {
    if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not (Get-BcrChrome)) { return $false }
    Push-Location $PSScriptRoot   # puppeteer-core is installed in tests/node_modules
    try { $null = & node -e "require('puppeteer-core')" 2>&1; return ($LASTEXITCODE -eq 0) } finally { Pop-Location }
}
# Invoke-BcrNode: run one tests/browser/*.js script -> @{ ExitCode; Out }
function Invoke-BcrNode {
    param([string]$Js, [string[]]$Arguments, [hashtable]$Env = @{})
    $old = @{}; $Env['CHROME'] = (Get-BcrChrome)
    foreach ($k in $Env.Keys) { $old[$k] = [System.Environment]::GetEnvironmentVariable($k); [System.Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try { $out = & node (Join-Path $PSScriptRoot "browser/$Js") @Arguments 2>&1; return @{ ExitCode = $LASTEXITCODE; Out = ($out -join "`n") } }
    finally { foreach ($k in $old.Keys) { [System.Environment]::SetEnvironmentVariable($k, $old[$k]) } }
}

Export-ModuleMember -Function *
