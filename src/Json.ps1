# src/Json.ps1 - JSON in / out and the few jq behaviours the report relies on:
#   * value ordering for sort / unique (null < false < true < numbers < strings < arrays < objects; strings ordinal)
#   * stable multi-key sort (jq sort_by)
#   * number text ("7", "5.5", never "7.0"), the same text jq prints
# AWS output is read with ConvertFrom-Json -AsHashtable. On PowerShell 7.5+ date strings stay strings (-DateKind String);
# on 7.2 - 7.4 they may arrive as [datetime], which ConvertTo-BcrEpoch (Time.ps1) accepts too.

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:JsonDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')

# Read-BcrJson: JSON text -> hashtables / object[] / scalars. Throws on invalid JSON.
function Read-BcrJson {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'empty JSON document' }
    if ($script:JsonDateKind) { return (ConvertFrom-Json -InputObject $Text -AsHashtable -NoEnumerate -DateKind String -Depth 200) }
    return (ConvertFrom-Json -InputObject $Text -AsHashtable -NoEnumerate -Depth 200)
}

# ConvertTo-BcrJson: compact (HTML payload, data files) or indented (-F json) JSON; key order is kept
function ConvertTo-BcrJson {
    param([AllowNull()]$Value, [switch]$Compress)
    return (ConvertTo-Json -InputObject $Value -Depth 60 -Compress:$Compress -EscapeHandling Default)
}

# Test-BcrNumber: a JSON number (any .NET numeric type, not bool)
function Test-BcrNumber {
    param([AllowNull()]$V)
    return ($V -is [long] -or $V -is [int] -or $V -is [double] -or $V -is [decimal] -or $V -is [single] -or $V -is [System.Numerics.BigInteger] -or $V -is [short] -or $V -is [byte])
}

# N: a computed number in its simplest form (whole doubles become [long], so JSON / text never shows "7.0")
function N {
    param([AllowNull()]$V)
    if ($null -eq $V) { return $null }
    $d = [double]$V
    if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e15) { return [long]$d }
    return $d
}

# J: jq string interpolation of one value: null -> "null", true / false, numbers like jq, strings as they are
function J {
    param([AllowNull()]$V)
    if ($null -eq $V) { return 'null' }
    if ($V -is [bool]) { if ($V) { return 'true' } else { return 'false' } }
    if ($V -is [string]) { return $V }
    if (Test-BcrNumber $V) {
        $d = [double]$V
        if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e17) { return ([long]$d).ToString($script:Inv) }
        return $d.ToString('R', $script:Inv)
    }
    return (ConvertTo-BcrJson $V -Compress)
}

# Round-Jq: jq round (half away from zero)
function Round-Jq { param([double]$V) return [Math]::Round($V, [MidpointRounding]::AwayFromZero) }
# R1: round to one decimal place (jq r1)
function R1 { param([double]$V) return (N ((Round-Jq ($V * 10)) / 10)) }

# Get-JqRank: jq type order
function Get-JqRank {
    param([AllowNull()]$V)
    if ($null -eq $V) { return 0 }
    if ($V -is [bool]) { if ($V) { return 2 } else { return 1 } }
    if (Test-BcrNumber $V) { return 3 }
    if ($V -is [string]) { return 4 }
    if ($V -is [System.Collections.IDictionary]) { return 6 }
    return 5
}
# Compare-Jq: -1 / 0 / 1 in jq order (arrays element by element; objects are not compared by content here)
function Compare-Jq {
    param([AllowNull()]$A, [AllowNull()]$B)
    $ra = Get-JqRank $A; $rb = Get-JqRank $B
    if ($ra -ne $rb) { return [Math]::Sign($ra - $rb) }
    switch ($ra) {
        3 { return [Math]::Sign(([double]$A).CompareTo([double]$B)) }
        4 { return [Math]::Sign([string]::CompareOrdinal($A, $B)) }
        5 {
            $la = @($A); $lb = @($B)
            for ($i = 0; $i -lt [Math]::Min($la.Count, $lb.Count); $i++) { $c = Compare-Jq $la[$i] $lb[$i]; if ($c -ne 0) { return $c } }
            return [Math]::Sign($la.Count - $lb.Count)
        }
        default { return 0 }
    }
}
# Sort-JqBy: stable sort (jq sort_by) of $Items by the key list $Key returns (scriptblock, $_ = item)
function Sort-JqBy {
    param([AllowNull()][object[]]$Items, [scriptblock]$Key)
    $list = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($it in $Items) {
        $vars = [System.Collections.Generic.List[psvariable]]::new(); $vars.Add([psvariable]::new('_', $it))
        $k = [object[]]@(foreach ($x in $Key.InvokeWithContext($null, $vars)) { if ($null -eq $x) { $null } else { $x.PSObject.BaseObject } })
        $list.Add([pscustomobject]@{ k = $k; i = $i; v = $it }); $i++
    }
    $arr = $list.ToArray()
    $cmp = [System.Comparison[object]] { param($x, $y) $c = Compare-Jq $x.k $y.k; if ($c -ne 0) { return $c }; return $x.i.CompareTo($y.i) }
    [Array]::Sort($arr, $cmp)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $arr) { $out.Add($e.v) }
    return $out.ToArray()   # unrolled: callers wrap in @()
}
# Get-JqUnique: sorted distinct values (jq unique) of scalars
function Get-JqUnique {
    param([AllowNull()][object[]]$Items)
    $s = @(Sort-JqBy @($Items) { , $_ })
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $s) { if ($out.Count -eq 0 -or (Compare-Jq $out[$out.Count - 1] $v) -ne 0) { $out.Add($v) } }
    return $out.ToArray()   # unrolled: callers wrap in @()
}
# Get-Or: jq "a // b" (b when a is null or false)
function Get-Or { param([AllowNull()]$A, [AllowNull()]$B) if ($null -eq $A -or ($A -is [bool] -and -not $A)) { return $B } return $A }
# Get-At: jq array index (negative = from the end, out of range = null)
function Get-At {
    param([AllowNull()][object[]]$Arr, [long]$I)
    $a = @($Arr); if ($I -lt 0) { $I = $a.Count + $I }
    if ($I -lt 0 -or $I -ge $a.Count) { return $null }
    return $a[$I]
}
