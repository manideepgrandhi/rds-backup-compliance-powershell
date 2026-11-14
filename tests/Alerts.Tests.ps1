# Alerts.Tests.ps1 - -AlertEmail over SMTP against a local sink (tests/alerts/smtp_sink.py): test alert, status in the
# subject, the text report as the body, -AlertOn, -AlertAttach, and a failed send that is only a warning.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Py = Get-BcrPython
    $script:Mail = New-BcrTestDir 'mail'
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Py)
    $psi.ArgumentList.Add((Join-Path $PSScriptRoot 'alerts/smtp_sink.py')); $psi.ArgumentList.Add($Mail)
    $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $script:Sink = [System.Diagnostics.Process]::Start($psi)
    $script:Port = $Sink.StandardOutput.ReadLine().Trim()
    $script:Smtp = @('-AlertSmtpServer', '127.0.0.1', '-AlertSmtpPort', $Port, '-AlertFrom', 'rds-backup@example.com')
    function Get-Mails { @(Get-ChildItem -LiteralPath $Mail -Filter '*.eml' | Sort-Object { [int]($_.BaseName -replace '\D', '') }) }
    function Read-Mail { param([string]$Path) return (& $Py (Join-Path $PSScriptRoot 'alerts/read_mail.py') $Path | ConvertFrom-Json) }
}
AfterAll { if ($Sink -and -not $Sink.HasExited) { $Sink.Kill() } }

Describe '-AlertEmail (SMTP)' {
    It '-AlertTest sends a test message and scans nothing' {
        $n = (Get-Mails).Count
        $log = Join-Path $Mail 'calls.jsonl'
        $r = Invoke-Bcr -Arguments (@('-AlertEmail', 'dba@example.com', '-AlertTest') + $Smtp) -Env @{ MOCK_LOG = $log }
        $r.ExitCode | Should -Be 0
        @(Get-BcrMockLog $log).Count | Should -Be 0
        (Get-Mails).Count | Should -Be ($n + 1)
        $m = Read-Mail (Get-Mails)[-1].FullName
        $m.subject | Should -Match '^\[rds_backup_compliance\] TEST alert from '
        $m.to | Should -Be 'dba@example.com'; $m.from | Should -Be 'rds-backup@example.com'
    }
    It 'NON-COMPLIANT: subject with the counts, the text report as the body, files attached' {
        $n = (Get-Mails).Count; $o = New-BcrTestDir 'ao'
        $r = Invoke-Bcr -Arguments (@('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'csv,html', '-OutputDir', $o, '-AlertEmail', 'dba@example.com,ops@example.com', '-AlertAttach', '-FailOnNonCompliant') + $Smtp)
        $r.ExitCode | Should -Be 5
        $r.Stderr | Should -Match 'Alert: e-mail sent to dba@example.com, ops@example.com via 127\.0\.0\.1:[0-9]+ \(4 attachment\(s\)\)'
        (Get-Mails).Count | Should -Be ($n + 1)
        $m = Read-Mail (Get-Mails)[-1].FullName
        $m.subject | Should -Be '[rds_backup_compliance] NON-COMPLIANT: 3 non-compliant of 6 - prod-core (111111111111)'
        $m.to | Should -Match 'dba@example.com'; $m.to | Should -Match 'ops@example.com'
        $m.body | Should -Match 'RDS backup compliance - account prod-core \(111111111111\)'
        $m.body | Should -Match 'billing-aurora-mysql'
        @($m.attachments | Sort-Object) | Should -Be (@(Get-ChildItem -LiteralPath $o -File | ForEach-Object Name) | Sort-Object)
    }
    It '-AlertOn noncompliant: nothing sent when all is compliant; -AlertOn always sends' {
        $n = (Get-Mails).Count
        $a = @('-ProfileName', 'nonprod', '-Region', 'ap-south-1', '-Identifier', 'hr-*', '-AlertEmail', 'dba@example.com') + $Smtp
        $r = Invoke-Bcr -Arguments $a
        $r.ExitCode | Should -Be 0; $r.Stderr | Should -Match 'Alert: nothing to report'
        (Get-Mails).Count | Should -Be $n
        $r = Invoke-Bcr -Arguments ($a + @('-AlertOn', 'always'))
        (Get-Mails).Count | Should -Be ($n + 1)
        (Read-Mail (Get-Mails)[-1].FullName).subject | Should -Match '^\[rds_backup_compliance\] OK: 0 non-compliant of 1 - 222222222222$'
    }
    It 'region errors alone trigger the alert (ERRORS)' {
        $n = (Get-Mails).Count
        $r = Invoke-Bcr -Arguments (@('-ProfileName', 'prod', '-Region', 'us-west-2', '-Identifier', 'orders-*', '-AlertEmail', 'dba@example.com') + $Smtp) -Scenario 'backupdeny'
        $r.ExitCode | Should -Be 0
        (Get-Mails).Count | Should -Be ($n + 1)
        (Read-Mail (Get-Mails)[-1].FullName).subject | Should -Match '^\[rds_backup_compliance\] ERRORS: 0 non-compliant'
    }
    It 'a failed send is a warning and keeps the exit code' {
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'prod', '-Region', 'us-east-1', '-AlertEmail', 'dba@example.com', '-AlertSmtpServer', '127.0.0.1', '-AlertSmtpPort', '9')
        $r.ExitCode | Should -Be 0
        $r.Stderr | Should -Match '\[WARN(ING)?\] Alert: SMTP 127\.0\.0\.1:9 failed'
    }
    It 'alert settings from the config file' {
        $n = (Get-Mails).Count
        $c = Join-Path $Mail 'alert.conf'
        Set-Content -LiteralPath $c -Value "alert-email = cfg@example.com`nalert-smtp-server = 127.0.0.1`nalert-smtp-port = $Port`nalert-on = always"
        $r = Invoke-Bcr -Arguments @('-ProfileName', 'nonprod', '-Region', 'ap-south-1', '-ConfigFile', $c)
        $r.ExitCode | Should -Be 0
        (Get-Mails).Count | Should -Be ($n + 1)
        (Read-Mail (Get-Mails)[-1].FullName).to | Should -Be 'cfg@example.com'
    }
}
