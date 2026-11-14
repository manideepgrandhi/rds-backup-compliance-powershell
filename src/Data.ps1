# src/Data.ps1 - -SaveData (raw collected data per account, no ARNs) and -Merge (offline, zero AWS calls).
# Data document: { schema, schema_version, tool_version, collected_epoch, collected_at, accounts: [...], regions: [...],
#                  resources: [... snapshots ...], orphans: [...] }. Compliance is NOT stored: it is evaluated when a
# report is built, so a merge always applies today's rules and the current exceptions file.

$script:DataSchema = 'rds_backup_compliance_ps_data'
$script:DataSchemaVersion = 1

# Write-BcrFile: write UTF-8 (no BOM) text; exit 4 when the file cannot be written
function Write-BcrFile {
    param([string]$Path, [string]$Text)
    try {
        $full = Resolve-BcrPath $Path
        [System.IO.File]::WriteAllText($full, $Text, [System.Text.UTF8Encoding]::new($false))
    }
    catch { Stop-Bcr 4 "Cannot write $Path" }
    $script:Run.Written.Add($full)
}

# Save-BcrData: one file per account: rds_backup_<ACCOUNT>_<YYYYMMDD>.json (or -SaveDataFile; _<account> added for several)
function Save-BcrData {
    param($Docs)
    $O = $script:O
    $day = [DateTimeOffset]::FromUnixTimeSeconds($script:Run.Now).UtcDateTime.ToString('yyyyMMdd', $script:Inv)
    foreach ($d in $Docs) {
        $a = $d.accounts[0].account
        $dir = if ($O.OutputDir) { $O.OutputDir } else { '.' }
        $target = Join-Path $dir "rds_backup_${a}_$day.json"
        if ($O.SaveDataFile) { $target = $O.SaveDataFile; if (@($Docs).Count -gt 1) { $target = ($O.SaveDataFile -replace '\.json$', '') + "_$a.json" } }
        $sd = Split-Path -Parent $target; if ($sd -and -not (Test-Path -LiteralPath $sd)) { try { [void](New-Item -ItemType Directory -Force -Path $sd) } catch { Stop-Bcr 4 "Cannot create $sd" } }
        Write-BcrFile $target ((ConvertTo-BcrJson $d) + "`n")
    }
}

# Read-BcrDataFile: JSON object with this tool's -SaveData schema name and 12-digit account ids (they end up in file
# names), else $null. Everything else in the file is only ever shown escaped.
function Read-BcrDataFile {
    param([string]$Path)
    try { $d = Read-BcrJson ([System.IO.File]::ReadAllText((Resolve-BcrPath $Path))) } catch { return $null }
    if (-not ($d -is [System.Collections.IDictionary] -and $d['schema'] -eq $script:DataSchema)) { return $null }
    foreach ($a in @($d['accounts'])) { if (-not ($a -is [System.Collections.IDictionary]) -or [string]$a['account'] -notmatch '^[0-9]{12}$') { return $null } }
    return $d
}

# Invoke-BcrMerge: -Merge FILE|DIR ... -> one data document. Same account in several files: the newer collection wins
# (same time: the later file). Older collections are logged and left out.
function Invoke-BcrMerge {
    $O = $script:O
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $O.MergeArgs) {
        if (Test-Path -LiteralPath $a -PathType Container) {
            $found = 0
            foreach ($f in (Get-ChildItem -LiteralPath $a -Filter '*.json' -File | Sort-Object Name)) {
                $d = Read-BcrDataFile $f.FullName
                if ($d) { $files.Add(@{ path = $f.FullName; d = $d }); $found++ } else { Write-BcrWarn "skipping $($f.FullName) (not a -SaveData file)" }
            }
            if (-not $found) { Stop-Bcr 3 "No -SaveData files in directory: $a" }
        }
        elseif (Test-Path -LiteralPath $a -PathType Leaf) {
            $d = Read-BcrDataFile $a
            if (-not $d) { Stop-Bcr 3 "Not a -SaveData file of this tool (or unreadable JSON): $a" }
            $files.Add(@{ path = $a; d = $d })
        }
        else { Stop-Bcr 3 "Merge input not found: $a" }
    }
    $all = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $files.Count; $i++) { foreach ($acc in @($files[$i].d['accounts'])) { $all.Add(@{ acc = $acc; i = $i }) } }
    $keep = @{}
    foreach ($x in $all) {
        $a = [string]$x.acc['account']; $k = $keep[$a]
        if (-not $k -or [double]$x.acc['collected_epoch'] -ge [double]$k.acc['collected_epoch']) { $keep[$a] = $x }
    }
    $kept = { param($a, $i) $k = $keep[[string]$a]; return ($k -and $k.i -eq $i) }
    foreach ($x in $all) { if (-not (& $kept $x.acc['account'] $x.i)) { Write-BcrWarn "account $($x.acc['account']): $($files[$x.i].path) (collected $(Format-BcrUtc ([long]$x.acc['collected_epoch']))) ignored, a newer collection wins" } }
    $accounts = @(foreach ($x in (Sort-JqBy @($keep.Values) { $_.acc['account'] })) { $x.acc })
    $regions = [System.Collections.Generic.List[object]]::new(); $resources = [System.Collections.Generic.List[object]]::new(); $orphans = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $d = $files[$i].d
        foreach ($r in @($d['regions'])) { if ($r -and (& $kept $r['account'] $i)) { $regions.Add($r) } }
        foreach ($r in @($d['resources'])) { if ($r -and (& $kept $r['account_id'] $i)) { $resources.Add($r) } }
        foreach ($r in @($d['orphans'])) { if ($r -and (& $kept $r['account_id'] $i)) { $orphans.Add($r) } }
    }
    Write-BcrInfo "merged $($files.Count) file(s): $((@($accounts | ForEach-Object { $_['account'] })) -join ', ')"
    return [ordered]@{ schema = $script:DataSchema; schema_version = $script:DataSchemaVersion
        collected_epoch = $(if ($accounts.Count) { (@($accounts | ForEach-Object { [double]$_['collected_epoch'] }) | Measure-Object -Maximum).Maximum } else { $null })
        accounts = $accounts; regions = $regions.ToArray(); resources = $resources.ToArray(); orphans = $orphans.ToArray() }
}
