# src/Options.ps1 - settings (defaults, -ConfigFile, parameters), logging, validation and the exceptions file.
# Every setting lives in $script:O. Set-BcrOpt validates one key (same keys as the Bash --config file) and is used
# for both the config file and the parameters, so a value is checked the same way wherever it comes from.

# ---------------------------------------------------------------------------------------------- defaults
function New-BcrOptions {
    return @{
        Profiles = @(); Regions = @(); AllRegions = $false; Engines = @(); Identifiers = @(); Formats = @(); FormatsSet = $false
        MergeArgs = @(); Merge = $false; ExemptEngines = @()
        OutputDir = ''; OutFile = ''; ManualOlder = $null; SnapPrice = 0.021; Prefix = 'rds_backup_compliance'; Tz = 'Asia/Kolkata'
        Daily = 7; DailyMaxAgeH = 26; Weekly = 'auto'; Monthly = 12; Yearly = 0
        WeeklyMinDays = 25; WeeklyMaxDays = 40; MonthlyMinDays = 300; MonthlyMaxDays = 400
        WeeklyWeekday = 'sat'; MonthlyRule = 'first-sun'; ToleranceDays = 1; WeeklyWindowDays = 30; Parallel = 4
        DailyRetentionDays = $null; WeeklyRetentionDays = 30; MonthlyRetentionDays = 365; RetToleranceDays = 1
        NcOnly = $false; FailOnNc = $false; LogFile = ''; ConfigFile = ''; AwsTimeout = 30; MaxAttempts = 5
        KeepWorkdir = $false; DryRun = $false; VerboseLog = $false; SaveData = $false; SaveDataFile = ''
        ExcFile = ''; AccountNames = [ordered]@{}
        AlertEmails = @(); AlertOn = 'noncompliant'; AlertFrom = ''; AlertTest = $false; AlertSmtpServer = ''; AlertSmtpPort = 25; AlertAttach = $false
    }
}

# ---------------------------------------------------------------------------------------------- logging
# Write-BcrLog: "YYYY-mm-dd HH:MM:SS [LEVEL] message" on stderr (stdout stays clean for the report) and in -LogFile
function Write-BcrLog {
    param([string]$Level, [string]$Message)
    $line = "$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv)) [$Level] $Message"
    [Console]::Error.WriteLine($line)
    if ($script:O -and $script:O.LogFile -and -not $script:O.DryRun) {
        try { [System.IO.File]::AppendAllText($script:O.LogFile, $line + "`n") } catch { Write-Debug "log file write failed: $_" }
    }
}
function Write-BcrInfo { param([string]$Message) Write-BcrLog INFO $Message }
function Write-BcrWarn { param([string]$Message) Write-BcrLog WARN $Message }
function Write-BcrError { param([string]$Message) Write-BcrLog ERROR $Message }
function Write-BcrDebug { param([string]$Message) if ($script:O -and $script:O.VerboseLog) { Write-BcrLog DEBUG $Message } }
# Write-BcrStdout: report text on stdout (never through the pipeline, which carries only the exit code)
function Write-BcrStdout { param([string]$Text) [Console]::Out.Write($Text); [Console]::Out.Flush() }

# Stop-Bcr: log an error and leave with an exit code (thrown, so cleanup still runs; the entry point returns the code)
function Stop-Bcr {
    param([int]$Code, [string]$Message)
    if ($Message) { Write-BcrError $Message }
    $e = [System.Exception]::new("BcrExit ${Code}: $Message")
    $e.Data['BcrExit'] = $Code
    throw $e
}

# ---------------------------------------------------------------------------------------------- helpers
# Split-BcrList: "a, b,c" (or an array of such strings) -> @('a','b','c'); blanks dropped
function Split-BcrList {
    param([AllowNull()][object[]]$Value)
    $out = foreach ($v in @($Value)) { foreach ($p in ([string]$v).Split(',')) { $t = ($p -replace '\s', ''); if ($t) { $t } } }
    return , @($out)
}
# Test-BcrTrue: 1 / y / yes / true / on (any case)
function Test-BcrTrue { param([string]$Value) return @('1', 'y', 'yes', 'true', 'on') -contains $Value.ToLowerInvariant() }
function Expand-BcrHome { param([string]$Path) if ($Path -match '^~') { return ($HOME + $Path.Substring(1)) } return $Path }
# Resolve-BcrPath: absolute path (does not need to exist)
function Resolve-BcrPath { param([string]$Path) return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
function Assert-BcrInt { param([string]$Name, [string]$V) if ($V -notmatch '^[0-9]+$') { Stop-Bcr 1 "$Name must be a whole number (got '$V')" } return [long]$V }
function Assert-BcrDow { param([string]$Name, [string]$V) if ($V.ToLowerInvariant() -notmatch '^(sun|mon|tue|wed|thu|fri|sat)$') { Stop-Bcr 1 "$Name must be sun, mon, tue, wed, thu, fri or sat (got '$V')" } }
function Get-BcrDowNum { param([string]$Day) return [array]::IndexOf(@('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'), $Day.ToLowerInvariant()) }

# The settings: config key (Bash --config name) -> parameter name. Used by Set-BcrOpt and the -Help text.
$script:OptKeys = [ordered]@{
    'profile' = 'ProfileName'; 'region' = 'Region'; 'all-regions' = 'AllRegions'; 'engine' = 'Engine'; 'identifier' = 'Identifier'
    'daily' = 'Daily'; 'daily-max-age' = 'DailyMaxAge'; 'weekly' = 'Weekly'; 'weekly-window-days' = 'WeeklyWindowDays'; 'weekly-weekday' = 'WeeklyWeekday'
    'monthly' = 'Monthly'; 'monthly-rule' = 'MonthlyRule'; 'parallel' = 'Parallel'; 'tolerance-days' = 'ToleranceDays'; 'yearly' = 'Yearly'
    'weekly-days' = 'WeeklyDays'; 'monthly-days' = 'MonthlyDays'; 'monthly-max-days' = 'MonthlyMaxDays'
    'daily-retention-days' = 'DailyRetentionDays'; 'weekly-retention-days' = 'WeeklyRetentionDays'; 'monthly-retention-days' = 'MonthlyRetentionDays'
    'retention-tolerance-days' = 'RetentionToleranceDays'; 'replica-exempt-engines' = 'ReplicaExemptEngines'
    'non-compliant-only' = 'NonCompliantOnly'; 'fail-on-noncompliant' = 'FailOnNonCompliant'; 'exceptions' = 'Exceptions'
    'format' = 'Format'; 'output-dir' = 'OutputDir'; 'snapshot-price-per-gb' = 'SnapshotPricePerGb'; 'manual-older-than' = 'ManualOlderThan'
    'save-data' = 'SaveData'; 'prefix' = 'Prefix'; 'tz' = 'Tz'; 'log-file' = 'LogFile'; 'aws-timeout' = 'AwsTimeout'; 'max-attempts' = 'MaxAttempts'
    'verbose' = 'Verbose'; 'alert-email' = 'AlertEmail'; 'alert-smtp-server' = 'AlertSmtpServer'; 'alert-smtp-port' = 'AlertSmtpPort'
    'alert-from' = 'AlertFrom'; 'alert-on' = 'AlertOn'; 'alert-attach' = 'AlertAttach'
}

# Set-BcrOpt: validate one setting and store it (config key spelling, - or _ both work). Returns $false for an unknown key.
function Set-BcrOpt {
    param([string]$Key, [AllowEmptyString()][string]$V)
    $O = $script:O
    $k = $Key.ToLowerInvariant().Replace('_', '-')
    switch ($k) {
        'profile' { $O.Profiles = Split-BcrList $V; break }
        'region' { $O.Regions = Split-BcrList $V; break }
        'all-regions' { $O.AllRegions = Test-BcrTrue $V; break }
        'engine' { $O.Engines = Split-BcrList $V; break }
        'identifier' { $O.Identifiers = Split-BcrList $V; break }
        'daily' { $O.Daily = Assert-BcrInt '-Daily' $V; break }
        'daily-max-age' { $O.DailyMaxAgeH = Assert-BcrInt '-DailyMaxAge' $V; break }
        'weekly' { if ($V -eq 'auto') { $O.Weekly = 'auto' } else { $O.Weekly = Assert-BcrInt '-Weekly' $V }; break }
        'monthly' { $O.Monthly = Assert-BcrInt '-Monthly' $V; break }
        'yearly' { $O.Yearly = Assert-BcrInt '-Yearly' $V; break }
        'weekly-days' {
            $m = [regex]::Match($V, '^([0-9]+)-([0-9]+)$'); if (-not $m.Success) { Stop-Bcr 1 "-WeeklyDays must be MIN-MAX (got '$V')" }
            $O.WeeklyMinDays = [long]$m.Groups[1].Value; $O.WeeklyMaxDays = [long]$m.Groups[2].Value; break
        }
        'monthly-days' {
            $m = [regex]::Match($V, '^([0-9]+)-([0-9]+)$'); if (-not $m.Success) { Stop-Bcr 1 "-MonthlyDays must be MIN-MAX (got '$V')" }
            $O.MonthlyMinDays = [long]$m.Groups[1].Value; $O.MonthlyMaxDays = [long]$m.Groups[2].Value; break
        }
        'monthly-max-days' { $O.MonthlyMaxDays = Assert-BcrInt '-MonthlyMaxDays' $V; break }
        'weekly-weekday' { Assert-BcrDow '-WeeklyWeekday' $V; $O.WeeklyWeekday = $V.ToLowerInvariant(); break }
        'monthly-rule' {
            if ($V.ToLowerInvariant() -notmatch '^first-(sun|mon|tue|wed|thu|fri|sat)$') { Stop-Bcr 1 "-MonthlyRule must be first-sun .. first-sat (got '$V')" }
            $O.MonthlyRule = $V.ToLowerInvariant(); break
        }
        'parallel' { $n = Assert-BcrInt '-Parallel' $V; if ($n -lt 1 -or $n -gt 32) { Stop-Bcr 1 "-Parallel must be 1-32 (got '$V')" }; $O.Parallel = $n; break }
        'daily-retention-days' { $O.DailyRetentionDays = Assert-BcrInt '-DailyRetentionDays' $V; break }
        'weekly-retention-days' { $O.WeeklyRetentionDays = Assert-BcrInt '-WeeklyRetentionDays' $V; break }
        'monthly-retention-days' { $O.MonthlyRetentionDays = Assert-BcrInt '-MonthlyRetentionDays' $V; break }
        'retention-tolerance-days' { $O.RetToleranceDays = Assert-BcrInt '-RetentionToleranceDays' $V; break }
        'tolerance-days' { $n = Assert-BcrInt '-ToleranceDays' $V; if ($n -gt 3) { Stop-Bcr 1 "-ToleranceDays must be 0-3 (got '$V')" }; $O.ToleranceDays = $n; break }
        'weekly-window-days' { $n = Assert-BcrInt '-WeeklyWindowDays' $V; if ($n -lt 7) { Stop-Bcr 1 '-WeeklyWindowDays must be at least 7' }; $O.WeeklyWindowDays = $n; break }
        'format' { $O.Formats = Split-BcrList $V; $O.FormatsSet = $true; break }
        'output-dir' { $O.OutputDir = Expand-BcrHome $V; break }
        'prefix' { $O.Prefix = $V; break }
        'tz' { $O.Tz = $V; break }
        'log-file' { $O.LogFile = Expand-BcrHome $V; break }
        'aws-timeout' { $n = Assert-BcrInt '-AwsTimeout' $V; if ($n -lt 1) { Stop-Bcr 1 '-AwsTimeout must be a positive integer' }; $O.AwsTimeout = $n; break }
        'max-attempts' { $n = Assert-BcrInt '-MaxAttempts' $V; if ($n -lt 1) { Stop-Bcr 1 '-MaxAttempts must be a positive integer' }; $O.MaxAttempts = $n; break }
        'non-compliant-only' { $O.NcOnly = Test-BcrTrue $V; break }
        'fail-on-noncompliant' { $O.FailOnNc = Test-BcrTrue $V; break }
        'save-data' { $O.SaveData = Test-BcrTrue $V; break }
        'verbose' { $O.VerboseLog = Test-BcrTrue $V; break }
        'snapshot-price-per-gb' {
            if ($V -notmatch '^[0-9]+(\.[0-9]+)?$') { Stop-Bcr 1 "-SnapshotPricePerGb must be a number like 0.021 (got '$V')" }
            $O.SnapPrice = N ([double]::Parse($V, $script:Inv)); break
        }
        'manual-older-than' { $O.ManualOlder = Assert-BcrInt '-ManualOlderThan' $V; break }
        'replica-exempt-engines' { $O.ExemptEngines = Split-BcrList $V; break }
        'exceptions' { $O.ExcFile = Expand-BcrHome $V; break }
        'alert-email' { $O.AlertEmails = Split-BcrList $V; break }
        'alert-smtp-server' { $O.AlertSmtpServer = $V; break }
        'alert-smtp-port' { $n = Assert-BcrInt '-AlertSmtpPort' $V; if ($n -lt 1 -or $n -gt 65535) { Stop-Bcr 1 '-AlertSmtpPort must be 1-65535' }; $O.AlertSmtpPort = [int]$n; break }
        'alert-from' { $O.AlertFrom = $V; break }
        'alert-on' { $O.AlertOn = $V.ToLowerInvariant(); break }
        'alert-attach' { $O.AlertAttach = Test-BcrTrue $V; break }
        default { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------------------------- config file
# Import-BcrConfig: key = value lines (# comments and blank lines skipped; never executed). Same keys as the Bash
# --config file (long option names, - or _). "123456789012 = name" lines name accounts. Any bad line stops the run.
function Import-BcrConfig {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Stop-Bcr 1 "Config file not readable: $File" }
    $O = $script:O; $n = 0
    foreach ($raw in [System.IO.File]::ReadAllLines((Resolve-BcrPath $File))) {
        $n++; $line = $raw.TrimEnd("`r")
        if ($line -match '^\s*(#|$)') { continue }
        $m = [regex]::Match($line, '^\s*([0-9]{12})\s*=\s*(.*)$')
        if ($m.Success) {   # account name (display only): trailing # comment, control characters and quotes removed; max 64
            $key = $m.Groups[1].Value; $val = $m.Groups[2].Value
            $c = [regex]::Match($val, '^(.*[^\s])?\s+#.*$'); if ($c.Success) { $val = $c.Groups[1].Value }
            $val = ($val.TrimEnd() -replace '[\x01-\x1f]', '')
            $q = [regex]::Match($val, '^"(.*)"$'); if (-not $q.Success) { $q = [regex]::Match($val, "^'(.*)'$") }
            if ($q.Success) { $val = $q.Groups[1].Value }
            if ($val.Length -gt 64) { $val = $val.Substring(0, 64) }
            $O.AccountNames[$key] = $val; continue
        }
        $m = [regex]::Match($line, '^\s*([A-Za-z_-]+)\s*=\s*(.*)$')
        if (-not $m.Success) { Stop-Bcr 1 "Config ${File}:${n}: expected key=value" }
        $key = $m.Groups[1].Value; $val = $m.Groups[2].Value
        $q = [regex]::Match($val, '^"([^"]*)"'); if (-not $q.Success) { $q = [regex]::Match($val, "^'([^']*)'") }
        if ($q.Success) { $val = $q.Groups[1].Value }
        else { $c = [regex]::Match($val, '^(.*[^\s])?\s+#.*$'); if ($c.Success) { $val = $c.Groups[1].Value }; $val = $val.Trim() }
        if ($key.ToLowerInvariant() -match '^(aws[-_]access[-_]key[-_]id|aws[-_]secret[-_]access[-_]key|aws[-_]session[-_]token|secret|password)$') {
            Stop-Bcr 1 "Config ${File}:${n}: credentials are not accepted here; use an AWS CLI profile / SSO / role"
        }
        if (-not (Set-BcrOpt $key $val)) { Stop-Bcr 1 "Config ${File}:${n}: unknown key '$key'" }
    }
}

# ---------------------------------------------------------------------------------------------- validation
# Confirm-BcrOptions: the checks that need every setting (same rules and exit code 1 as the Bash tool)
function Confirm-BcrOptions {
    $O = $script:O
    foreach ($f in $O.Formats) { if (@('text', 'txt', 'csv', 'json', 'html') -notcontains $f.ToLowerInvariant()) { Stop-Bcr 1 "Unknown format '$f' (text,csv,json,html)" } }
    $seen = @{}; $O.Formats = @(foreach ($x in $O.Formats) { $f = $x.ToLowerInvariant(); if ($f -eq 'txt') { $f = 'text' }; if (-not $seen[$f]) { $seen[$f] = 1; $f } })
    if ($O.Formats.Count -eq 0) { $O.Formats = @(if ($O.Merge) { 'html' } else { 'text' }) }
    if (-not ($O.WeeklyMinDays -le $O.WeeklyMaxDays -and $O.WeeklyMaxDays -lt $O.MonthlyMinDays -and $O.MonthlyMinDays -le $O.MonthlyMaxDays)) {
        Stop-Bcr 1 "Need -WeeklyDays MIN <= MAX < -MonthlyDays MIN <= MAX (got weekly $($O.WeeklyMinDays)-$($O.WeeklyMaxDays), monthly $($O.MonthlyMinDays)-$($O.MonthlyMaxDays))"
    }
    if ($O.Merge) {
        if ($O.MergeArgs.Count -eq 0) { Stop-Bcr 1 '-Merge needs at least one FILE or DIR' }
        if ($O.Profiles.Count -or $O.Regions.Count -or $O.AllRegions) { Stop-Bcr 1 '-Merge works offline: do not combine it with -ProfileName / -Region / -AllRegions' }
        if ($O.SaveData) { Stop-Bcr 1 '-SaveData cannot be combined with -Merge' }
        if ($O.DryRun) { Stop-Bcr 1 '-DryRun cannot be combined with -Merge' }
    }
    if ($O.OutputDir -match '\.html?$') {   # -OutputDir report.html names the HTML file
        $O.OutFile = $O.OutputDir; $O.OutputDir = Split-Path -Parent $O.OutputDir; if (-not $O.OutputDir) { $O.OutputDir = '.' }
        if (-not $O.FormatsSet) { $O.Formats = @('html') }
        if ($O.Formats -notcontains 'html') { Stop-Bcr 1 "-OutputDir $($O.OutFile) names an HTML file; add html to -Format or give a directory" }
    }
    if ($O.Formats.Count -gt 1 -and -not $O.OutputDir) { Stop-Bcr 1 'Several formats need -OutputDir DIR' }
    if ($O.Prefix -cnotmatch '^[A-Za-z0-9._-]+$') { Stop-Bcr 1 '-Prefix may contain only letters, digits, . _ -' }
    if ($O.AllRegions -and $O.Regions.Count) { Stop-Bcr 1 'Use either -Region or -AllRegions, not both' }
    foreach ($x in $O.Regions) { if ($x -cnotmatch '^[a-z]{2}(-[a-z]+)+-[0-9]+$') { Stop-Bcr 1 "Invalid region: $x" } }
    foreach ($x in $O.Profiles) { if ($x -cnotmatch '^[A-Za-z0-9_.+@-]+$') { Stop-Bcr 1 "Invalid profile name: $x" } }
    if ($O.SaveDataFile -and $O.SaveDataFile -notmatch '\.json$') { Stop-Bcr 1 '-SaveDataFile must end in .json' }
    if (@('noncompliant', 'always') -notcontains $O.AlertOn) { Stop-Bcr 1 '-AlertOn must be noncompliant or always' }
    foreach ($x in $O.AlertEmails) { if ($x -notmatch '^[^\s@;|&$`<>]+@[^\s@;|&$`<>]+$') { Stop-Bcr 1 "Invalid -AlertEmail address: $x" } }
    if ($O.AlertEmails.Count -and -not $O.AlertSmtpServer) { Stop-Bcr 1 '-AlertEmail needs -AlertSmtpServer (SMTP relay host)' }
    if ($O.AlertTest -and -not $O.AlertEmails.Count) { Stop-Bcr 1 '-AlertTest needs -AlertEmail' }
    try { [void](Get-BcrTz $O.Tz 0) } catch { Stop-Bcr 1 "Unknown time zone: $($O.Tz)" }
    if ($O.LogFile) {
        $O.LogFile = Resolve-BcrPath $O.LogFile
        if (-not $O.DryRun) { try { [System.IO.File]::AppendAllText($O.LogFile, '') } catch { $lf = $O.LogFile; $O.LogFile = ''; Stop-Bcr 1 "Cannot write log file: $lf" } }
    }
}

# ---------------------------------------------------------------------------------------------- exceptions (v1.6.0 format)
# compliance_exceptions.conf: one entry per line "account_id | identifier | scope | expires | reason" (all five required;
# scope patch, backup or patch,backup; expires YYYY-MM-DD, the last valid UTC day). The same file works for the Bash tools.
# Strict: any bad line stops the run (exit 1) naming file:line. -Exceptions FILE, else compliance_exceptions.conf next to
# the script when present, else off. Returns $null (off) or a list of entries.
function Import-BcrExceptions {
    param([string]$File, [string]$DefaultDir)
    $f = $File
    if (-not $f) { $f = Join-Path $DefaultDir 'compliance_exceptions.conf'; if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null } }
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Stop-Bcr 1 "Exceptions file not readable: $f" }
    try { $lines = [System.IO.File]::ReadAllLines((Resolve-BcrPath $f)) } catch { Stop-Bcr 1 "Exceptions file not readable: $f" }
    $out = [System.Collections.Generic.List[object]]::new(); $seen = @{}; $n = 0
    foreach ($raw in $lines) {
        $n++; $line = $raw.TrimEnd("`r")
        if ($line -match '^\s*(#|$)') { continue }
        $p = $line.Split('|')
        if ($p.Count -lt 5) { Stop-Bcr 1 "Exceptions ${f}:${n}: expected 5 fields 'account_id | identifier | scope | expires | reason'" }
        $acct = $p[0].Trim(); $id = $p[1].Trim(); $scope = $p[2].Trim(); $exp = $p[3].Trim()
        $reason = (($p[4..($p.Count - 1)] -join '|') -replace '[\x01-\x1f]', ' ').Trim()
        if (-not ($acct -and $id -and $scope -and $exp -and $reason)) { Stop-Bcr 1 "Exceptions ${f}:${n}: missing field (all of account_id, identifier, scope, expires, reason are required)" }
        if ($acct -notmatch '^[0-9]{12}$') { Stop-Bcr 1 "Exceptions ${f}:${n}: account_id must be 12 digits (got '$acct')" }
        if ($id -cnotmatch '^[A-Za-z][A-Za-z0-9-]{0,62}$') { Stop-Bcr 1 "Exceptions ${f}:${n}: identifier '$id' is not a DB instance / cluster identifier (letters, digits, hyphens; no wildcards)" }
        $sc = ($scope.ToLowerInvariant() -replace '\s', '')
        $parts = @($sc.Split(',')); $ok = [System.Collections.Generic.List[string]]::new()
        if ($sc -eq '') { Stop-Bcr 1 "Exceptions ${f}:${n}: scope must be patch, backup or patch,backup" }
        foreach ($s in $parts) {
            if ($s -ne 'patch' -and $s -ne 'backup') { Stop-Bcr 1 "Exceptions ${f}:${n}: scope must be patch, backup or patch,backup (got '$sc')" }
            if ($ok.Contains($s)) { Stop-Bcr 1 "Exceptions ${f}:${n}: scope lists '$s' twice" }
            $ok.Add($s)
        }
        $dm = [regex]::Match($exp, '^([0-9]{4})-([0-9]{2})-([0-9]{2})$')
        if (-not $dm.Success) { Stop-Bcr 1 "Exceptions ${f}:${n}: expires must be a date YYYY-MM-DD (got '$exp'); an expiry date is mandatory" }
        $y = [int]$dm.Groups[1].Value; $mo = [int]$dm.Groups[2].Value; $d = [int]$dm.Groups[3].Value
        if (-not ($mo -ge 1 -and $mo -le 12 -and $y -ge 2000 -and $d -ge 1 -and $d -le [datetime]::DaysInMonth($y, $mo))) { Stop-Bcr 1 "Exceptions ${f}:${n}: expires '$exp' is not a valid date" }
        foreach ($s in $ok) {
            $k = "$acct|$($id.ToLowerInvariant())|$s"
            if ($seen.ContainsKey($k)) { Stop-Bcr 1 "Exceptions ${f}:${n}: duplicate entry for $acct $id ($s), already on line $($seen[$k])" }
            $seen[$k] = $n
        }
        $out.Add([ordered]@{ line = $n; account = $acct; identifier = $id; scopes = $ok.ToArray(); expires = $exp; reason = $reason })
    }
    $script:ExcPath = $f
    return , $out.ToArray()
}
