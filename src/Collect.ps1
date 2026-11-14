# src/Collect.ps1 - one account: account id and name, region list, the region scans (one by one or in parallel),
# and the raw AWS responses -> resources / orphan snapshot candidates (the Bash lib/collect.jq).

# Get-BcrArnParts: "arn:aws:rds:REGION:ACCOUNT:type:name" -> @{ region; account; name } ($null when not an ARN)
function Get-BcrArnParts {
    param([AllowNull()]$Arn)
    if ($Arn -isnot [string] -or -not $Arn.StartsWith('arn:')) { return $null }
    $p = $Arn.Split(':')
    return @{ region = $(if ($p.Count -gt 3) { $p[3] }); account = $(if ($p.Count -gt 4) { $p[4] }); name = $(if ($p.Count -gt 6) { $p[6..($p.Count - 1)] -join ':' } else { '' }) }
}
function Test-BcrSkipEngine { param([AllowNull()]$Engine) return ([string]$Engine -match '^(docdb|neptune)') }
# Test-BcrGlob: case-insensitive match against any glob; no globs = match (no -Engine / -Identifier filter)
function Test-BcrGlob {
    param([AllowNull()][string]$Value, [string[]]$Globs)
    if (-not $Globs -or $Globs.Count -eq 0) { return $true }
    foreach ($g in $Globs) { if ([System.Management.Automation.WildcardPattern]::new($g, [System.Management.Automation.WildcardOptions]::IgnoreCase).IsMatch([string]$Value)) { return $true } }
    return $false
}

# ConvertTo-BcrRecoveryPoint: one AWS Backup recovery point -> snapshot entry (kind backup)
function ConvertTo-BcrRecoveryPoint {
    param($P)
    $cb = Get-Or $P['CreatedBy'] @{}
    $sz = $P['BackupSizeInBytes']
    $e = [ordered]@{ kind = 'backup'; id = ([string]$P['RecoveryPointArn']).Split(':')[-1]; created_epoch = (ConvertTo-BcrEpoch $P['CreationDate']); status = $P['Status']
        size_gb = $(if ($null -eq $sz) { $null } else { R1 ([double]$sz / 1073741824) })
        expires_epoch = (ConvertTo-BcrEpoch $(if ($P['CalculatedLifecycle']) { $P['CalculatedLifecycle']['DeleteAt'] })); vault = $P['BackupVaultName'] }
    if ($P['Lifecycle'] -and $null -ne $P['Lifecycle']['DeleteAfterDays']) { $e['ret_days'] = $P['Lifecycle']['DeleteAfterDays'] }
    if (([string]$P['RecoveryPointArn']) -match ':continuous:' -or $P['BackupType'] -eq 'CONTINUOUS') { $e['continuous'] = $true }
    $plan = Get-Or $cb['BackupPlanName'] $cb['BackupPlanId']; if ($null -ne $plan) { $e['plan'] = $plan }
    $rule = Get-Or $cb['BackupRuleName'] $cb['BackupRuleId']; if ($null -ne $rule) { $e['rule'] = $rule }
    if ($null -ne $cb['BackupRuleCron']) { $e['cron'] = $cb['BackupRuleCron'] }
    if ($null -ne $cb['BackupRuleTimezone']) { $e['rtz'] = $cb['BackupRuleTimezone'] }
    return $e
}

# ConvertTo-BcrRegionData: raw responses of one region -> @{ resources; orphans; existing } (lib/collect.jq)
function ConvertTo-BcrRegionData {
    param([string]$Acct, [string]$Reg, $Io)
    $gok = [bool]$Io.global_ok
    $GM = @{}
    foreach ($g in @((Get-Or $Io.globals @{})['GlobalClusters'])) {
        if (-not $g) { continue }
        foreach ($m in @($g['GlobalClusterMembers'])) { if ($m -and $m['DBClusterArn']) { $GM[[string]$m['DBClusterArn']] = @{ g = $g['GlobalClusterIdentifier']; w = ($m['IsWriter'] -eq $true) } } }
    }
    $rpBy = @{}
    foreach ($p in $Io.rps) { $k = ([string]$p['ResourceArn']).ToLowerInvariant(); if (-not $rpBy.ContainsKey($k)) { $rpBy[$k] = [System.Collections.Generic.List[object]]::new() }; $rpBy[$k].Add($p) }
    $rpsOf = { param($arn) $l = [System.Collections.Generic.List[object]]::new(); $k = ([string]$arn).ToLowerInvariant(); if ($rpBy.ContainsKey($k)) { foreach ($p in $rpBy[$k]) { $l.Add((ConvertTo-BcrRecoveryPoint $p)) } }; return , $l }
    $role = { param($arn, [bool]$repl)
        if (-not $gok) { if ($repl) { return 'replica' } else { return 'unknown' } }
        if ($arn -and $GM.ContainsKey([string]$arn)) { if ($GM[[string]$arn].w) { return 'primary' } else { return 'secondary' } }
        if ($repl) { return 'replica' } else { return 'none' } }
    $clusters = @(@($Io.clusters['DBClusters']) | Where-Object { $_ })
    $instances = @(@($Io.instances['DBInstances']) | Where-Object { $_ })
    $csn = @(@($Io.csnaps['DBClusterSnapshots']) | Where-Object { $_ })
    $isn = @(@($Io.isnaps['DBSnapshots']) | Where-Object { $_ })
    $EC = @(Get-JqUnique @($clusters | ForEach-Object { $_['DBClusterIdentifier'] }))
    $EI = @(Get-JqUnique @($instances | ForEach-Object { $_['DBInstanceIdentifier'] }))
    $orphan = { param($s, $type, $sid, $src, $srcarn, $snaparn)
        $sa = Get-BcrArnParts $srcarn; $na = Get-BcrArnParts $snaparn; $si = Get-BcrArnParts $sid
        $shared = ($s['SnapshotType'] -eq 'shared')
        [ordered]@{ account_id = $Acct; region = $Reg; type = $type; id = $(if ($si -and $si.name) { $si.name } else { $sid })
            kind = $(if ($shared) { 'shared' } else { 'manual' }); source_id = $src
            source_account = $(if ($shared) { if ($na) { $na.account } } else { if ($sa) { $sa.account } })
            source_region = (Get-Or $s['SourceRegion'] $(if ($sa) { $sa.region }))
            engine = $s['Engine']; engine_version = $s['EngineVersion']; created_epoch = (ConvertTo-BcrEpoch $s['SnapshotCreateTime']); status = $s['Status']
            size_gb = $s['AllocatedStorage']; encrypted = (Get-Or (Get-Or $s['StorageEncrypted'] $s['Encrypted']) $false); kms_key = $s['KmsKeyId'] } }
    $orphans = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $csn) {
        if (($s['SnapshotType'] -eq 'manual' -or $s['SnapshotType'] -eq 'shared') -and -not (Test-BcrSkipEngine $s['Engine']) -and ($s['SnapshotType'] -eq 'shared' -or $EC -cnotcontains [string]$s['DBClusterIdentifier'])) {
            $orphans.Add((& $orphan $s 'cluster' $s['DBClusterSnapshotIdentifier'] $s['DBClusterIdentifier'] $s['SourceDBClusterSnapshotArn'] $s['DBClusterSnapshotArn']))
        }
    }
    foreach ($s in $isn) {
        if (($s['SnapshotType'] -eq 'manual' -or $s['SnapshotType'] -eq 'shared') -and -not (Test-BcrSkipEngine $s['Engine']) -and ($s['SnapshotType'] -eq 'shared' -or $EI -cnotcontains [string]$s['DBInstanceIdentifier'])) {
            $orphans.Add((& $orphan $s 'instance' $s['DBSnapshotIdentifier'] $s['DBInstanceIdentifier'] $s['SourceDBSnapshotIdentifier'] $s['DBSnapshotArn']))
        }
    }
    $snapOf = { param($list, $idKey, $sidKey, $id)
        $l = [System.Collections.Generic.List[object]]::new()
        foreach ($s in $list) {
            if ($s[$idKey] -ceq $id -and ($s['SnapshotType'] -eq 'manual' -or $s['SnapshotType'] -eq 'automated')) {
                $l.Add([ordered]@{ kind = $s['SnapshotType']; id = $s[$sidKey]; created_epoch = (ConvertTo-BcrEpoch $s['SnapshotCreateTime']); status = $s['Status']; size_gb = $s['AllocatedStorage']; expires_epoch = $null })
            }
        }
        return , $l }
    $resources = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $clusters) {
        if (Test-BcrSkipEngine $c['Engine']) { continue }
        $arn = $c['DBClusterArn']
        $snaps = & $snapOf $csn 'DBClusterIdentifier' 'DBClusterSnapshotIdentifier' $c['DBClusterIdentifier']
        foreach ($x in (& $rpsOf $arn)) { $snaps.Add($x) }
        $resources.Add([ordered]@{ account_id = $Acct; region = $Reg; id = $c['DBClusterIdentifier']; type = 'cluster'; engine = $c['Engine']; engine_version = $c['EngineVersion']
                created_epoch = (ConvertTo-BcrEpoch $c['ClusterCreateTime']); retention = (Get-Or $c['BackupRetentionPeriod'] 0)
                backup_window = $c['PreferredBackupWindow']; copy_tags = $c['CopyTagsToSnapshot']
                global_cluster = $(if ($arn -and $GM.ContainsKey([string]$arn)) { $GM[[string]$arn].g } elseif ($gok) { $null } else { 'unknown' })
                global_role = (& $role $arn ([string]$c['ReplicationSourceIdentifier'] -ne '')); snap_ok = [bool]$Io.csnap_ok; backup_ok = [bool]$Io.backup_ok
                arn = $arn; snapshots = $snaps.ToArray() })
    }
    foreach ($i in $instances) {
        if ($i['DBClusterIdentifier'] -or (Test-BcrSkipEngine $i['Engine'])) { continue }
        $arn = $i['DBInstanceArn']
        $snaps = & $snapOf $isn 'DBInstanceIdentifier' 'DBSnapshotIdentifier' $i['DBInstanceIdentifier']
        foreach ($x in (& $rpsOf $arn)) { $snaps.Add($x) }
        $resources.Add([ordered]@{ account_id = $Acct; region = $Reg; id = $i['DBInstanceIdentifier']; type = 'instance'; engine = $i['Engine']; engine_version = $i['EngineVersion']
                created_epoch = (ConvertTo-BcrEpoch $i['InstanceCreateTime']); retention = (Get-Or $i['BackupRetentionPeriod'] 0); global_cluster = $null
                backup_window = $i['PreferredBackupWindow']; copy_tags = $i['CopyTagsToSnapshot']
                global_role = $(if ([string]$i['ReadReplicaSourceDBInstanceIdentifier'] -ne '') { 'replica' } else { 'none' })
                snap_ok = [bool]$Io.isnap_ok; backup_ok = [bool]$Io.backup_ok; arn = $arn; snapshots = $snaps.ToArray() })
    }
    return @{ resources = $resources; orphans = $orphans; existing = [ordered]@{ clusters = $EC; instances = $EI } }
}

# Get-BcrRegionLine: progress text for one region ("2 clusters, 1 instance, 9 snapshots, 12 recovery points, 1 without source")
function Get-BcrRegionLine {
    param($Resources, [int]$NOrphans)
    $c = 0; $i = 0; $s = 0; $b = 0
    foreach ($r in $Resources) { if ($r.type -eq 'cluster') { $c++ } elseif ($r.type -eq 'instance') { $i++ }; foreach ($x in $r.snapshots) { if ($x.kind -eq 'backup') { $b++ } else { $s++ } } }
    if ($c + $i -eq 0 -and $NOrphans -eq 0) { return '(empty)' }
    $pl = { param($n, $w) "$n $w$(if ($n -ne 1) { 's' })" }
    $t = "$(& $pl $c 'cluster'), $(& $pl $i 'instance'), $(& $pl $s 'snapshot'), $(& $pl $b 'recovery point')"
    if ($NOrphans -gt 0) { $t += ", $NOrphans without source" }
    return $t
}

# Complete-BcrRegion: raw responses -> filtered resources / orphans + the region record; logs the region line
function Complete-BcrRegion {
    param([string]$Acct, [string]$Reg, $Io, [int]$I, [int]$N)
    $O = $script:O
    $errs = [System.Collections.Generic.List[string]]::new()
    try {
        if ($Io.failed) { throw $Io.failed }
        foreach ($e in $Io.errors) { $errs.Add($e) }
        $d = ConvertTo-BcrRegionData $Acct $Reg $Io
        $res = @($d.resources | Where-Object { (Test-BcrGlob $_.id $O.Identifiers) -and (Test-BcrGlob $_.engine $O.Engines) })
        $orph = @($d.orphans | Where-Object { (Test-BcrGlob ([string]$_.source_id) $O.Identifiers) -and (Test-BcrGlob ([string]$_.engine) $O.Engines) })
    }
    catch {
        $why = $_.Exception.Message
        Write-BcrError "[$I/$N] ${Reg}: failed ($why)"
        return @{ failed = $true; resources = @(); orphans = @()
            region = [ordered]@{ account = $Acct; region = $Reg; status = 'error'; resources = 0; errors = @("region scan failed: $why"); snapshot_scan = $false; existing = @() } }
    }
    $status = if ($errs.Count) { 'error' } elseif ($res.Count) { 'with databases' } elseif ($orph.Count) { 'snapshots only' } else { 'empty' }
    foreach ($e in $errs) { Write-BcrWarn "$Acct ${Reg}: $e" }
    $line = Get-BcrRegionLine $res $orph.Count
    if (-not ($line -eq '(empty)' -and $errs.Count -eq 0 -and -not $O.VerboseLog)) {
        if ($line -ne '(empty)') { $line += " ($($Io.secs)s)" }
        if ($errs.Count) { $line += " - ERROR: $($errs -join '; ')"; $line = $line.Replace('(empty)', '(no data)') }
        Write-BcrInfo "[$I/$N] ${Reg}: $line"
    }
    return @{ failed = $false; resources = $res; orphans = $orph
        region = [ordered]@{ account = $Acct; region = $Reg; status = $status; resources = $res.Count; errors = $errs.ToArray(); snapshot_scan = ($Io.csnap_ok -and $Io.isnap_ok); existing = $d.existing } }
}

# Get-BcrDefaultRegion: AWS_REGION / AWS_DEFAULT_REGION / `aws configure get region`
function Get-BcrDefaultRegion {
    param([string]$Prof)
    foreach ($v in $env:AWS_REGION, $env:AWS_DEFAULT_REGION) { if ($v) { return $v } }
    $a = @('configure', 'get', 'region'); if ($Prof) { $a += @('--profile', $Prof) }
    $PSNativeCommandUseErrorActionPreference = $false
    try { $r = & aws @a 2>$null; if ($LASTEXITCODE -eq 0 -and $r) { return ([string]@($r)[0]).Trim() } } catch { Write-Debug "configure get: $_" }
    return ''
}

# Invoke-BcrProfileScan: one profile / account -> account data document (or $null when it cannot be read)
function Invoke-BcrProfileScan {
    param([string]$Prof)
    $O = $script:O; $pn = if ($Prof) { $Prof } else { 'default' }
    $firstReg = if ($O.Regions.Count) { $O.Regions[0] } elseif ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { 'us-east-1' }
    if ($O.DryRun) { $acct = 'ACCOUNT'; [void](Invoke-BcrAws @('sts', 'get-caller-identity') $Prof '') }
    else {
        $r = Invoke-BcrAws @('sts', 'get-caller-identity') $Prof ''
        if (-not $r.ok) { Write-BcrError "profile '$pn': no valid credentials ($($r.err))"; return $null }
        $acct = ''; try { $acct = [string](Read-BcrJson $r.out)['Account'] } catch { $acct = '' }
        if (-not $acct) { Write-BcrError "profile '$pn': no account id"; return $null }
    }
    $aname = if ($O.AccountNames.Contains($acct)) { [string]$O.AccountNames[$acct] } else { '' }
    if (-not $aname) {   # IAM account alias: optional; denied / none = number only (not counted as a failure)
        $f0 = $script:Run.AwsFails
        $r = Invoke-BcrAws @('iam', 'list-account-aliases') $Prof $firstReg
        if ($r.ok) {
            try { $al = @((Read-BcrJson $r.out)['AccountAliases']); if ($al.Count -and $al[0]) { $aname = ([string]$al[0] -replace '[\x00-\x1f]', ''); if ($aname.Length -gt 64) { $aname = $aname.Substring(0, 64) } } } catch { $aname = '' }
        }
        else { $script:Run.AwsFails = $f0; Write-BcrDebug "Account alias for $acct not available (iam:ListAccountAliases)" }
    }
    # region list: -AllRegions (ec2 describe-regions, enabled only, sorted), -Region, else the default region
    if ($O.AllRegions) {
        if ($O.DryRun) { [void](Invoke-BcrAws @('ec2', 'describe-regions') $Prof $firstReg); $regs = @('<each-enabled-region>') }
        else {
            $r = Invoke-BcrAws @('ec2', 'describe-regions', '--filters', 'Name=opt-in-status,Values=opt-in-not-required,opted-in') $Prof $firstReg
            if (-not $r.ok) { Write-BcrError "${acct}: ec2 describe-regions failed ($($r.err))"; return $null }
            $regs = @(Sort-JqBy @(@((Read-BcrJson $r.out)['Regions']) | ForEach-Object { [string]$_['RegionName'] }) { , $_ })
        }
    }
    elseif ($O.Regions.Count) { $regs = @($O.Regions) }
    else {
        $reg = Get-BcrDefaultRegion $Prof
        if (-not $reg) { Write-BcrError "${acct}: no region (use -Region REGION or -AllRegions)"; return $null }
        $regs = @($reg)
    }
    $n = $regs.Count
    Write-BcrInfo "account $acct (profile $pn): $n region(s)"
    $par = [int]$O.Parallel; if ($O.DryRun -or $n -lt 2) { $par = 1 }
    $ctx0 = @{ Timeout = $O.AwsTimeout; DryRun = $O.DryRun; KeepDir = $script:Run.WorkDir; N = $n; Started = ($O.VerboseLog -and $par -gt 1) }
    $results = @{}
    $collect = {   # one finished region: counters, then resources / region record (logged in completion order)
        param($io)
        $script:Run.AwsCalls += $io.calls; $script:Run.AwsFails += $io.fails
        $c = Complete-BcrRegion $acct $io.region $io $io.idx $n
        $results[$io.idx] = $c
    }
    if ($par -le 1) {
        $globals = $null
        for ($k = 0; $k -lt $n; $k++) {
            $ctx = $ctx0.Clone(); $ctx.Idx = $k + 1; $ctx.Globals = $globals
            $io = Invoke-BcrRegionIo $Prof $regs[$k] $ctx
            if ($io.global_read) { $globals = @{ doc = $io.globals; ok = $io.global_ok } }   # account-wide: read once
            & $collect $io
        }
    }
    else {
        Write-BcrInfo "${acct}: scanning $n regions, up to $par at a time"
        $fnAws = ${function:Invoke-BcrAwsCall}.ToString(); $fnIo = ${function:Invoke-BcrRegionIo}.ToString()
        $jobs = for ($k = 0; $k -lt $n; $k++) { $ctx = $ctx0.Clone(); $ctx.Idx = $k + 1; @{ reg = $regs[$k]; ctx = $ctx } }
        $jobs | ForEach-Object -ThrottleLimit $par -Parallel {
            ${function:Invoke-BcrAwsCall} = $using:fnAws; ${function:Invoke-BcrRegionIo} = $using:fnIo
            $ErrorActionPreference = 'Stop'
            Invoke-BcrRegionIo $using:Prof $_.reg $_.ctx
        } | ForEach-Object { & $collect $_ }
    }
    $fails = 0; $summ = @()
    for ($k = 1; $k -le $n; $k++) {
        $c = $results[$k]
        if (-not $c) { $c = @{ failed = $true; resources = @(); orphans = @(); region = [ordered]@{ account = $acct; region = $regs[$k - 1]; status = 'error'; resources = 0; errors = @('region scan failed: no result'); snapshot_scan = $false; existing = @() } }; $results[$k] = $c }
        if ($c.failed) { $fails++ }
        $rr = $c.region
        $summ += "$($rr.region): $(if ($rr.status -eq 'error') { 'failed' } else { 'done' }) ($($rr.resources) resource$(if ($rr.resources -ne 1) { 's' }))"
    }
    if ($par -gt 1) {
        if ($O.VerboseLog) { Write-BcrInfo "$acct regions in order: $($summ -join '; ')" }
        if ($fails) { Write-BcrWarn "${acct}: $fails of $n region(s) failed; see Region errors in the report" }
    }
    if ($O.DryRun) { return $null }
    $regRecs = @(for ($k = 1; $k -le $n; $k++) { $results[$k].region })
    $empty = @($regRecs | Where-Object { $_.status -eq 'empty' } | ForEach-Object { $_.region })
    $failedR = @($regRecs | Where-Object { $_.status -eq 'error' -and @($_.errors | Where-Object { $_ -like 'region scan failed*' }).Count } | ForEach-Object { $_.region })
    $errR = @($regRecs | Where-Object { $_.status -eq 'error' } | ForEach-Object { $_.region })
    $line = "$n region$(if ($n -ne 1) { 's' }) scanned, $($empty.Count) empty$(if ($empty.Count) { ': ' + ($empty -join ', ') })"
    if ($errR.Count) { $line += "; $($errR.Count) failed: $($errR -join ', ')" }
    [void]$failedR
    Write-BcrInfo "${acct}: $line"
    $resources = [System.Collections.Generic.List[object]]::new(); $orphans = [System.Collections.Generic.List[object]]::new()
    for ($k = 1; $k -le $n; $k++) {
        foreach ($r in $results[$k].resources) { $x = [ordered]@{}; foreach ($kk in $r.Keys) { if ($kk -ne 'arn') { $x[$kk] = $r[$kk] } }; $resources.Add($x) }
        foreach ($o in $results[$k].orphans) { $orphans.Add($o) }
    }
    $now = $script:Run.Now
    return [ordered]@{ schema = $script:DataSchema; schema_version = $script:DataSchemaVersion; tool_version = $script:ScriptVersion
        collected_epoch = $now; collected_at = [DateTimeOffset]::FromUnixTimeSeconds($now).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv)
        accounts = @([ordered]@{ account = $acct; profile = $pn; name = $aname; collected_epoch = $now })
        regions = $regRecs; resources = $resources.ToArray(); orphans = $orphans.ToArray() }
}
