# src/Alerts.ps1 - optional e-mail alert through an SMTP relay (System.Net.Mail; no login, no TLS - an internal relay).
# Body = the text report; -AlertAttach also attaches the files this run wrote (HTML, CSV ...). A failed alert is a
# WARNING and never changes the exit code.

# Get-BcrAlertMessage: subject + body (tested directly; nothing is sent here)
function Get-BcrAlertMessage {
    param($Rep, [string]$Mode)
    if ($Mode -eq 'test') {
        return @{ Subject = "[rds_backup_compliance] TEST alert from $([System.Net.Dns]::GetHostName())"; Body = "Test alert from $script:ScriptName $script:ScriptVersion. No report attached.`n" }
    }
    $t = $Rep.T; $err = @($Rep.D.regions | Where-Object { $_.status -eq 'error' }).Count
    $st = if ($t.non_compliant -gt 0) { 'NON-COMPLIANT' } elseif ($err -gt 0) { 'ERRORS' } else { 'OK' }
    $subject = "[rds_backup_compliance] ${st}: $($t.non_compliant) non-compliant of $($t.resources) - $(Get-AccountsLabel $Rep.D)"
    if ($subject.Length -gt 200) { $subject = $subject.Substring(0, 197) + '...' }
    return @{ Subject = $subject; Body = (ConvertTo-BcrText $Rep); Status = $st }
}

# Send-BcrAlert: send when -AlertOn always, or (noncompliant) when a NON-COMPLIANT resource or a region error was found
function Send-BcrAlert {
    param($Rep, [string]$Mode, [string[]]$Attach = @())
    $O = $script:O
    if (-not $O.AlertEmails.Count) { return }
    $m = Get-BcrAlertMessage $Rep $Mode
    if ($Mode -ne 'test' -and $O.AlertOn -eq 'noncompliant' -and $m.Status -eq 'OK') { Write-BcrInfo 'Alert: nothing to report (all compliant, no errors); -AlertOn always sends anyway'; return }
    $from = if ($O.AlertFrom) { $O.AlertFrom } else { "rds-backup-compliance@$([System.Net.Dns]::GetHostName())" }
    $msg = [System.Net.Mail.MailMessage]::new()
    try {
        $msg.From = $from; foreach ($t in $O.AlertEmails) { $msg.To.Add($t) }
        $msg.Subject = $m.Subject; $msg.Body = $m.Body; $msg.BodyEncoding = [System.Text.Encoding]::UTF8; $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
        if ($O.AlertAttach) { foreach ($f in $Attach) { if (Test-Path -LiteralPath $f -PathType Leaf) { $msg.Attachments.Add([System.Net.Mail.Attachment]::new($f)) } } }
        $smtp = [System.Net.Mail.SmtpClient]::new($O.AlertSmtpServer, [int]$O.AlertSmtpPort)
        $smtp.Timeout = 60000
        try { $smtp.Send($msg) } finally { $smtp.Dispose() }
        Write-BcrInfo "Alert: e-mail sent to $($O.AlertEmails -join ', ') via $($O.AlertSmtpServer):$($O.AlertSmtpPort)$(if ($O.AlertAttach) { " ($($msg.Attachments.Count) attachment(s))" })"
    }
    catch { Write-BcrWarn "Alert: SMTP $($O.AlertSmtpServer):$($O.AlertSmtpPort) failed: $($_.Exception.Message)" }
    finally { $msg.Dispose() }
}
