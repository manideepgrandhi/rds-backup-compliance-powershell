# src/Main.ps1 - Invoke-RdsBackupCompliance: the whole run, plus the -Help text.
# Returns the exit code (0 ok, 1 usage, 2 pre-check, 3 bad -Merge input, 4 output error, 5 NON-COMPLIANT with
# -FailOnNonCompliant) instead of exiting, so Pester and other scripts can call it; the .ps1 wrapper exits with it.

$script:ScriptName = 'Invoke-RdsBackupCompliance.ps1'
$script:ScriptVersion = '1.0.0'   # PowerShell 7 version of rds_backup_compliance_report.sh v1.6.0 (same rules and outputs)

function New-BcrRun { return @{ Now = [long]0; AwsCalls = 0; AwsFails = 0; Stamp = ''; WorkDir = ''; Written = [System.Collections.Generic.List[string]]::new() } }

function Get-BcrUsage {
    return @"
$script:ScriptName v$script:ScriptVersion - backup compliance report for Aurora clusters and RDS instances (read-only)
PowerShell 7 version of rds_backup_compliance_report.sh v1.6.0 (same rules, statuses, CSV columns and HTML page).

Usage: ./Invoke-RdsBackupCompliance.ps1 [options]     (Get-Help ./Invoke-RdsBackupCompliance.ps1 -Full for examples)

Scope:
  -ProfileName NAME[,NAME]  AWS CLI profile(s) / accounts (default: current credentials)
  -Region R[,R]             Region(s) (default: AWS_REGION / AWS_DEFAULT_REGION / profile region)
  -AllRegions               Every enabled region (ec2 describe-regions); regions without databases are left out
  -Engine GLOB[,GLOB]       aurora-postgresql, aurora-mysql, postgres, mysql, mariadb, 'sqlserver-*', 'oracle-*'
  -Identifier GLOB[,GLOB]   Cluster / instance identifier (case-insensitive globs)

Compliance (defaults in brackets):
  -Daily N                  RDS automated: retention >= N days, a backup on each of the last N days [7]
  -DailyMaxAge H            Latest automated backup at most H hours old                         [26]
  -Weekly auto|N            Weekly points expected: auto = every scheduled weekday in the
                            -WeeklyWindowDays window (4 or 5); N = the last N scheduled days    [auto]
  -WeeklyWindowDays N       Window for -Weekly auto                                            [30]
  -WeeklyWeekday DAY        Day the weekly backup runs (sun..sat)                              [sat]
  -Monthly N                First-<day> points expected, one per month for the last N months   [12]
  -MonthlyRule RULE         first-sun (first Sunday of the month), first-mon, ... first-sat    [first-sun]
  -ToleranceDays N          A point counts for a scheduled day if taken up to N days before/after [1]
  -Yearly N                 AWS Backup points with retention above the monthly range; 0 = off  [0]
  -WeeklyDays MIN-MAX       Retention (days) that classifies a recovery point as weekly        [25-40]
  -MonthlyDays MIN-MAX      Retention (days) that classifies a recovery point as monthly       [300-400]
  -MonthlyMaxDays N         Same as the MAX of -MonthlyDays
  -DailyRetentionDays N     Expected RDS BackupRetentionPeriod; more is highlighted            [= -Daily]
  -WeeklyRetentionDays N    Expected retention of a weekly point (highlight if not)            [30]
  -MonthlyRetentionDays N   Expected retention of a monthly point (highlight if not)           [365]
  -RetentionToleranceDays N Allowed difference from the expected retention                     [1]
  -ReplicaExemptEngines L   Engine globs (comma-separated). Role=replica/secondary matching these
                            are always COMPLIANT (all schedules N/A). Empty = daily only         []
  -NonCompliantOnly         Show only NON-COMPLIANT rows
  -FailOnNonCompliant       Exit 5 when a NON-COMPLIANT resource is found
  -Exceptions FILE          Compliance exceptions: lines "account_id | identifier | scope | expires | reason";
                            listed servers (scope backup) show COMPLIANT (EXCEPTION) and count as compliant until
                            the expiry date. Default: compliance_exceptions.conf next to the script, if present.
                            Any malformed line stops the run. See compliance_exceptions.conf.example

Report:
  -Format LIST              text,csv,json,html (default: text; html with -Merge). Several formats need -OutputDir.
                            csv writes the compliance CSV and, with -OutputDir, also <name>_backups.csv and
                            <name>_orphaned_snapshots.csv
  -OutputDir DIR            Write <prefix>_<account>_YYYYmmdd_HHMMSS.<ext> into DIR; DIR\FILE.html names the HTML file
  -ManualOlderThan N        Also write <name>_manual_older_than_<N>d.csv: manual snapshots older than N days
  -SnapshotPricePerGb USD   Price per GB-month for the orphaned-snapshot cost estimate          [0.021]
  -SaveData                 Also write the raw data for -Merge: rds_backup_<ACCOUNT>_<YYYYMMDD>.json per account
  -SaveDataFile FILE.json   ... with this name (implies -SaveData; _<account> is added for several accounts)
  -Prefix NAME              File name prefix                                                   [rds_backup_compliance]
  -Tz ZONE                  Second time zone shown next to UTC (IANA or Windows id)            [Asia/Kolkata = IST]
  -LogFile FILE             Append log lines to FILE

Merge (offline, zero AWS calls):
  -Merge FILE|DIR ...       Combine -SaveData files of several accounts. Same account twice: the newer collection
                            wins. Compliance is evaluated again at merge time. e.g. -Merge a.json b.json -OutputDir all.html

Alerts (optional):
  -AlertEmail ADDR[,ADDR]   E-mail the text report through -AlertSmtpServer HOST (-AlertSmtpPort N, default 25)
  -AlertOn WHEN             noncompliant (NON-COMPLIANT or region errors) | always               [noncompliant]
  -AlertFrom ADDR           From address; -AlertAttach also attaches the files written; -AlertTest sends a test

Behaviour:
  -ConfigFile FILE          key=value settings (Bash --config names, e.g. weekly=4; never executed; parameters win)
  -Parallel N               Scan up to N regions of an account at the same time; 1 = one by one [4]
  -AwsTimeout SEC           AWS CLI connect/read timeout                                       [30]
  -MaxAttempts N            AWS CLI retry attempts                                             [5]
  -KeepWorkdir              Keep raw AWS responses for debugging
  -DryRun                   Print the AWS calls that would run; call nothing
  -Verbose                  Every region line (empty regions too) and debug logs
  -Help / -Version

AWS calls (all read-only, AWS CLI v2): sts get-caller-identity; iam list-account-aliases (optional, account name);
ec2 describe-regions (-AllRegions); rds describe-db-clusters, describe-db-instances, describe-global-clusters,
describe-db-cluster-snapshots and describe-db-snapshots (--include-shared, every region, for orphaned snapshots);
backup list-backup-vaults, list-recovery-points-by-backup-vault.
Exit codes: 0 ok, 5 NON-COMPLIANT with -FailOnNonCompliant, 1 usage, 2 pre-check, 3 bad -Merge input, 4 output error.
"@
}

# Set-BcrParams: parameters override the config file (a list given here replaces the config list)
function Set-BcrParams {
    param([hashtable]$B)
    $O = $script:O
    $map = @{}; foreach ($k in $script:OptKeys.Keys) { $map[$script:OptKeys[$k]] = $k }
    foreach ($p in $B.Keys) {
        if (-not $map.ContainsKey($p)) { continue }
        $v = $B[$p]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { [void](Set-BcrOpt $map[$p] 'yes') }; continue }
        if ($v -is [array]) { $v = ($v -join ',') }
        [void](Set-BcrOpt $map[$p] ([string]$v))
    }
    if ($B.ContainsKey('Debug') -and $B.Debug) { $O.VerboseLog = $true }
    if ($B.ContainsKey('SaveDataFile')) { $O.SaveData = $true; $O.SaveDataFile = [string]$B.SaveDataFile }
    foreach ($s in 'KeepWorkdir', 'DryRun', 'AlertTest') { if ($B.ContainsKey($s) -and $B[$s]) { $O[$s] = $true } }
    if ($B.ContainsKey('Merge')) { $O.Merge = $true; $O.MergeArgs = @($B.Merge | Where-Object { $_ }) }
    $more = @($B['MoreArgs'] | Where-Object { $null -ne $_ -and $_ -ne '' })
    if ($more.Count) { if ($O.Merge) { $O.MergeArgs = @($O.MergeArgs) + $more } else { Stop-Bcr 1 "Unknown option: $($more[0]) (see -Help)" } }
}

# New-BcrCfg: every threshold as one object (shown in JSON / HTML; the page script reads it)
function New-BcrCfg {
    $O = $script:O; $tz = Get-BcrTz $O.Tz $script:Run.Now
    return [ordered]@{ manual_older_than = $O.ManualOlder; snapshot_price_per_gb = $O.SnapPrice; daily = $O.Daily; daily_max_age_h = $O.DailyMaxAgeH
        weekly = $O.Weekly; monthly = $O.Monthly; yearly = $O.Yearly; weekly_min_days = $O.WeeklyMinDays; weekly_max_days = $O.WeeklyMaxDays
        monthly_min_days = $O.MonthlyMinDays; monthly_max_days = $O.MonthlyMaxDays; weekly_weekday = [long](Get-BcrDowNum $O.WeeklyWeekday)
        monthly_weekday = [long](Get-BcrDowNum ($O.MonthlyRule -replace '^first-', '')); tolerance_days = $O.ToleranceDays; weekly_window_days = $O.WeeklyWindowDays
        daily_retention_days = $(if ($null -ne $O.DailyRetentionDays) { $O.DailyRetentionDays } else { $O.Daily }); weekly_retention_days = $O.WeeklyRetentionDays
        monthly_retention_days = $O.MonthlyRetentionDays; ret_tolerance_days = $O.RetToleranceDays; replica_exempt_engines = [string[]]@($O.ExemptEngines)
        tz_offset = [long]$tz.offset; tz_label = $tz.label }
}

# Write-BcrOutputs: one file per format (csv adds the backups and orphaned snapshot CSVs), the manual-snapshot CSV
function Write-BcrOutputs {
    param($Rep)
    $O = $script:O; $D = $Rep.D
    $accts = @(Get-JqUnique @($D.accounts | ForEach-Object { [string]$_.account }))
    $tag = if (@($D.accounts).Count -gt 3) { "merged_$(@($D.accounts).Count)_accounts" } else { $accts -join '_' }
    $base = if ($O.OutputDir) { Join-Path $O.OutputDir "$($O.Prefix)_${tag}_$($script:Run.Stamp)" } else { $null }
    foreach ($f in $O.Formats) {
        $text = switch ($f) { 'text' { ConvertTo-BcrText $Rep } 'csv' { ConvertTo-BcrCsv $Rep.Rows } 'json' { ConvertTo-BcrJsonReport $Rep } 'html' { ConvertTo-BcrHtml $Rep } }
        if (-not $base) { Write-BcrStdout $text; continue }
        if ($f -eq 'html' -and $O.OutFile) { Write-BcrFile $O.OutFile $text; continue }
        Write-BcrFile "$base.$(if ($f -eq 'text') { 'txt' } else { $f })" $text
        if ($f -eq 'csv') {
            Write-BcrFile "${base}_backups.csv" (ConvertTo-BcrBackupsCsv $D $Rep.OR)
            Write-BcrFile "${base}_orphaned_snapshots.csv" (ConvertTo-BcrOrphanCsv $Rep.OR)
        }
    }
    if ($null -ne $O.ManualOlder) {
        $dir = if ($O.OutputDir) { $O.OutputDir } else { '.' }
        $csv = ConvertTo-BcrManualCsv $D $Rep.OR
        Write-BcrFile (Join-Path $dir "$($O.Prefix)_${tag}_$($script:Run.Stamp)_manual_older_than_$($O.ManualOlder)d.csv") $csv
        Write-BcrInfo "manual snapshots older than $($O.ManualOlder) days: $(@($csv.TrimEnd("`n").Split("`n")).Count - 1)"
    }
}
function Write-BcrOutputBlock {
    $w = $script:Run.Written; if (-not $w.Count) { return }
    [Console]::Error.WriteLine("Output ($($w.Count) file$(if ($w.Count -ne 1) { 's' })):")
    foreach ($f in $w) { [Console]::Error.WriteLine("  $f") }
    if ($script:O.LogFile) { try { [System.IO.File]::AppendAllText($script:O.LogFile, (($w | ForEach-Object { "wrote $_" }) -join "`n") + "`n") } catch { Write-Debug "log: $_" } }
}

<#
.SYNOPSIS
Backup compliance report for Aurora clusters and RDS instances (read-only). Returns the exit code.
.DESCRIPTION
Module entry point behind Invoke-RdsBackupCompliance.ps1. Same parameters; see that script's help or -Help.
#>
function Invoke-RdsBackupCompliance {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Alias('Profile', 'P')][string[]]$ProfileName, [Alias('r')][string[]]$Region, [Alias('A')][switch]$AllRegions,
        [Alias('e')][string[]]$Engine, [Alias('i')][string[]]$Identifier,
        [string]$Daily, [string]$DailyMaxAge, [string]$Weekly, [string]$WeeklyWindowDays, [string]$WeeklyWeekday, [string]$Monthly, [string]$MonthlyRule,
        [string]$ToleranceDays, [string]$Yearly, [string]$WeeklyDays, [string]$MonthlyDays, [string]$MonthlyMaxDays,
        [string]$DailyRetentionDays, [string]$WeeklyRetentionDays, [string]$MonthlyRetentionDays, [string]$RetentionToleranceDays,
        [string[]]$ReplicaExemptEngines, [switch]$NonCompliantOnly, [switch]$FailOnNonCompliant, [Alias('ExceptionsFile')][string]$Exceptions,
        [Alias('F')][string[]]$Format, [Alias('o')][string]$OutputDir, [string]$ManualOlderThan, [string]$SnapshotPricePerGb,
        [switch]$SaveData, [string]$SaveDataFile, [string]$Prefix, [Alias('TimeZone')][string]$Tz, [Alias('l')][string]$LogFile, [string[]]$Merge,
        [string[]]$AlertEmail, [string]$AlertSmtpServer, [string]$AlertSmtpPort, [string]$AlertFrom, [string]$AlertOn, [switch]$AlertAttach, [switch]$AlertTest,
        [Alias('Config')][string]$ConfigFile, [string]$Parallel, [string]$AwsTimeout, [string]$MaxAttempts, [switch]$KeepWorkdir, [switch]$DryRun,
        [Alias('h')][switch]$Help, [Alias('V')][switch]$Version,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$MoreArgs
    )
    # -Verbose / -Debug only switch on this tool's own detail lines, not PowerShell's VERBOSE stream of every cmdlet
    $VerbosePreference = 'SilentlyContinue'; $DebugPreference = 'SilentlyContinue'
    $script:O = New-BcrOptions; $script:Run = New-BcrRun; $script:Exc = $null; $script:ExcPath = ''
    $rc = 0
    try {
        if ($Help) { Write-BcrStdout ((Get-BcrUsage) + "`n"); return 0 }
        if ($Version) { Write-BcrStdout "$script:ScriptName $script:ScriptVersion`n"; return 0 }
        if ($ConfigFile) { $script:O.ConfigFile = $ConfigFile; Import-BcrConfig $ConfigFile }
        Set-BcrParams $PSBoundParameters
        Confirm-BcrOptions
        $O = $script:O
        if (-not $O.Merge -and -not $O.DryRun -and -not $O.AlertTest -and -not (Get-Command aws -ErrorAction SilentlyContinue)) { Stop-Bcr 2 'aws CLI not found (install the AWS CLI v2)' }
        $script:Exc = Import-BcrExceptions $O.ExcFile $script:RepoRoot   # before any AWS call: a bad line stops the run now
        if ($null -ne $script:Exc) { Write-BcrInfo "Exceptions file $($script:ExcPath): $(@($script:Exc).Count) entries" }
        $script:Run.Now = Get-BcrNow
        $script:Run.Stamp = [DateTimeOffset]::FromUnixTimeSeconds($script:Run.Now).UtcDateTime.ToString('yyyyMMdd_HHmmss', $script:Inv)
        $script:Now = $script:Run.Now
        $script:Cfg = New-BcrCfg
        if ($O.AlertTest) { Send-BcrAlert $null 'test'; return 0 }
        if ($O.OutputDir -and -not $O.DryRun) { try { [void](New-Item -ItemType Directory -Force -Path $O.OutputDir -ErrorAction Stop) } catch { Stop-Bcr 4 "Cannot create $($O.OutputDir)" } }
        if ($O.KeepWorkdir -and -not $O.DryRun) { $script:Run.WorkDir = (New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('rds_bcr.' + [guid]::NewGuid().ToString('N').Substring(0, 8)))).FullName }
        # the AWS CLI settings for every call of this run (retries in standard mode, no pager, UTF-8 output)
        $env:AWS_MAX_ATTEMPTS = "$($O.MaxAttempts)"; $env:AWS_RETRY_MODE = 'standard'; $env:AWS_PAGER = ''
        try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { Write-Debug "encoding: $_" }
        if ($O.Merge) { $data = Invoke-BcrMerge }
        else {
            $docs = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $(if ($O.Profiles.Count) { $O.Profiles } else { @('') })) { $d = Invoke-BcrProfileScan $p; if ($d) { $docs.Add($d) } }
            if ($O.DryRun) { return 0 }
            if ($docs.Count -eq 0) { Stop-Bcr 2 'No profile could be scanned' }
            $data = [ordered]@{ schema = $script:DataSchema; schema_version = $script:DataSchemaVersion; collected_epoch = $script:Run.Now
                accounts = @($docs | ForEach-Object { $_.accounts }); regions = @($docs | ForEach-Object { $_.regions }); resources = @($docs | ForEach-Object { $_.resources }); orphans = @($docs | ForEach-Object { $_.orphans }) }
            Write-BcrInfo "AWS calls: $($script:Run.AwsCalls) ($($script:Run.AwsFails) failed)"
            if ($O.SaveData) { Save-BcrData $docs }
        }
        $unmatchedRows = $null
        if ($O.NcOnly) {   # keep only NON-COMPLIANT resources; exceptions are still matched against every scanned server
            $all = Get-BcrRows $data
            $keys = @{}; foreach ($r in $all) { if ($r.status -eq 'NON-COMPLIANT') { $keys["$($r.account_id)|$($r.region)|$($r.identifier)"] = 1 } }
            $unmatchedRows = @(foreach ($r in @($data.resources)) { @{ account_id = $r.account_id; identifier = $r.id } })
            $nd = [ordered]@{}; foreach ($k in $data.Keys) { $nd[$k] = $data[$k] }
            $nd['resources'] = @($data.resources | Where-Object { $keys.ContainsKey("$($_.account_id)|$($_.region)|$($_.id)") })
            $data = $nd
        }
        $rep = New-BcrReport $data $unmatchedRows
        Write-BcrOutputs $rep
        $nc = $rep.T.non_compliant
        Write-BcrInfo "resources: $(@($data.resources).Count), non-compliant: $nc"
        foreach ($l in (Get-BcrExcLog $rep)) { if ($l[0] -eq 'W') { Write-BcrWarn $l[1] } else { Write-BcrInfo $l[1] } }
        Write-BcrInfo (Get-OsumText $rep.OT)
        Write-BcrOutputBlock
        if ($O.FailOnNc -and $nc -gt 0) { $rc = 5 }
        Send-BcrAlert $rep '' @($script:Run.Written)
        return $rc
    }
    catch {
        $code = $_.Exception.Data['BcrExit']
        if ($null -ne $code) { return [int]$code }
        Write-BcrError "Internal error: $($_.Exception.Message)"
        Write-BcrDebug $_.ScriptStackTrace
        return 4
    }
    finally {
        if ($script:Run.WorkDir) { [Console]::Error.WriteLine("workdir kept: $($script:Run.WorkDir)") }
    }
}
