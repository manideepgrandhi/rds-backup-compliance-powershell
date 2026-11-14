# src/Aws.ps1 - read-only AWS access through the AWS CLI v2 (the same calls as the Bash tool).
# Only these calls exist: sts get-caller-identity, iam list-account-aliases, ec2 describe-regions,
# rds describe-db-clusters / describe-db-instances / describe-global-clusters / describe-db-cluster-snapshots /
# describe-db-snapshots, backup list-backup-vaults / list-recovery-points-by-backup-vault, configure get region (local file).
# Invoke-BcrAwsCall and Invoke-BcrRegionIo are self-contained (no module state) so the parallel region scan can copy
# them into its runspaces.

# Invoke-BcrAwsCall: one AWS CLI call -> @{ ok; out (stdout text); err (first readable error line, <= 200 chars) }.
# -DryRun prints the command instead and returns '{}'. -KeepDir saves the raw response there.
function Invoke-BcrAwsCall {
    param([string[]]$Arguments, [string]$Prof, [string]$Reg, [int]$Timeout = 30, [switch]$DryRun, [string]$KeepDir)
    $a = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $Arguments) { $a.Add($x) }
    $a.AddRange([string[]]@('--output', 'json', '--cli-connect-timeout', "$Timeout", '--cli-read-timeout', "$Timeout"))
    if ($Reg) { $a.Add('--region'); $a.Add($Reg) }
    if ($Prof) { $a.Add('--profile'); $a.Add($Prof) }
    if ($DryRun) { [Console]::Out.WriteLine('DRY-RUN: aws ' + ($a -join ' ')); return @{ ok = $true; out = '{}'; err = '' } }
    $errFile = [System.IO.Path]::GetTempFileName()
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $o = & aws @a 2> $errFile
        $rc = $LASTEXITCODE
        $out = (@($o) -join "`n")
        $et = [System.IO.File]::ReadAllText($errFile)
    }
    catch { $rc = 255; $out = ''; $et = $_.Exception.Message }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    if ($KeepDir) {
        $name = '{0}_{1}_{2}_{3}.json' -f [guid]::NewGuid().ToString('N').Substring(0, 8), ($Reg -replace '[^a-z0-9-]', ''), $Arguments[0], $Arguments[1]
        try { [System.IO.File]::WriteAllText((Join-Path $KeepDir $name), $out + $(if ($rc -ne 0) { "`n# error: $et" } else { '' })) } catch { Write-Debug "keep: $_" }
    }
    if ($rc -eq 0) { return @{ ok = $true; out = $out; err = '' } }
    $line = ''
    foreach ($l in ($et -replace "`r", '') -split "`n") { if ($l.Trim()) { $line = $l; break } }
    $line = $line.Replace('aws: [ERROR]: ', '').Replace('An error occurred ', '')
    if (-not $line) { $line = "aws exited with $rc" }
    if ($line.Length -gt 200) { $line = $line.Substring(0, 200) }
    return @{ ok = $false; out = $out; err = $line }
}

# Invoke-BcrAws: one call from the main runspace (counts calls / failures)
function Invoke-BcrAws {
    param([string[]]$Arguments, [string]$Prof, [string]$Reg)
    $O = $script:O
    if (-not $O.DryRun) { $script:Run.AwsCalls++; Write-BcrDebug ("aws " + ($Arguments -join ' ') + $(if ($Reg) { " --region $Reg" }) + $(if ($Prof) { " --profile $Prof" })) }
    $r = Invoke-BcrAwsCall -Arguments $Arguments -Prof $Prof -Reg $Reg -Timeout $O.AwsTimeout -DryRun:$O.DryRun -KeepDir $script:Run.WorkDir
    if (-not $r.ok) { $script:Run.AwsFails++ }
    return $r
}

# Invoke-BcrRegionIo: every AWS call for one account + region; returns the parsed responses (no evaluation here).
# Snapshots are read in every region (manual snapshots outlive their source; --include-shared adds shared ones).
# Global clusters and AWS Backup recovery points are read only when the region has a database.
# Ctx: @{ Timeout; DryRun; KeepDir; Idx; N; Verbose; Started (log "started"); Globals (account-wide result already read) }
function Invoke-BcrRegionIo {
    param([string]$Prof, [string]$Reg, [hashtable]$Ctx)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = @{ idx = $Ctx.Idx; region = $Reg; errors = [System.Collections.Generic.List[string]]::new(); calls = 0; fails = 0
        clusters = @{}; instances = @{}; csnaps = @{}; isnaps = @{}; rps = [System.Collections.Generic.List[object]]::new()
        globals = $null; global_ok = $true; global_read = $false; csnap_ok = $true; isnap_ok = $true; backup_ok = $true; failed = ''; secs = 0 }
    $dk = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
    $parse = { param($t) if ([string]::IsNullOrWhiteSpace($t)) { return @{} }
        try { if ($dk) { ConvertFrom-Json -InputObject $t -AsHashtable -NoEnumerate -DateKind String -Depth 200 } else { ConvertFrom-Json -InputObject $t -AsHashtable -NoEnumerate -Depth 200 } }
        catch { throw 'incomplete result (the AWS CLI returned invalid JSON)' } }
    $call = {
        param([string[]]$A)
        if (-not $Ctx.DryRun) { $res.calls++ }
        $r = Invoke-BcrAwsCall -Arguments $A -Prof $Prof -Reg $Reg -Timeout $Ctx.Timeout -DryRun:$Ctx.DryRun -KeepDir $Ctx.KeepDir
        if (-not $r.ok) { $res.fails++ }
        return $r
    }
    try {
        if ($Ctx.Started) { [Console]::Error.WriteLine("$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) [INFO] [$($Ctx.Idx)/$($Ctx.N)] ${Reg}: started") }
        $r = & $call @('rds', 'describe-db-clusters')
        if ($r.ok) { $res.clusters = & $parse $r.out } else { $res.errors.Add("describe-db-clusters: $($r.err)") }
        $r = & $call @('rds', 'describe-db-instances')
        if ($r.ok) { $res.instances = & $parse $r.out } else { $res.errors.Add("describe-db-instances: $($r.err)") }
        $nc = @($res.clusters['DBClusters'] | Where-Object { $_ -and -not ([string]$_['Engine'] -match '^(docdb|neptune)') }).Count
        $ni = @($res.instances['DBInstances'] | Where-Object { $_ -and -not $_['DBClusterIdentifier'] -and -not ([string]$_['Engine'] -match '^(docdb|neptune)') }).Count
        if ($Ctx.DryRun) { $nc = 1; $ni = 1 }
        $r = & $call @('rds', 'describe-db-cluster-snapshots', '--include-shared')
        if ($r.ok) { $res.csnaps = & $parse $r.out } else { $res.csnap_ok = $false; $res.errors.Add("describe-db-cluster-snapshots: $($r.err)") }
        $r = & $call @('rds', 'describe-db-snapshots', '--include-shared')
        if ($r.ok) { $res.isnaps = & $parse $r.out } else { $res.isnap_ok = $false; $res.errors.Add("describe-db-snapshots: $($r.err)") }
        if ($nc + $ni -gt 0) {
            if ($nc -gt 0) {
                if ($Ctx.Globals) { $res.globals = $Ctx.Globals.doc; $res.global_ok = $Ctx.Globals.ok }
                else {
                    $res.global_read = $true
                    $r = & $call @('rds', 'describe-global-clusters')
                    if ($r.ok) { $res.globals = & $parse $r.out } else { $res.global_ok = $false; $res.globals = @{}; $res.errors.Add("describe-global-clusters: $($r.err)") }
                }
            }
            $r = & $call @('backup', 'list-backup-vaults')
            if ($r.ok) {
                $vl = & $parse $r.out
                foreach ($v in @($vl['BackupVaultList'])) {
                    if (-not $v -or -not $v['BackupVaultName']) { continue }
                    $vn = [string]$v['BackupVaultName']
                    $r2 = & $call @('backup', 'list-recovery-points-by-backup-vault', '--backup-vault-name', $vn)
                    if ($r2.ok) {
                        foreach ($p in @((& $parse $r2.out)['RecoveryPoints'])) {
                            if ($p -and ($p['ResourceType'] -eq 'Aurora' -or $p['ResourceType'] -eq 'RDS' -or ([string]$p['ResourceArn']) -match ':rds:')) { $res.rps.Add($p) }
                        }
                    }
                    else { $res.backup_ok = $false; $res.errors.Add("list-recovery-points-by-backup-vault ${vn}: $($r2.err)") }
                }
            }
            else { $res.backup_ok = $false; $res.errors.Add("list-backup-vaults: $($r.err)") }
        }
    }
    catch { $res.failed = ($_.Exception.Message -replace '\s+', ' ').Trim(); if ($res.failed.Length -gt 200) { $res.failed = $res.failed.Substring(0, 200) } }
    $res.secs = [long][Math]::Floor($sw.Elapsed.TotalSeconds)
    if ($Ctx.Started) { [Console]::Error.WriteLine("$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) [DEBUG] [$($Ctx.Idx)/$($Ctx.N)] ${Reg}: calls finished") }
    return $res
}
