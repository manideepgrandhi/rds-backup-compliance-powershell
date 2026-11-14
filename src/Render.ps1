# src/Render.ps1 - every output: compliance CSV, backups CSV, manual-older-than CSV, orphaned snapshots CSV, text,
# JSON and the HTML page (same Compliance / Backups tabs and page script as the Bash tool: assets/backup_page.js).
# All CSV cells are quoted text; a cell starting with = + @ - gets a leading ' so spreadsheets never run it as a formula.

# Format-BcrCsvRow: values -> one CSV line
function Format-BcrCsvRow {
    param([object[]]$Values)
    $cells = foreach ($v in $Values) {
        $t = if ($null -eq $v) { '' } else { J $v }
        if ($t -match '^[=+@-]') { $t = "'" + $t }
        '"' + $t.Replace('"', '""') + '"'
    }
    return ($cells -join ',')
}
# ConvertTo-BcrCstr: values -> strings, null -> "" (HTML "Export CSV" data; the page adds the formula guard)
function ConvertTo-BcrCstr { param([object[]]$Values) return , [string[]]@(foreach ($v in $Values) { if ($null -eq $v) { '' } else { J $v } }) }

function Test-YearlyOn { return ($script:Cfg.yearly -gt 0) }
function Get-Per { if (Test-YearlyOn) { return @('daily', 'weekly', 'monthly', 'yearly') } return @('daily', 'weekly', 'monthly') }
function Get-ExcCols { if ($null -ne $script:Exc) { return @('exception', 'exception_reason', 'exception_expires', 'exception_flag', 'actual_status') } return @() }
function Get-TzCol { return $script:Cfg.tz_label.ToLowerInvariant() }

# Get-BcrCsvHeader: compliance CSV columns (the HTML "Export CSV" uses the same list)
function Get-BcrCsvHeader {
    $h = [System.Collections.Generic.List[string]]::new()
    $h.AddRange([string[]]@('account_id', 'region', 'identifier', 'type', 'engine', 'engine_version', 'global_cluster', 'global_role', 'retention_days',
            'created_utc', 'age_days', 'backup_window', 'copy_tags_to_snapshot', 'last_automated_utc', "last_automated_$(Get-TzCol)"))
    foreach ($k in (Get-Per)) { foreach ($s in 'status', 'found', 'expected', 'target', 'missing', 'full_on') { $h.Add("${k}_$s") } }
    $h.AddRange([string[]]@('status', 'not_yet_due', 'gaps', 'warnings', 'weekly_retention', 'monthly_retention', 'backup_plans',
            'retention_mismatch_count', 'retention_mismatch', 'excess_daily', 'excess_weekly', 'excess_monthly', 'excess',
            'over_retention_count', 'over_retention', 'counted_in_compliance_pct', 'pitr_enabled', 'pitr_since_utc', 'account_name'))
    foreach ($c in (Get-ExcCols)) { $h.Add($c) }
    return , $h.ToArray()
}
function Get-PCols {
    param($C)
    if ($C.st -eq 'N/A' -or $C.st -eq 'UNKNOWN' -or $C.st -eq 'OFF' -or $null -eq $C.have) { return @($C.st, $null, $null, $null, '', '') }
    return @($C.st, $C.have, $C.need, (Get-Or $C.target $C.need), ((@($C.missing | Where-Object { $null -ne $_ } | ForEach-Object { Format-Dwk $_ })) -join '; '), (Get-Or $C.full_on_iso ''))
}
function Get-ExcLabel { param($Row) if ($Row.exception -eq 'yes') { return 'COMPLIANT (EXCEPTION)' } return $Row.status }
# Get-BcrCsvValues: one evaluated row -> compliance CSV values in header order
function Get-BcrCsvValues {
    param($R)
    $v = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($R.account_id, $R.region, $R.identifier, $R.type, $R.engine, $R.engine_version, $R.global_cluster, $R.global_role, $R.retention_days,
            $R.created, $R.age_days, $R.settings.backup_window, $R.settings.copy_tags, $R.last_automated_utc, $R.last_automated_local)) { $v.Add($x) }
    foreach ($k in (Get-Per)) { foreach ($x in (Get-PCols $R[$k])) { $v.Add($x) } }
    foreach ($x in @((Get-ExcLabel $R), $R.not_yet_due, $R.gaps, $R.warnings, $R.settings.weekly_retention, $R.settings.monthly_retention, $R.settings.plans,
            $R.retention_mismatch_count, $R.retention_mismatch, $R.excess_counts.daily, $R.excess_counts.weekly, $R.excess_counts.monthly, $R.excess,
            $R.over_retention_count, $R.over_retention, $(if ($R.status -eq 'NOT YET DUE') { 'no' } else { 'yes' }),
            $(if ($R.pitr.on) { 'yes' } else { 'no' }), $R.pitr.since, (Get-Or $R.account_name ''))) { $v.Add($x) }
    foreach ($c in (Get-ExcCols)) { $v.Add((Get-Or $R[$c] '')) }
    return , $v.ToArray()
}
function Join-Lines { param([System.Collections.Generic.List[string]]$L) if ($L.Count -eq 0) { return '' } return (($L -join "`n") + "`n") }

# ConvertTo-BcrCsv: the compliance CSV
function ConvertTo-BcrCsv {
    param($Rows)
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add((Format-BcrCsvRow (Get-BcrCsvHeader)))
    foreach ($r in $Rows) { $l.Add((Format-BcrCsvRow (Get-BcrCsvValues $r))) }
    return (Join-Lines $l)
}
# ConvertTo-BcrBackupsCsv: every snapshot / recovery point (same columns as the Backups tab "Export CSV"), then the
# manual snapshots without a current source (source_status SHARED / EXISTING / UNVERIFIED / ORPHANED)
function ConvertTo-BcrBackupsCsv {
    param($D, $OR)
    $now = $script:Now
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add((Format-BcrCsvRow @('account_id', 'region', 'identifier', 'type', 'kind', 'snapshot_or_recovery_point', 'created_utc', "created_$(Get-TzCol)",
                'age_days', 'status', 'size_gb', 'rule', 'retention_days', 'expires_utc', 'vault', 'source_status', 'backup_type', 'schedule')))
    foreach ($r in (Sort-JqBy @($D.resources) { $_.account_id; $_.region; $_.id })) {
        foreach ($s in (Sort-JqBy @($r.snapshots | Where-Object { $null -ne $_ }) { -[double](Get-Or $_.created_epoch 0) })) {
            $l.Add((Format-BcrCsvRow @($r.account_id, $r.region, $r.id, $r.type, $s.kind, $s.id, (Format-BcrUtc $s.created_epoch), (Format-BcrLoc $s.created_epoch),
                        $(if ($null -eq $s.created_epoch) { $null } else { [long][Math]::Floor(($now - $s.created_epoch) / 86400) }), $s.status, $s.size_gb,
                        $(if ($s.kind -eq 'backup') { Get-RpClass $s } elseif ($s.kind -eq 'automated') { 'daily' } else { '' }),
                        $(if ($s.kind -eq 'backup') { Get-RpRet $s } else { $null }), (Format-BcrUtc $s.expires_epoch), (Get-Or $s.vault ''), 'EXISTING', (Get-BType $s), (Get-BSched $s))))
        }
    }
    foreach ($o in (Sort-JqBy @($OR) { $_.account_id; $_.region; $_.source_id; -[double](Get-Or $_.created_epoch 0) })) {
        $l.Add((Format-BcrCsvRow @($o.account_id, $o.region, $o.source_id, $o.type, 'manual', $o.id, (Format-BcrUtc $o.created_epoch), (Format-BcrLoc $o.created_epoch),
                    $o.age_days, $o.status, $o.size_gb, '', $null, '', '', $o.source_status, 'manual', 'not_counted')))
    }
    return (Join-Lines $l)
}
# ConvertTo-BcrManualCsv: manual snapshots older than -ManualOlderThan days (current resources and orphan candidates), oldest first
function ConvertTo-BcrManualCsv {
    param($D, $OR)
    $now = $script:Now; $lim = [double](Get-Or $script:Cfg.manual_older_than 0) * 86400
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add((Format-BcrCsvRow @('account_id', 'region', 'identifier', 'type', 'engine', 'snapshot', 'created_utc', "created_$(Get-TzCol)", 'age_days', 'status', 'size_gb', 'source_status')))
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($D.resources)) {
        foreach ($s in @($r.snapshots | Where-Object { $null -ne $_ })) {
            if ($s.kind -eq 'manual' -and $null -ne $s.created_epoch -and ($now - $s.created_epoch) -gt $lim) { $items.Add(@{ r = $r; s = $s; o = 'EXISTING' }) }
        }
    }
    foreach ($o in @($OR)) {
        if ($null -ne $o.created_epoch -and ($now - $o.created_epoch) -gt $lim) {
            $items.Add(@{ r = @{ account_id = $o.account_id; region = $o.region; id = $o.source_id; type = $o.type; engine = $o.engine }; s = $o; o = $o.source_status })
        }
    }
    foreach ($x in (Sort-JqBy $items.ToArray() { $_.s.created_epoch; $_.r.account_id; $_.r.id })) {
        $l.Add((Format-BcrCsvRow @($x.r.account_id, $x.r.region, $x.r.id, $x.r.type, $x.r.engine, $x.s.id, (Format-BcrUtc $x.s.created_epoch), (Format-BcrLoc $x.s.created_epoch),
                    [long][Math]::Floor(($now - $x.s.created_epoch) / 86400), $x.s.status, $x.s.size_gb, $x.o)))
    }
    return (Join-Lines $l)
}
# ConvertTo-BcrOrphanCsv: ORPHANED manual snapshots only (source deleted), oldest first, with the cost estimate
function ConvertTo-BcrOrphanCsv {
    param($OR)
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add((Format-BcrCsvRow @('account_id', 'region', 'snapshot_id', 'type', 'source_id', 'engine', 'engine_version', 'created_utc', "created_$(Get-TzCol)",
                'age_days', 'size_gb', 'est_monthly_usd', 'encrypted', 'kms_key')))
    foreach ($o in @($OR | Where-Object { $_.source_status -eq 'ORPHANED' })) {
        $l.Add((Format-BcrCsvRow @($o.account_id, $o.region, $o.id, $o.type, $o.source_id, $o.engine, $o.engine_version, (Format-BcrUtc $o.created_epoch), (Format-BcrLoc $o.created_epoch),
                    $o.age_days, $o.size_gb, $o.est_monthly_usd, $o.encrypted, $o.kms_key)))
    }
    return (Join-Lines $l)
}

# ---------------------------------------------------------------------------------------------- text helpers
# Get-BcrCell: text cell ("3/4 · missing Sat 24 Oct", "2/2 so far (target 4)", N/A, ? = unknown, "" = off)
function Get-BcrCell {
    param($C)
    if ($C.st -eq 'N/A') { return 'N/A' }; if ($C.st -eq 'UNKNOWN') { return '?' }; if ($C.st -eq 'OFF') { return '' }
    $t = if ((Get-Or $C.target $C.need) -gt $C.need) { "$(J $C.have)/$(J $C.need) so far (target $(J $C.target))" } else { "$(J $C.have)/$(J $C.need)" }
    $m = @($C.missing | Where-Object { $null -ne $_ })
    if ($m.Count) { $t += ' · missing ' + ((@($m | ForEach-Object { if ($C.dfmt -eq 'month') { Format-MLabel $_ } else { Format-DShort $_ } })) -join ', ') }
    return $t
}
function Get-BcrCCell {
    param($C)
    if ($C.st -eq 'N/A') { return [ordered]@{ t = 'N/A'; n = 0; m = '' } }; if ($C.st -eq 'UNKNOWN') { return [ordered]@{ t = '?'; n = 0; m = '' } }
    if ($C.st -eq 'OFF') { return [ordered]@{ t = ''; n = 0; m = '' } }
    $m = @($C.missing | Where-Object { $null -ne $_ })
    return [ordered]@{ t = $(if ((Get-Or $C.target $C.need) -gt $C.need) { "$(J $C.have)/$(J $C.need) so far (target $(J $C.target))" } else { "$(J $C.have)/$(J $C.need)" })
        n = [long]$m.Count; m = ((@($m | ForEach-Object { if ($C.dfmt -eq 'month') { Format-MLabel $_ } else { Format-DShort $_ } })) -join ', ') }
}
# Get-BcrGsum: one short summary of a row's problems (HTML)
function Get-BcrGsum {
    param($R)
    $p = [System.Collections.Generic.List[string]]::new()
    foreach ($k in 'daily', 'weekly', 'monthly', 'yearly') {
        $c = $R[$k]; if ($c.st -ne 'FAIL') { continue }
        $m = @($c.missing | Where-Object { $null -ne $_ })
        if ($m.Count) { $p.Add("$k $($m.Count) missing") } elseif ($k -eq 'daily') { $p.Add(($c.gap -split '; ')[0]) } else { $p.Add("$k $(J $c.have)/$(J $c.need)") }
    }
    if ($R.weekly.st -eq 'UNKNOWN' -or $R.daily.st -eq 'UNKNOWN') { $p.Add('unreadable') }
    if ($R.warnings -ne '') { $p.Add('retention warning') }
    if ((Get-Or $R.retention_mismatch '') -ne '') { $p.Add('retention mismatch') }
    if ((Get-Or $R.excess '') -ne '') { $p.Add('excess backups') }
    if ((Get-Or $R.over_retention '') -ne '') { $p.Add('holds more than retention') }
    if ($R.not_yet_due -ne '') { $p.Add('not yet due') }
    return ($p -join ' · ')
}
function Get-AccountLabel { param($A) if ((Get-Or $A.name '') -ne '') { return "$($A.name) ($($A.account))" } return "$($A.account)" }
function Get-AccountsLabel { param($D) return ((@($D.accounts | ForEach-Object { Get-AccountLabel $_ })) -join ', ') }
function Get-CompText {
    param($T)
    $s = if ($null -eq $T.compliance.pct) { 'Compliance: - (nothing due yet)' } else { "Compliance: $($T.compliance.pct)% ($($T.compliance.compliant) of $($T.compliance.of))" }
    if ($T.not_yet_due -gt 0) { $s += ", $($T.not_yet_due) not yet due not counted" }
    return $s
}
function Get-RuleText {
    $c = $script:Cfg
    $auto = ($c.weekly -eq 'auto' -or $null -eq $c.weekly)
    $s = "daily: each of the last $(J $c.daily) days (RDS automated, last <= $(J $c.daily_max_age_h)h)" +
    " · weekly every $($script:WDNAME[[int](Get-Or $c.weekly_weekday 6)]) " + $(if ($auto) { "in the last $(J (Get-Or $c.weekly_window_days 30)) days" } else { "x$(J $c.weekly)" }) +
    " (retention $(J (Get-Or $c.weekly_retention_days 30))d, counted $(J $c.weekly_min_days)-$(J $c.weekly_max_days)d)" +
    " · monthly first $($script:WDNAME[[int](Get-Or $c.monthly_weekday 0)]) x$(J $c.monthly) (retention $(J (Get-Or $c.monthly_retention_days 365))d, counted $(J (Get-MonthlyMin))-$(J $c.monthly_max_days)d)" +
    $(if (Test-YearlyOn) { " · yearly x$(J $c.yearly)" } else { '' }) +
    " · daily retention $(J (Get-DRet))d · retention ±$(J (Get-RTol))d · schedule ±$(J (Get-Or $c.tolerance_days 1))d, UTC dates · global secondaries: daily only" +
    $(if (@($c.replica_exempt_engines).Count -gt 0) { " · replica-exempt-engines $($c.replica_exempt_engines -join ','): always COMPLIANT" } else { '' })
    return $s
}
function Get-HTip { param([string]$T) return " <span class=`"ti`" tabindex=`"0`" title=`"$(ConvertTo-JqHtml $T)`">&#9432;</span>" }
# ConvertTo-JqHtml: jq @html (escapes < > & ' ")
function ConvertTo-JqHtml { param([AllowNull()][string]$S) return ([string]$S).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace("'", '&#39;').Replace('"', '&quot;') }
function Get-HdrHtml {
    param($Rows)
    $c = $script:Cfg; $auto = ($c.weekly -eq 'auto' -or $null -eq $c.weekly); $now = $script:Now
    $h = "<ul class=`"hdr`" id=`"hdr`">" +
    "<li>Generated $(Format-BcrLoc $now) ($(Format-BcrUtc $now))</li>" +
    "<li id=`"h-daily`">Daily: last $(J $c.daily) days, newest within $(J $c.daily_max_age_h)h, retention $(J (Get-DRet))d</li>" +
    "<li id=`"h-weekly`">Weekly: every $($script:WDNAME[[int](Get-Or $c.weekly_weekday 6)]), " + $(if ($auto) { "last $(J (Get-Or $c.weekly_window_days 30)) days" } else { "last $(J $c.weekly)" }) +
    ", retention $(J (Get-Or $c.weekly_retention_days 30))d" +
    (Get-HTip "Counted when retention is $(J $c.weekly_min_days)-$(J $c.weekly_max_days)d; retention ±$(J (Get-RTol))d; schedule ±$(J (Get-Or $c.tolerance_days 1))d; dates in UTC") + '</li>' +
    "<li id=`"h-monthly`">Monthly: first $($script:WDNAME[[int](Get-Or $c.monthly_weekday 0)]), last $(J $c.monthly) months, retention $(J (Get-Or $c.monthly_retention_days 365))d" +
    (Get-HTip "Counted when retention is $(J (Get-MonthlyMin))-$(J $c.monthly_max_days)d; retention ±$(J (Get-RTol))d; schedule ±$(J (Get-Or $c.tolerance_days 1))d; dates in UTC") + '</li>' +
    $(if (Test-YearlyOn) { "<li id=`"h-yearly`">Yearly: last $(J $c.yearly)</li>" } else { '' }) +
    $(if (@($c.replica_exempt_engines).Count -gt 0) { "<li id=`"h-exempt`">Role=replica/secondary matching $($c.replica_exempt_engines -join ','): always COMPLIANT</li>" } else { '' }) +
    $(if (@($Rows | Where-Object { $_.global_role -eq 'secondary' -or $_.global_role -eq 'replica' }).Count) { "<li id=`"h-global`">Global secondaries: daily only</li>" } else { '' }) +
    '</ul>'
    return $h
}

# ---------------------------------------------------------------------------------------------- the report model
# New-BcrReport: evaluate once (rows, orphans, totals) for every output of the run
function New-BcrReport {
    param($D, $UnmatchedRows)
    $rows = Get-BcrRows $D
    $or = Get-BcrOrphanRows $D
    $ot = Get-BcrOrphanTotals $or
    $t = Get-BcrTotals $rows $UnmatchedRows
    return @{ D = $D; Rows = $rows; OR = $or; OT = $ot; T = $t }
}
function Get-BcrCfgPublic { $x = [ordered]@{}; foreach ($k in $script:Cfg.Keys) { if ($k -ne 'tz_offset') { $x[$k] = $script:Cfg[$k] } }; return $x }

# ConvertTo-BcrText: the text report
function ConvertTo-BcrText {
    param($Rep)
    $D = $Rep.D; $t = $Rep.T; $now = $script:Now
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add("RDS backup compliance - account $(Get-AccountsLabel $D)")
    $l.Add("Generated $(Format-BcrUtc $now) / $(Format-BcrLoc $now)")
    $l.Add("Rule: $(Get-RuleText)")
    $l.Add("Orphaned manual snapshots: $(Get-OsumText $Rep.OT) at `$$(J $script:Cfg.snapshot_price_per_gb)/GB-month - rough upper estimate, snapshot billing is incremental")
    $l.Add((Get-CompText $t))
    $l.Add("Resources $($t.resources): compliant $($t.compliant)$(if ($t.exceptions) { " (incl. $($t.exceptions.applied) exceptions)" }), non-compliant $($t.non_compliant), not yet due $($t.not_yet_due), unknown $($t.unknown)")
    $l.Add('')
    $hdr = @('ACCOUNT', 'REGION', 'IDENTIFIER', 'TYPE', 'ROLE', 'AGE_DAYS', 'DAILY', 'WEEKLY', 'MONTHLY') + $(if (Test-YearlyOn) { @('YEARLY') } else { @() }) + @('STATUS', 'GAPS', 'WARNINGS')
    $l.Add(($hdr -join "`t"))
    foreach ($r in $Rep.Rows) {
        $acc = if ((Get-Or $r.account_name '') -ne '') { "$($r.account_name) ($($r.account_id))" } else { $r.account_id }
        $c = @($acc, $r.region, $r.identifier, $r.type, $r.global_role, (J (Get-Or $r.age_days '')), (Get-BcrCell $r.daily), (Get-BcrCell $r.weekly), (Get-BcrCell $r.monthly))
        if (Test-YearlyOn) { $c += (Get-BcrCell $r.yearly) }
        $g = (@($r.gaps, $r.not_yet_due) | Where-Object { $_ -ne '' }) -join '; '
        $w = (@($r.warnings,
                $(if ((Get-Or $r.retention_mismatch '') -ne '') { "retention mismatch: $($r.retention_mismatch)" } else { '' }),
                $(if ((Get-Or $r.excess '') -ne '') { "excess backups: $($r.excess)" } else { '' }),
                $(if ((Get-Or $r.over_retention '') -ne '') { "holds more than retention: $($r.over_retention)" } else { '' })) | Where-Object { $_ -ne '' }) -join '; '
        $c += @((Get-ExcLabel $r), $g, $w)
        $l.Add(($c -join "`t"))
    }
    if ($t.exceptions) {
        $e = $t.exceptions
        $l.Add('')
        $l.Add("Exceptions: $($e.applied) applied (counted as compliant)" + $(if ($e.attention -gt 0) { "; expiring soon or no longer needed: $($e.attention)" } else { '' }) + $(if ($e.expired -gt 0) { "; expired: $($e.expired)" } else { '' }))
        foreach ($r in $Rep.Rows) {
            if ($r.exception -eq 'no') { continue }
            $l.Add("  $($r.account_id) $($r.identifier) until $($r.exception_expires), actual $($r.actual_status)" +
                $(if ($r.exception -eq 'expired') { ', EXPIRED (evaluated normally)' } elseif ($r.exception_flag -ne '') { " [$($r.exception_flag)]" } else { '' }) + ": $($r.exception_reason)")
        }
        foreach ($u in $e.unmatched) { $l.Add("  line $($u.line): $($u.account) $($u.identifier) matched no server") }
    }
    $er = @($D.regions | Where-Object { $_.status -eq 'error' })
    if ($er.Count) { $l.Add(''); $l.Add('Region errors:'); foreach ($x in $er) { $l.Add("  $($x.account) $($x.region): $(@($x.errors) -join '; ')") } }
    return (Join-Lines $l)
}
# Get-BcrOsum: orphan totals plus their one-line summary under key \$Key
function Get-BcrOsum { param($OT, [string]$Key) $x = [ordered]@{}; foreach ($k in $OT.Keys) { $x[$k] = $OT[$k] }; $x[$Key] = (Get-OsumText $OT); return $x }
function Get-BcrPublicRegions { param($D) return , @(foreach ($r in @($D.regions)) { if ($r.status -ne 'empty') { Copy-Without $r @('existing') } }) }

# ConvertTo-BcrJsonReport: -Format json
function ConvertTo-BcrJsonReport {
    param($Rep)
    $D = $Rep.D; $now = $script:Now
    $o = [ordered]@{ tool = 'Invoke-RdsBackupCompliance'; version = $script:ScriptVersion; generated_utc = (Format-BcrUtc $now); generated_local = (Format-BcrLoc $now)
        accounts = @($D.accounts); thresholds = (Get-BcrCfgPublic); totals = $Rep.T; regions = (Get-BcrPublicRegions $D); rows = @($Rep.Rows)
        orphan_totals = (Get-BcrOsum $Rep.OT 'summary')
        orphaned_snapshots = @(foreach ($r in $Rep.OR) { $x = [ordered]@{}; foreach ($k in $r.Keys) { $x[$k] = $r[$k] }; $x['created_utc'] = Format-BcrUtc $r.created_epoch; $x['created_local'] = Format-BcrLoc $r.created_epoch; $x }) }
    return (ConvertTo-BcrJson $o) + "`n"
}

# ConvertTo-BcrHtml: the HTML page: the data as JSON in <script type="application/json"> (</ escaped) + assets/backup_page.js,
# which builds every table with textContent (never innerHTML of data), so data cannot inject markup or script.
function ConvertTo-BcrHtml {
    param($Rep)
    $D = $Rep.D; $now = $script:Now
    $payload = [ordered]@{ generated_utc = (Format-BcrUtc $now); generated_local = (Format-BcrLoc $now); tz_label = $script:Cfg.tz_label; tz_offset = $script:Cfg.tz_offset; now = $now
        cfg = (Get-BcrCfgPublic); version = $script:ScriptVersion; accounts = @($D.accounts); regions = (Get-BcrPublicRegions $D)
        orph = @(foreach ($o in $Rep.OR) { [ordered]@{ a = $o.account_id; r = $o.region; t = $o.type; id = $o.id; sid = $o.source_id; kind = $o.kind; eng = $o.engine; ev = $o.engine_version
                    c = $o.created_epoch; st = $o.status; gb = $o.size_gb; usd = $o.est_monthly_usd; enc = $o.encrypted; kms = (Get-Or $o.kms_key ''); src = $o.source_status
                    sr = (Get-Or $o.source_region ''); sa = (Get-Or $o.source_account '') } })
        osum = (Get-BcrOsum $Rep.OT 'text')
        csvh = (Get-BcrCsvHeader)
        rows = @(foreach ($r in $Rep.Rows) {
                $x = [ordered]@{}; foreach ($k in $r.Keys) { $x[$k] = $r[$k] }
                $x['cells'] = [ordered]@{ daily = (Get-BcrCell $r.daily); weekly = (Get-BcrCell $r.weekly); monthly = (Get-BcrCell $r.monthly); yearly = (Get-BcrCell $r.yearly) }
                $x['cc'] = [ordered]@{ daily = (Get-BcrCCell $r.daily); weekly = (Get-BcrCCell $r.weekly); monthly = (Get-BcrCCell $r.monthly); yearly = (Get-BcrCCell $r.yearly) }
                $x['gsum'] = Get-BcrGsum $r; $x['csv'] = (ConvertTo-BcrCstr (Get-BcrCsvValues $r)); $x })
        snaps = @(foreach ($r in @($D.resources)) {
                $rr = $r.retention
                [ordered]@{ k = "$($r.account_id)|$($r.region)|$($r.id)"
                    s = @(foreach ($s in @($r.snapshots | Where-Object { $null -ne $_ })) {
                            $fl = if ($s.kind -eq 'backup' -and (Test-RpLive $s)) { Get-RmisNote (Get-RpClass $s) (Get-RpRet $s) }
                            elseif ($s.kind -eq 'automated' -and $null -ne $s.created_epoch -and $s.created_epoch -lt (Get-OverCut $rr)) { "older than the $(J (Get-Or $rr 0))d retention" } else { $null }
                            [ordered]@{ fl = $fl; kind = $s.kind; id = $s.id; c = $s.created_epoch; st = $s.status; gb = $s.size_gb; x = $s.expires_epoch; v = (Get-Or $s.vault '')
                                cl = $(if ($s.kind -eq 'backup') { Get-RpClass $s } else { '' }); rd = $(if ($s.kind -eq 'backup') { Get-RpRet $s } else { $null })
                                pl = (Get-Or $s.plan ''); ru = (Get-Or $s.rule ''); bt = (Get-BType $s); sc = (Get-BSched $s) } }) } }) }
    if ($null -ne $script:Exc) { $payload['exc'] = $Rep.T.exceptions }
    $json = (ConvertTo-BcrJson $payload -Compress).Replace('</', '<\/')
    $label = Get-AccountsLabel $D
    $na = @(Get-JqUnique @($D.accounts | ForEach-Object { $_.account })).Count
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<!DOCTYPE html>`n<html lang=`"en`"><head><meta charset=`"utf-8`"><title>RDS backup compliance - $(ConvertTo-JqHtml $label)</title>`n<style>`n")
    [void]$sb.Append($script:Assets.Css)
    [void]$sb.Append("</style></head><body>`n<h1 title=`"$(ConvertTo-JqHtml $label)`">RDS backup compliance · $na account$(if ($na -ne 1) { 's' })</h1>`n")
    [void]$sb.Append((Get-HdrHtml $Rep.Rows)); [void]$sb.Append("`n")
    [void]$sb.Append("<div class=`"tabs`"><button data-t=`"comp`" class=`"on`">Compliance</button><button data-t=`"bk`">Backups</button></div>`n")
    [void]$sb.Append("<div id=`"comp`" class=`"tab on`"></div><div id=`"bk`" class=`"tab`"></div>`n")
    [void]$sb.Append("<script id=`"data`" type=`"application/json`">$json</script>`n<script>")
    [void]$sb.Append($script:Assets.PageJs)
    [void]$sb.Append("</script></body></html>`n")
    return $sb.ToString()
}

# Get-BcrExcLog: log lines about the exceptions (W = warning, I = info)
function Get-BcrExcLog {
    param($Rep)
    if ($null -eq $script:Exc) { return @() }
    $e = $Rep.T.exceptions; $f = [System.IO.Path]::GetFileName($script:ExcPath)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $e.unmatched) { $out.Add(@('W', "Exception ${f}:$($u.line) ($($u.account) $($u.identifier)) matched no server in this report")) }
    foreach ($r in $Rep.Rows) { if ($r.exception -eq 'expired') { $out.Add(@('W', "Exception for $($r.account_id) $($r.identifier) expired on $($r.exception_expires): evaluated normally ($($r.status))")) } }
    $out.Add(@('I', "Exceptions (backup): $($e.applied) applied (counted as COMPLIANT), $($e.attention) expiring soon or no longer needed, $($e.expired) expired, $(@($e.unmatched).Count) unmatched"))
    return , $out.ToArray()
}
