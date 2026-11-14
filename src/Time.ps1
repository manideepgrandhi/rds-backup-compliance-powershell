# src/Time.ps1 - the run clock, UTC / second-zone formatting and the UTC day arithmetic the schedules use.
# Schedules work on UTC day numbers (days since 1970-01-01); weekday 0 = Sunday .. 6 = Saturday.

$script:MON = @('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')
$script:DOW = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
$script:WDNAME = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')

# Get-BcrNow: epoch seconds; RDS_BCR_NOW freezes the clock (tests)
function Get-BcrNow {
    if ($env:RDS_BCR_NOW -match '^[0-9]+$') { return [long]$env:RDS_BCR_NOW }
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# ConvertTo-BcrEpoch: AWS timestamp -> epoch seconds (whole). Accepts "2026-10-31T05:00:00.123+05:30", "...Z", no zone (= UTC),
# numbers (already epoch) and [datetime] / [DateTimeOffset] (ConvertFrom-Json on PowerShell < 7.5). Unreadable -> $null.
function ConvertTo-BcrEpoch {
    param([AllowNull()]$V)
    if ($null -eq $V -or ($V -is [string] -and $V -eq '')) { return $null }
    if (Test-BcrNumber $V) { return [long][Math]::Floor([double]$V) }
    if ($V -is [DateTimeOffset]) { return $V.ToUnixTimeSeconds() }
    if ($V -is [datetime]) {
        $u = if ($V.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($V, [DateTimeKind]::Utc) } else { $V.ToUniversalTime() }
        return [DateTimeOffset]::new($u).ToUnixTimeSeconds()
    }
    $m = [regex]::Match([string]$V, '^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})T(?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$')
    if (-not $m.Success) { return $null }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($m.Groups['d'].Value + 'T' + $m.Groups['t'].Value, 'yyyy-MM-ddTHH:mm:ss', $script:Inv,
            ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal), [ref]$d)) { return $null }
    $e = [DateTimeOffset]::new([datetime]::SpecifyKind($d, [DateTimeKind]::Utc)).ToUnixTimeSeconds()
    $z = $m.Groups['z'].Value
    if ($z -and $z -ne 'Z') {
        $o = [regex]::Match($z, '([+-])([0-9]{2}):?([0-9]{2})')
        $sec = [long]$o.Groups[2].Value * 3600 + [long]$o.Groups[3].Value * 60
        if ($o.Groups[1].Value -eq '+') { $e -= $sec } else { $e += $sec }
    }
    return $e
}

# Format-BcrUtc: epoch -> "2026-10-24 05:00 UTC" ("" for null)
function Format-BcrUtc {
    param([AllowNull()]$E)
    if ($null -eq $E) { return '' }
    return [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor([double]$E)).UtcDateTime.ToString('yyyy-MM-dd HH:mm', $script:Inv) + ' UTC'
}
# Format-BcrLoc: epoch -> the same in the second zone (-Tz; fixed offset taken at the start of the run, like the Bash tool)
function Format-BcrLoc {
    param([AllowNull()]$E)
    if ($null -eq $E) { return '' }
    $t = [long][Math]::Floor([double]$E + $script:Cfg.tz_offset)
    return [DateTimeOffset]::FromUnixTimeSeconds($t).UtcDateTime.ToString('yyyy-MM-dd HH:mm', $script:Inv) + ' ' + $script:Cfg.tz_label
}

# UTC day helpers (day number d = floor(epoch / 86400))
function Get-Day { param($E) return [long][Math]::Floor([Math]::Floor([double]$E) / 86400) }
function Get-Dow { param([long]$D) return [int]((($D + 4) % 7 + 7) % 7) }
function Get-DayDate { param([long]$D) return [DateTimeOffset]::FromUnixTimeSeconds($D * 86400).UtcDateTime }
function P2 { param([int]$V) if ($V -lt 10) { return "0$V" } return "$V" }
# Sat 17 Oct
function Format-DShort { param([long]$D) $g = Get-DayDate $D; return "$($script:DOW[(Get-Dow $D)]) $(P2 $g.Day) $($script:MON[$g.Month - 1])" }
# 17 Oct 2026
function Format-DLong { param([long]$D) $g = Get-DayDate $D; return "$(P2 $g.Day) $($script:MON[$g.Month - 1]) $($g.Year)" }
# 2026-10-17
function Format-DIso { param([long]$D) $g = Get-DayDate $D; return "$($g.Year)-$(P2 $g.Month)-$(P2 $g.Day)" }
# Oct 2026
function Format-MLabel { param([long]$D) $g = Get-DayDate $D; return "$($script:MON[$g.Month - 1]) $($g.Year)" }
# 2026-10-24 Sat (CSV dates that Excel keeps as text)
function Format-Dwk { param([long]$D) return "$(Format-DIso $D) $($script:DOW[(Get-Dow $D)])" }
# Get-Year: UTC year of an epoch
function Get-Year { param($E) return [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor([double]$E)).UtcDateTime.Year }
# Get-MonthIndex: year * 12 + month (0-11) of a day number
function Get-MonthIndex { param([long]$D) $g = Get-DayDate $D; return [long]($g.Year * 12 + $g.Month - 1) }
# Get-FirstDow: day number of the first <weekday> of month index y*12+m
function Get-FirstDow {
    param([long]$Mi, [int]$Wd)
    $y = [long][Math]::Floor($Mi / 12); $m = $Mi - $y * 12
    $d1 = [long]([DateTimeOffset]::new([datetime]::new([int]$y, [int]$m + 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).ToUnixTimeSeconds() / 86400)
    return $d1 + (($Wd - (Get-Dow $d1) + 7) % 7)
}

# ---------------------------------------------------------------------------------------------- second time zone
$script:TzAbbr = @{   # used where `date` is not available (Windows): zone -> (standard, daylight)
    'Asia/Kolkata' = @('IST', 'IST'); 'Asia/Calcutta' = @('IST', 'IST'); 'India Standard Time' = @('IST', 'IST'); 'UTC' = @('UTC', 'UTC'); 'Etc/UTC' = @('UTC', 'UTC')
    'America/New_York' = @('EST', 'EDT'); 'America/Chicago' = @('CST', 'CDT'); 'America/Denver' = @('MST', 'MDT')
    'America/Los_Angeles' = @('PST', 'PDT'); 'Europe/London' = @('GMT', 'BST'); 'Europe/Dublin' = @('GMT', 'IST')
    'Europe/Berlin' = @('CET', 'CEST'); 'Europe/Paris' = @('CET', 'CEST'); 'Europe/Amsterdam' = @('CET', 'CEST')
    'Asia/Tokyo' = @('JST', 'JST'); 'Australia/Sydney' = @('AEST', 'AEDT'); 'Asia/Seoul' = @('KST', 'KST'); 'Asia/Singapore' = @('+08', '+08')
}
# Get-BcrTz: @{ offset (seconds, at $Now); label } for -Tz. IST / Asia/Kolkata / Asia/Calcutta -> IST, +05:30 (like the Bash tool).
# Throws for an unknown zone.
function Get-BcrTz {
    param([string]$Tz, [long]$Now)
    if ($Tz -in 'Asia/Kolkata', 'Asia/Calcutta', 'IST', 'India Standard Time') { return @{ offset = 19800; label = 'IST' } }
    if ($Tz -in 'UTC', 'Etc/UTC', 'GMT') { return @{ offset = 0; label = 'UTC' } }
    $z = [System.TimeZoneInfo]::FindSystemTimeZoneById($Tz)
    $dto = [DateTimeOffset]::FromUnixTimeSeconds($Now)
    $off = [long]$z.GetUtcOffset($dto).TotalSeconds
    $label = $null
    if ($script:TzAbbr.ContainsKey($Tz)) { $label = $script:TzAbbr[$Tz][[int]$z.IsDaylightSavingTime($dto)] }
    elseif (-not $IsWindows -and (Get-Command date -CommandType Application -ErrorAction SilentlyContinue)) {
        $prev = $env:TZ
        try { $env:TZ = $Tz; $a = & date -d "@$Now" '+%Z' 2>$null; if ($LASTEXITCODE -eq 0 -and $a) { $label = ([string]$a).Trim() } }
        catch { $label = $null } finally { $env:TZ = $prev }
    }
    if (-not $label) {
        $mins = [Math]::Abs($off / 60); $sign = if ($off -lt 0) { '-' } else { '+' }
        $label = $sign + (P2 ([Math]::Floor($mins / 60))) + $(if ($mins % 60) { P2 ($mins % 60) } else { '' })
    }
    if ($label -match '^[+-]') { $label = "UTC$label" }
    return @{ offset = $off; label = $label }
}
