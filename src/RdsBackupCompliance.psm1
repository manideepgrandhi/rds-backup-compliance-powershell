# src/RdsBackupCompliance.psm1 - loads the parts in dependency order and the HTML assets.
# Everything is module-private except Invoke-RdsBackupCompliance; Invoke-RdsBackupCompliance.ps1 is a thin wrapper.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

foreach ($part in 'Json', 'Time', 'Options', 'Aws', 'Collect', 'Evaluate', 'Render', 'Data', 'Alerts', 'Main') {
    . (Join-Path $PSScriptRoot "$part.ps1")
}

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:AssetDir = Join-Path $script:RepoRoot 'assets'
$script:Assets = @{
    Css    = [System.IO.File]::ReadAllText((Join-Path $script:AssetDir 'backup_report.css'))
    PageJs = [System.IO.File]::ReadAllText((Join-Path $script:AssetDir 'backup_page.js'))
}

Export-ModuleMember -Function Invoke-RdsBackupCompliance
