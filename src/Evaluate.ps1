# src/Evaluate.ps1 - the compliance rules (Bash lib/backup.jq "evaluate", rows, totals, exceptions, orphan snapshots).
# Pure functions of (resource, $script:Now, $script:Cfg): saved data is evaluated again with today's rules at merge time.
#   daily   RDS automated backups: retention >= daily, one backup on each of the last <daily> UTC days, newest <= daily_max_age_h
#   weekly  AWS Backup point (retention in the weekly range) for each scheduled weekday (+/- tolerance days)
#   monthly AWS Backup point (retention in the monthly range) for the first <weekday> of each of the last <monthly> months
#   yearly  off unless yearly > 0: points with retention above the monthly range, one per calendar year
# Status: any FAIL -> NON-COMPLIANT, else any UNKNOWN -> UNKNOWN, else any DUE (resource too young) -> NOT YET DUE, else COMPLIANT.

# ---------------------------------------------------------------------------------------------- recovery point class
# Get-RpRet: retention of a recovery point in whole days (expiry - creation), else the saved ret_days, else $null (never expires)
function Get-RpRet {
    param($P)
    if ($null -ne $P.expires_epoch -and $null -ne $P.created_epoch) { return (N (Round-Jq (([double]$P.expires_epoch - [double]$P.created_epoch) / 86400))) }
    return (Get-Or $P.ret_days $null)
}
# Test-RpLive: COMPLETED / AVAILABLE and not a continuous (PITR) backup
function Test-RpLive { param($P) return (($P.status -eq 'COMPLETED' -or $P.status -eq 'AVAILABLE') -and -not ($P.continuous -eq $true)) }
# Get-RpClass: weekly / monthly / yearly / mismatch from the retention alone
function Get-RpClass {
    param($P)
    $c = $script:Cfg; $d = Get-RpRet $P
    if ($null -ne $d -and $d -ge $c.weekly_min_days -and $d -le $c.weekly_max_days) { return 'weekly' }
    if ($null -ne $d -and $d -ge (Get-MonthlyMin) -and $d -le $c.monthly_max_days) { return 'monthly' }
    if ($c.yearly -gt 0 -and ($null -eq $d -or $d -gt $c.monthly_max_days)) { return 'yearly' }
    return 'mismatch'
}
function Get-MonthlyMin { $c = $script:Cfg; if ($null -ne $c.monthly_min_days) { return $c.monthly_min_days } return $c.weekly_max_days + 1 }
# Get-BType / Get-BSched: backup type and the schedule a snapshot / point counts for (Backups tab, CSV)
function Get-BType { param($P) if ($P.kind -eq 'backup') { if ($P.continuous) { return 'pitr' } else { return 'aws_backup' } } return $P.kind }
function Get-BSched {
    param($P)
    if ($P.kind -eq 'automated') { return 'daily' }
    if ($P.kind -eq 'backup' -and (Test-RpLive $P)) { $c = Get-RpClass $P; if ($c -eq 'mismatch') { return 'not_counted' } return $c }
    return 'not_counted'
}
# strict retention (highlight only, never a failure)
function Get-RTol { return (Get-Or $script:Cfg.ret_tolerance_days 1) }
function Get-ExpRet { param([string]$Cl) if ($Cl -eq 'weekly') { return (Get-Or $script:Cfg.weekly_retention_days 30) } elseif ($Cl -eq 'monthly') { return (Get-Or $script:Cfg.monthly_retention_days 365) } return $null }
function Get-RmisNote {
    param([string]$Cl, $Ret)
    $e = Get-ExpRet $Cl
    if ($null -ne $e -and $null -ne $Ret -and [Math]::Abs([double]$Ret - $e) -gt (Get-RTol)) { return "$Cl point has $(J $Ret)d, expected $(J $e)d" }
    return $null
}
function Get-DRet { return (Get-Or $script:Cfg.daily_retention_days $script:Cfg.daily) }
function Get-OverCut { param($Ret) return $script:Now - (([double](Get-Or $Ret 0) + (Get-RTol)) * 86400) }

# replica-exempt-engines: Role=replica / secondary whose engine matches a glob (only * is special) -> every schedule N/A
function Test-EngExempt {
    param($Engine)
    $e = ([string](Get-Or $Engine '')).ToLowerInvariant()
    foreach ($g in @($script:Cfg.replica_exempt_engines)) {
        if (-not $g) { continue }
        $re = '^' + ([regex]::Escape($g.ToLowerInvariant()) -replace '\\\*', '.*') + '$'
        if ($e -match $re) { return $true }
    }
    return $false
}
function Test-RoleExempt { param($R) return (($R.global_role -eq 'secondary' -or $R.global_role -eq 'replica') -and (Test-EngExempt $R.engine)) }

# ---------------------------------------------------------------------------------------------- schedule check
# Get-Sched: $Cand = candidate scheduled day numbers (newest first), $Pts = point epochs, $Tol = days either side,
# $Count = days expected ($null = every candidate after $Low), days on or before $CDay (creation day) never expected.
# A day whose tolerance window is still open and has no point is not expected yet.
# -> @{ have; need; target; _days; missing } (need < target: resource too young for the full schedule)
function Get-Sched {
    param([long[]]$Cand, [object[]]$Pts, [long]$Tol, $Count, $Low, [long]$CDay)
    $now = $script:Now
    $pl = [System.Collections.Generic.List[double]]::new(); foreach ($p in $Pts) { if ($null -ne $p) { $pl.Add([double]$p) } }
    $c = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Cand) {
        $lo = ($d - $Tol) * 86400; $hi = ($d + 1 + $Tol) * 86400
        $hit = $false; foreach ($p in $pl) { if ($p -ge $lo -and $p -lt $hi) { $hit = $true; break } }
        $closed = ($hi -le $now)
        if ($hit -or $closed) { $c.Add(@{ d = $d; hit = $hit }) }
    }
    $full = if ($null -eq $Count) { @($c | Where-Object { $_.d -gt $Low }) } else { @($c | Select-Object -First ([Math]::Max(0, [long]$Count))) }
    $exp = @($full | Where-Object { $_.d -gt $CDay })
    $miss = @($exp | Where-Object { -not $_.hit } | ForEach-Object { $_.d }); [array]::Reverse($miss)
    return [ordered]@{ have = [long]@($exp | Where-Object { $_.hit }).Count; need = [long]$exp.Count; target = [long]$full.Count
        _days = [long[]]@($exp | ForEach-Object { $_.d }); missing = [long[]]$miss }
}
# Get-Stx: FAIL (a point missing), DUE (fewer days expected than the target), else OK
function Get-Stx { param($S) if ($S.have -lt $S.need) { return 'FAIL' } if ($S.need -lt $S.target) { return 'DUE' } return 'OK' }
function Add-Fin { param($S) if ($null -ne $S.full_d) { $S['full_on'] = Format-DLong $S.full_d; $S['full_on_iso'] = Format-Dwk $S.full_d }; return $S }
function Copy-Without { param($S, [string[]]$Drop) $o = [ordered]@{}; foreach ($k in $S.Keys) { if ($Drop -notcontains $k) { $o[$k] = $S[$k] } }; return $o }

# ---------------------------------------------------------------------------------------------- evaluate one resource
# Invoke-BcrEvaluate: one resource of the data document -> one report row
function Invoke-BcrEvaluate {
    param($R)
    $cfg = $script:Cfg; $now = $script:Now
    $today = Get-Day $now
    $cday = if ($null -eq $R.created_epoch) { [long]-1 } else { Get-Day $R.created_epoch }
    $age = ($now - [double](Get-Or $R.created_epoch $now)) / 86400
    $tol = [long](Get-Or $cfg.tolerance_days 1)
    $snapsAll = @($R.snapshots | Where-Object { $null -ne $_ })
    $auto = @($snapsAll | Where-Object { $_.kind -eq 'automated' -and (Get-Or $_.status 'available') -eq 'available' })
    $autoC = @($auto | ForEach-Object { $_.created_epoch } | Where-Object { $null -ne $_ })
    $lastAuto = if ($autoC.Count) { ($autoC | Measure-Object -Maximum).Maximum } else { $null }
    $rps = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $snapsAll) {
        if ($s.kind -eq 'backup' -and (Test-RpLive $s) -and ($null -eq $s.expires_epoch -or $s.expires_epoch -gt $now)) {
            $x = [ordered]@{}; foreach ($k in $s.Keys) { $x[$k] = $s[$k] }; $x['class'] = Get-RpClass $s; $x['ret'] = Get-RpRet $s; $rps.Add($x)
        }
    }
    $retention = Get-Or $R.retention 0
    # daily
    if (Test-RoleExempt $R) { $daily = [ordered]@{ st = 'N/A'; have = $null; need = $null; gap = ''; missing = @() } }
    elseif ($R.snap_ok -eq $false) { $daily = [ordered]@{ st = 'UNKNOWN'; have = $null; need = $cfg.daily; gap = 'snapshots unreadable'; missing = @() } }
    else {
        $s = Get-Sched ([long[]]@(for ($k = 0; $k -lt $cfg.daily + 2; $k++) { $today - $k })) $autoC 0 $cfg.daily $null $cday
        $h = if ($null -eq $lastAuto) { $null } else { R1 (($now - $lastAuto) / 3600) }
        $g = [System.Collections.Generic.List[string]]::new()
        if ($retention -lt $cfg.daily) { $g.Add("daily: retention $(J $retention)d < $(J $cfg.daily)d") }
        if ($null -eq $h) { if ($age * 24 -gt $cfg.daily_max_age_h) { $g.Add('daily: no automated backup') } }
        elseif ($h -gt $cfg.daily_max_age_h) { $g.Add("daily: last automated $(J $h)h ago") }
        if ((Get-Stx $s) -eq 'FAIL') { $g.Add("daily $($s.have)/$($s.need) missing $((@($s.missing | ForEach-Object { Format-DShort $_ })) -join ', ')") }
        $s['last_h'] = $h; $s['gap'] = ($g -join '; ')
        $s['full_d'] = if ($s.need -lt $s.target) { $cday + $s.target } else { $null }
        $s['st'] = if ($g.Count) { 'FAIL' } elseif ((Get-Stx $s) -eq 'DUE' -or $null -eq $h) { 'DUE' } else { 'OK' }
        $daily = $s
    }
    # weekly / monthly / yearly
    $wd = [int](Get-Or $cfg.weekly_weekday 6); $md = [int](Get-Or $cfg.monthly_weekday 0)
    $wn = if ($cfg.weekly -eq 'auto' -or $null -eq $cfg.weekly) { $null } else { [long]$cfg.weekly }
    $lastw = $today - (((Get-Dow $today) - $wd + 7) % 7)
    $nowD = [DateTimeOffset]::FromUnixTimeSeconds($now).UtcDateTime; $mi = [long]($nowD.Year * 12 + $nowD.Month - 1)
    $win = [long]$cfg.weekly_window_days
    if ($R.global_role -eq 'secondary' -or $R.global_role -eq 'replica') {
        $wmy = [ordered]@{ weekly = [ordered]@{ st = 'N/A' }; monthly = [ordered]@{ st = 'N/A' }; yearly = [ordered]@{ st = 'N/A' } }
    }
    elseif ($R.backup_ok -eq $false) {
        $wmy = [ordered]@{ weekly = [ordered]@{ st = 'UNKNOWN' }; monthly = [ordered]@{ st = 'UNKNOWN' }; yearly = [ordered]@{ st = 'UNKNOWN' } }
    }
    else {
        $wp = @($rps | Where-Object { $_.class -eq 'weekly' } | ForEach-Object { $_.created_epoch })
        $mp = @($rps | Where-Object { $_.class -eq 'monthly' } | ForEach-Object { $_.created_epoch })
        $wcount = if ($null -ne $wn) { $wn } else { [long][Math]::Floor($win / 7) }
        $w = Get-Sched ([long[]]@(for ($k = 0; $k -lt $wcount + 3; $k++) { $lastw - 7 * $k })) $wp $tol $wn ($today - $win) $cday
        $m = Get-Sched ([long[]]@(for ($k = 0; $k -lt $cfg.monthly + 2; $k++) { Get-FirstDow ($mi - $k) $md })) $mp $tol $cfg.monthly $null $cday
        $w['st'] = Get-Stx $w; $w['dfmt'] = 'week'
        $w['full_d'] = if ($w.need -lt $w.target) { if ($null -eq $wn) { $cday + $win } else { $f = $cday + 1; $f + (($wd - (Get-Dow $f) + 7) % 7) + 7 * ($wn - 1) } } else { $null }
        $m['st'] = Get-Stx $m; $m['dfmt'] = 'month'
        $m['full_d'] = if ($m.need -lt $m.target) {
            $cmi = Get-MonthIndex $cday
            Get-At @(for ($k = 0; $k -lt $cfg.monthly + 14; $k++) { $x = Get-FirstDow ($cmi + $k) $md; if ($x -gt $cday) { $x } }) ($cfg.monthly - 1)
        } else { $null }
        if ($cfg.yearly -gt 0) {
            $yy = @(Get-JqUnique @($rps | Where-Object { $_.class -eq 'yearly' -and $null -ne $_.created_epoch } | ForEach-Object { Get-Year $_.created_epoch })).Count
            $y = [ordered]@{ have = [long]$yy; need = $cfg.yearly; target = $cfg.yearly; missing = @()
                st = $(if ($yy -ge $cfg.yearly) { 'OK' } elseif ($age -lt $cfg.yearly * 365.25) { 'DUE' } else { 'FAIL' }) }
        }
        else { $y = [ordered]@{ st = 'OFF' } }
        $wmy = [ordered]@{ weekly = $w; monthly = $m; yearly = $y }
    }
    $daily = Add-Fin $daily
    foreach ($k in @($wmy.Keys)) { $wmy[$k] = Add-Fin $wmy[$k] }
    $mtxt = { param($k, $c) if ($k -eq 'monthly') { (@($c.missing | ForEach-Object { Format-MLabel $_ })) -join ', ' } else { (@($c.missing | ForEach-Object { Format-DShort $_ })) -join ', ' } }
    $gl = [System.Collections.Generic.List[string]]::new()
    if ($daily.st -eq 'FAIL') { $gl.Add($daily.gap) }
    if ($daily.st -eq 'UNKNOWN') { $gl.Add('daily: snapshots unreadable') }
    foreach ($k in $wmy.Keys) {
        $v = $wmy[$k]
        if ($v.st -eq 'FAIL') { $gl.Add("$k $(J $v.have)/$(J $v.need)" + $(if (@($v.missing).Count) { ' missing ' + (& $mtxt $k $v) } else { '' })) }
    }
    if ($wmy.weekly.st -eq 'UNKNOWN') { $gl.Add('AWS Backup recovery points unreadable') }
    $gaps = $gl -join '; '
    $mis = @($rps | Where-Object { $_.class -eq 'mismatch' })
    $sts = @($daily.st) + @($wmy.Values | ForEach-Object { $_.st } | Where-Object { $_ -ne 'OFF' })
    # per recovery point: why it was / was not counted
    $mmin = Get-MonthlyMin
    $wtxt = "the weekly range $(J $cfg.weekly_min_days)-$(J $cfg.weekly_max_days)d (expected $(J (Get-ExpRet 'weekly'))d)"
    $mtxt2 = "the monthly range $(J $mmin)-$(J $cfg.monthly_max_days)d (expected $(J (Get-ExpRet 'monthly'))d)"
    $hitday = { param($p, $k)
        foreach ($d in @($wmy[$k]._days | Where-Object { $null -ne $_ })) { if ($null -ne $d -and $null -ne $p -and $p -ge ($d - $tol) * 86400 -and $p -lt ($d + 1 + $tol) * 86400) { return $d } }
        return $null }
    $diag = [System.Collections.Generic.List[object]]::new()
    $bk = @(Sort-JqBy @($snapsAll | Where-Object { $_.kind -eq 'backup' }) { -[double](Get-Or $_.created_epoch 0) })
    foreach ($p in $bk) {
        $ret = Get-RpRet $p; $cl = Get-RpClass $p
        $why = $null
        if ($p.continuous) { $why = [ordered]@{ counted = $false; reason = 'continuous backup (point-in-time restore), not a snapshot: never counted' } }
        elseif (-not ($p.status -eq 'COMPLETED' -or $p.status -eq 'AVAILABLE')) { $why = [ordered]@{ counted = $false; reason = "status $(J (Get-Or $p.status 'unknown')): only COMPLETED / AVAILABLE count" } }
        elseif ($null -ne $p.expires_epoch -and $p.expires_epoch -le $now) { $why = [ordered]@{ counted = $false; reason = 'expired' } }
        elseif (Test-RoleExempt $R) { $why = [ordered]@{ counted = $false; reason = 'not evaluated: replica/secondary exempt (replica-exempt-engines)' } }
        elseif ($wmy.weekly.st -eq 'N/A') { $why = [ordered]@{ counted = $false; reason = 'not evaluated: global secondary / replica (daily only)' } }
        elseif ($wmy.weekly.st -eq 'UNKNOWN') { $why = [ordered]@{ counted = $false; reason = 'not evaluated: recovery points unreadable' } }
        elseif ($cl -eq 'mismatch') {
            $t = if ($null -eq $ret) { 'no expiry (never expires): not weekly or monthly' + $(if ($cfg.yearly -gt 0) { '' } else { '; yearly check is off' }) } else { "retention $(J $ret)d is outside $wtxt and $mtxt2" }
            $why = [ordered]@{ counted = $false; reason = $t }
        }
        elseif ($cl -eq 'yearly') { $why = [ordered]@{ counted = $true; reason = "yearly ($(Get-Year $p.created_epoch)), retention $(if ($null -eq $ret) { 'never expires' } else { "$(J $ret)d" })" } }
        else {
            $h = & $hitday $p.created_epoch $cl
            $rn = Get-RmisNote $cl $ret
            if ($null -ne $h) {
                $on = if ($cl -eq 'monthly') { (Format-DShort $h) + " (first $($script:WDNAME[$md]))" } else { Format-DShort $h }
                $why = [ordered]@{ counted = $true; ret_mismatch = ($null -ne $rn); reason = "${cl}: counts for $on, " + $(if ($null -ne $rn) { "but $rn" } else { "retention $(J $ret)d as expected" }) }
            }
            else {
                $days = @($wmy[$cl]._days | Where-Object { $null -ne $_ })
                $t = "retention $(J $ret)d = $cl, but $(Format-DShort (Get-Day $p.created_epoch)) is not within ±$(J $tol)d of a checked $(if ($cl -eq 'weekly') { $script:WDNAME[$wd] } else { 'first ' + $script:WDNAME[$md] })" +
                $(if ($days.Count) { ' (' + ((@($days | ForEach-Object { Format-DShort $_ })) -join ', ') + ')' } else { '' })
                $why = [ordered]@{ counted = $false; reason = $t }
            }
        }
        $e = [ordered]@{ id = $p.id; c = $p.created_epoch; date = $(if ($null -eq $p.created_epoch) { '' } else { Format-Dwk (Get-Day $p.created_epoch) }); ret = $ret; class = $cl
            status = (Get-Or $p.status ''); vault = (Get-Or $p.vault '') }
        foreach ($k in $why.Keys) { $e[$k] = $why[$k] }
        $diag.Add($e)
    }
    # retention mismatch (counted, highlighted), excess backups and over-retention (warnings, never a failure)
    $dret = Get-DRet
    $dailyRm = ($retention -gt $dret -and $R.snap_ok -ne $false)
    $rmList = [System.Collections.Generic.List[object]]::new()
    if ($dailyRm) { $rmList.Add("daily retention $(J $R.retention)d, expected $(J $dret)d") }
    foreach ($d in $diag) { if ($d.ret_mismatch -eq $true) { $rmList.Add((Get-RmisNote $d.class $d.ret)) } }
    $rmt = [System.Collections.Generic.List[string]]::new()
    $sorted = @(Sort-JqBy $rmList.ToArray() { , $_ })
    $ix = 0
    while ($ix -lt $sorted.Count) { $jx = $ix; while ($jx + 1 -lt $sorted.Count -and $sorted[$jx + 1] -ceq $sorted[$ix]) { $jx++ }; $cnt = $jx - $ix + 1; $rmt.Add($(if ($cnt -gt 1) { "$($sorted[$ix]) (x$cnt)" } else { $sorted[$ix] })); $ix = $jx + 1 }
    $rmn = [long](@($diag | Where-Object { $_.ret_mismatch -eq $true }).Count + $(if ($dailyRm) { 1 } else { 0 }))
    $exd = if ($R.snap_ok -eq $false) { $null } else { [ordered]@{ n = [long]@($auto | Where-Object { $null -ne $_.created_epoch -and $_.created_epoch -ge $now - $cfg.daily * 86400 }).Count; max = $cfg.daily + 1; exp = "$(J $cfg.daily)" } }
    $exw = $null
    if (-not ($wmy.weekly.st -eq 'N/A' -or $wmy.weekly.st -eq 'UNKNOWN')) {
        $wpts = @($rps | Where-Object { $_.class -eq 'weekly' -and $null -ne $_.created_epoch })
        $lh = if ($null -eq $wn) { @([long][Math]::Floor($win / 7), [long][Math]::Ceiling($win / 7)) } else { @($wn, $wn) }
        $nn = if ($null -eq $wn) { @($wpts | Where-Object { $_.created_epoch -ge ($today - $win - $tol) * 86400 }).Count } else { @($wpts | Where-Object { $_.created_epoch -ge ($lastw - 7 * ($wn - 1) - $tol) * 86400 }).Count }
        $exw = [ordered]@{ n = [long]$nn; max = $lh[1]; exp = $(if ($lh[0] -eq $lh[1]) { "$($lh[0])" } else { "$($lh[0])-$($lh[1])" }) }
    }
    $exm = $null
    if (-not ($wmy.monthly.st -eq 'N/A' -or $wmy.monthly.st -eq 'UNKNOWN')) {
        $old = Get-At @(for ($k = 0; $k -lt $cfg.monthly + 2; $k++) { $x = Get-FirstDow ($mi - $k) $md; if ($x -le $today) { $x } }) ($cfg.monthly - 1)
        $exm = [ordered]@{ n = [long]@($rps | Where-Object { $_.class -eq 'monthly' -and $null -ne $_.created_epoch -and $_.created_epoch -ge ([double](Get-Or $old 0) - $tol) * 86400 }).Count; max = $cfg.monthly; exp = "$(J $cfg.monthly)" }
    }
    $ex = [ordered]@{ daily = $exd; weekly = $exw; monthly = $exm }
    $ext = (@(foreach ($k in $ex.Keys) { $v = $ex[$k]; if ($null -ne $v -and $v.n -gt $v.max) { "$k $($v.n) (expected $($v.exp))" } })) -join '; '
    $oldA = @(Sort-JqBy @($auto | Where-Object { $null -ne $_.created_epoch -and $_.created_epoch -lt (Get-OverCut $R.retention) }) { $_.created_epoch })
    $ort = if ($oldA.Count -eq 0 -and $auto.Count -le $retention + 1 + (Get-RTol)) { '' } else {
        "holds $($auto.Count) automated backup$(if ($auto.Count -ne 1) { 's' }) for $(J $retention)d retention" +
        $(if ($oldA.Count) { "; $($oldA.Count) older than $(J $retention)d, oldest $(J $oldA[0].id) ($([long][Math]::Floor(($now - $oldA[0].created_epoch) / 86400))d)" } else { '' }) }
    $rset = { param($k) (@(Get-JqUnique @($rps | Where-Object { $_.class -eq $k } | ForEach-Object { , $_.ret })) | ForEach-Object { "$(J $_)d" }) -join ', ' }
    $status = if ($sts -contains 'FAIL') { 'NON-COMPLIANT' } elseif ($sts -contains 'UNKNOWN') { 'UNKNOWN' } elseif ($sts -contains 'DUE') { 'NOT YET DUE' } else { 'COMPLIANT' }
    $nyd = @(if ($null -ne $daily.full_on) { "daily full on $($daily.full_on)" }; foreach ($k in $wmy.Keys) { if ($null -ne $wmy[$k].full_on) { "$k full on $($wmy[$k].full_on)" } })
    $warn = if ($mis.Count -eq 0) { '' } else {
        "retention doesn't match: $($mis.Count) recovery point$(if ($mis.Count -ne 1) { 's' }) (" + ((Get-JqUnique @($mis | ForEach-Object { if ($null -eq $_.ret) { 'never expires' } else { "$(J $_.ret)d" } })) -join ', ') + ') not counted' }
    $plans = (Get-JqUnique @($rps | Where-Object { $null -ne $_.plan -or $null -ne $_.rule } | ForEach-Object { "$(Get-Or $_.plan '?') / $(Get-Or $_.rule '?')" })) -join ', '
    $scheds = (Get-JqUnique @($rps | Where-Object { $null -ne $_.cron } | ForEach-Object { $_.cron + $(if ($_.rtz) { " ($($_.rtz))" } else { '' }) })) -join ', '
    $pitrC = @($snapsAll | Where-Object { $_.kind -eq 'backup' -and $_.continuous -eq $true -and $null -ne $_.created_epoch } | ForEach-Object { $_.created_epoch })
    $drop = @('_days', 'full_d')
    return [ordered]@{
        account_id = $R.account_id; region = $R.region; identifier = $R.id; type = $R.type; engine = $R.engine
        engine_version = $R.engine_version; global_cluster = (Get-Or $R.global_cluster ''); global_role = (Get-Or $R.global_role 'none')
        created = (Format-BcrUtc $R.created_epoch); created_epoch = $R.created_epoch
        age_days = $(if ($null -eq $R.created_epoch) { $null } else { [long][Math]::Floor($age) })
        retention_days = $R.retention; last_automated_utc = (Format-BcrUtc $lastAuto); last_automated_local = (Format-BcrLoc $lastAuto)
        daily = (Copy-Without $daily $drop); weekly = (Copy-Without $wmy.weekly $drop); monthly = (Copy-Without $wmy.monthly $drop); yearly = (Copy-Without $wmy.yearly $drop)
        status = $status; gaps = $gaps; not_yet_due = ($nyd -join '; '); warnings = $warn
        settings = [ordered]@{ backup_window = (Get-Or $R.backup_window ''); copy_tags = $(if ($null -eq $R.copy_tags) { '' } else { $R.copy_tags })
            weekly_retention = (& $rset 'weekly'); monthly_retention = (& $rset 'monthly'); yearly_retention = (& $rset 'yearly'); plans = $plans; schedules = $scheds }
        manual = [long]@($snapsAll | Where-Object { $_.kind -eq 'manual' }).Count; automated = [long]$auto.Count; backup_points = [long]$rps.Count
        retention_mismatch = ($rmt -join '; '); retention_mismatch_count = $rmn
        excess = $ext; excess_counts = [ordered]@{ daily = $(if ($null -eq $exd) { $null } elseif ($exd.n -gt $exd.max) { $exd.n - $exd.max } else { 0 })
            weekly = $(if ($null -eq $exw) { $null } elseif ($exw.n -gt $exw.max) { $exw.n - $exw.max } else { 0 })
            monthly = $(if ($null -eq $exm) { $null } elseif ($exm.n -gt $exm.max) { $exm.n - $exm.max } else { 0 }) }
        over_retention = $ort; over_retention_count = [long]$oldA.Count
        pitr = $(if ($pitrC.Count) { [ordered]@{ on = $true; since = (Format-BcrUtc (($pitrC | Measure-Object -Minimum).Minimum)) } } else { [ordered]@{ on = $false; since = '' } })
        recovery_points = @(foreach ($d in $diag) { $x = Copy-Without $d @('ret_mismatch'); if ($d.ret_mismatch -eq $true) { $x['retention_mismatch'] = Get-RmisNote $d.class $d.ret }; $x })
    }
}

# ---------------------------------------------------------------------------------------------- compliance exceptions
function Get-ExcLeft {
    param([string]$Expires)
    $base = if ($env:RDS_BCR_EXC_NOW -match '^[0-9]+$') { [long]$env:RDS_BCR_EXC_NOW } else { $script:Now }
    $d = [DateTimeOffset]::new([datetime]::ParseExact($Expires, 'yyyy-MM-dd', $script:Inv), [TimeSpan]::Zero).ToUnixTimeSeconds()
    return [long][Math]::Floor($d / 86400) - [long][Math]::Floor($base / 86400)
}
function Find-BcrException {
    param([string]$Scope, [string]$Acct, [string]$Id)
    foreach ($e in @($script:Exc)) { if ($e.account -eq $Acct -and $e.identifier.ToLowerInvariant() -eq ([string]$Id).ToLowerInvariant() -and $e.scopes -contains $Scope) { return $e } }
    return $null
}
# Add-BcrException: exception columns; an unexpired entry makes the row COMPLIANT (actual_status keeps the evaluated status)
function Add-BcrException {
    param($Row)
    $e = Find-BcrException 'backup' $Row.account_id $Row.identifier
    if ($null -eq $e) { $v = [ordered]@{ exception = 'no'; exception_reason = ''; exception_expires = ''; exception_flag = '' } }
    else {
        $d = Get-ExcLeft $e.expires
        $flag = if ($d -lt 0) { 'exception expired' } else { (@($(if ($Row.status -eq 'COMPLIANT') { 'no longer needed' }), $(if ($d -le 14) { 'expiring soon' })) | Where-Object { $_ }) -join ', ' }
        $v = [ordered]@{ exception = $(if ($d -lt 0) { 'expired' } else { 'yes' }); exception_reason = $e.reason; exception_expires = $e.expires; exception_flag = $flag }
    }
    foreach ($k in $v.Keys) { $Row[$k] = $v[$k] }
    $Row['actual_status'] = $Row.status
    if ($v.exception -eq 'yes') { $Row['status'] = 'COMPLIANT' }
}
function Get-ExcUnmatched {
    param($Rows)
    $keys = @{}; foreach ($r in $Rows) { $keys["$($r.account_id)|$(([string]$r.identifier).ToLowerInvariant())"] = 1 }
    return , @(foreach ($e in @($script:Exc)) { if ($e.scopes -contains 'backup' -and -not $keys.ContainsKey("$($e.account)|$($e.identifier.ToLowerInvariant())")) { [ordered]@{ line = $e.line; account = $e.account; identifier = $e.identifier } } })
}
function Get-ExcCounts {
    param($Rows, $UnmatchedRows)
    return [ordered]@{ entries = [long]@($script:Exc | Where-Object { $_.scopes -contains 'backup' }).Count
        applied = [long]@($Rows | Where-Object { $_.exception -eq 'yes' }).Count
        attention = [long]@($Rows | Where-Object { $_.exception -eq 'yes' -and $_.exception_flag -ne '' }).Count
        expiring_soon = [long]@($Rows | Where-Object { $_.exception -eq 'yes' -and $_.exception_flag -like '*expiring soon*' }).Count
        no_longer_needed = [long]@($Rows | Where-Object { $_.exception -eq 'yes' -and $_.exception_flag -like '*no longer needed*' }).Count
        expired = [long]@($Rows | Where-Object { $_.exception -eq 'expired' }).Count
        unmatched = (Get-ExcUnmatched $UnmatchedRows) }
}

# ---------------------------------------------------------------------------------------------- rows, totals, orphans
# Get-BcrRows: evaluate every resource, add the account name, apply exceptions, sort (account, global cluster group
# with the primary first, region, identifier)
function Get-BcrRows {
    param($D)
    $an = [ordered]@{}; foreach ($a in @($D.accounts)) { $an[[string]$a.account] = [string](Get-Or $a.name '') }
    foreach ($k in $script:O.AccountNames.Keys) { $an[$k] = $script:O.AccountNames[$k] }
    $rows = foreach ($r in @($D.resources)) {
        $x = Invoke-BcrEvaluate $r
        $x['account_name'] = Get-Or $an[[string]$x.account_id] ''
        if ($null -ne $script:Exc) { Add-BcrException $x }
        $x
    }
    return , @(Sort-JqBy @($rows) {
            $g = ($_.global_cluster -ne '' -and $_.global_cluster -ne 'unknown')
            $_.account_id; $(if ($g) { $_.global_cluster } else { $_.identifier }); $(if ($g) { if ($_.global_role -eq 'primary') { 0 } else { 1 } } else { 0 }); $_.region; $_.identifier })
}
# Get-BcrTotals: counts per status and the compliance % (NOT YET DUE is not counted), plus exception counts
function Get-BcrTotals {
    param($Rows, $UnmatchedRows)
    $t = [ordered]@{ resources = [long]@($Rows).Count
        compliant = [long]@($Rows | Where-Object { $_.status -eq 'COMPLIANT' }).Count
        non_compliant = [long]@($Rows | Where-Object { $_.status -eq 'NON-COMPLIANT' }).Count
        not_yet_due = [long]@($Rows | Where-Object { $_.status -eq 'NOT YET DUE' }).Count
        unknown = [long]@($Rows | Where-Object { $_.status -eq 'UNKNOWN' }).Count }
    $d = $t.resources - $t.not_yet_due
    $t['compliance'] = [ordered]@{ compliant = $t.compliant; of = $d; not_yet_due = $t.not_yet_due; pct = $(if ($d -eq 0) { $null } else { [long](Round-Jq (100 * $t.compliant / $d)) }) }
    if ($null -ne $script:Exc) { $t['exceptions'] = Get-ExcCounts $Rows $(if ($null -ne $UnmatchedRows) { $UnmatchedRows } else { $Rows }) }
    return $t
}
# Get-BcrOrphanStatus: SHARED (shared / copied from another account), EXISTING (cross-region copy whose source exists),
# UNVERIFIED (source region not scanned), ORPHANED (source cluster / instance not in this account + region)
function Get-BcrOrphanStatus {
    param($O, $Regions)
    if ($O.kind -eq 'shared' -or ($null -ne $O.source_account -and $O.source_account -ne $O.account_id)) { return 'SHARED' }
    if ($null -ne $O.source_region -and $O.source_region -ne $O.region) {
        $sr = $null
        foreach ($r in @($Regions)) { if ($r.account -eq $O.account_id -and $r.region -eq $O.source_region -and $null -ne $r.existing) { $sr = $r; break } }
        if ($null -eq $sr) { return 'UNVERIFIED' }
        $ex = $sr.existing; $list = if ($ex -is [System.Collections.IDictionary]) { @($ex[$(if ($O.type -eq 'cluster') { 'clusters' } else { 'instances' })]) } else { @() }
        foreach ($x in $list) { if ([string]$x -ceq [string]$O.source_id) { return 'EXISTING' } }
        return 'ORPHANED'
    }
    return 'ORPHANED'
}
function Get-Usd { param([double]$V) return (N ((Round-Jq ($V * 100)) / 100)) }
# Get-BcrOrphanRows: orphan candidates with source status, age and estimated monthly cost, oldest first
function Get-BcrOrphanRows {
    param($D)
    $price = [double](Get-Or $script:Cfg.snapshot_price_per_gb 0.021)
    $rows = foreach ($o in @($D.orphans)) {
        if ($null -eq $o) { continue }
        $x = [ordered]@{}; foreach ($k in $o.Keys) { $x[$k] = $o[$k] }
        $x['source_status'] = Get-BcrOrphanStatus $o $D.regions
        $x['age_days'] = if ($null -eq $o.created_epoch) { $null } else { [long][Math]::Floor(($script:Now - $o.created_epoch) / 86400) }
        $x['est_monthly_usd'] = if ($null -eq $o.size_gb) { $null } else { Get-Usd ([double]$o.size_gb * $price) }
        $x
    }
    return , @(Sort-JqBy @($rows) { $_.created_epoch; $_.account_id; $_.region; $_.id })
}
function Get-BcrOrphanTotals {
    param($OR)
    $o = @($OR | Where-Object { $_.source_status -eq 'ORPHANED' })
    $gb = 0.0; $usd = 0.0; foreach ($x in $o) { $gb += [double](Get-Or $x.size_gb 0); $usd += [double](Get-Or $x.est_monthly_usd 0) }
    return [ordered]@{ orphaned = [long]$o.Count; size_gb = (N $gb); est_monthly_usd = (Get-Usd $usd)
        shared = [long]@($OR | Where-Object { $_.source_status -eq 'SHARED' }).Count; unverified = [long]@($OR | Where-Object { $_.source_status -eq 'UNVERIFIED' }).Count
        price_per_gb_month = $script:Cfg.snapshot_price_per_gb }
}
function Format-Gb { param([double]$V) if ($V -ge 1024) { return "$(J (R1 ($V / 1024))) TB" } return "$((J (R1 $V)) -replace '\.0$', '') GB" }
function Get-OsumText {
    param($T)
    $u = if ($T.est_monthly_usd -ge 10) { [long](Round-Jq $T.est_monthly_usd) } else { $T.est_monthly_usd }
    return "$($T.orphaned) orphaned snapshot$(if ($T.orphaned -ne 1) { 's' }), $(Format-Gb $T.size_gb), ~`$$(J $u)/month (estimate)"
}
