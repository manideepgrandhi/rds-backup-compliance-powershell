# Comparison with the Bash tool

`Invoke-RdsBackupCompliance.ps1` 1.0.0 is a port of `rds_backup_compliance_report.sh` v1.6.0. Rules, statuses,
CSV columns, JSON report fields and the HTML page are the same: `tests/Parity.Tests.ps1` runs both tools on the same
mock AWS CLI with the same frozen clock and requires identical output files (only the version string may differ).

## Same

| Area | Notes |
|---|---|
| Checks | Daily / weekly / monthly / yearly, tolerance, "so far", missing dates, strict retention, excess, over-retention |
| Roles | primary, secondary, replica (daily only), `-ReplicaExemptEngines`; DocumentDB and Neptune excluded |
| Statuses | COMPLIANT, NON-COMPLIANT, NOT YET DUE, UNKNOWN, COMPLIANT (EXCEPTION) |
| Exceptions | Same file format, same validation, flags, counts and log lines |
| CSV | Main, `_backups.csv`, `_orphaned_snapshots.csv`, `_manual_older_than_<N>d.csv`: same columns, quoting, Excel safety |
| HTML | Same tabs, filters, links and CSV export; `assets/backup_page.js` is the Bash file unchanged |
| File names | `<prefix>_<account>_<UTC stamp>.<ext>`, `merged_<N>_accounts` |
| Times | UTC plus a second zone (IST default) |
| Exit codes | 0, 1, 2, 3, 4, 5 (`-FailOnNonCompliant`) |
| AWS calls | Same read-only list; `-DryRun` |
| Config | Same `key = value` names, account-name lines, credentials refused |

## Parameter names

| Bash | PowerShell |
|---|---|
| `--profile p1,p2` | `-ProfileName p1,p2` (alias `-Profile`) |
| `--region` / `--all-regions` | `-Region` / `-AllRegions` |
| `--weekly`, `--monthly-rule`, `--tolerance-days` ... | `-Weekly`, `-MonthlyRule`, `-ToleranceDays` ... (each `--a-b` is `-AB`) |
| `--format`, `--output` | `-Format`, `-OutputDir` |
| `--manual-older-than N` | `-ManualOlderThan N` |
| `--save-data [FILE]` | `-SaveData` / `-SaveDataFile FILE` |
| `--merge F...` | `-Merge F,...` |
| `--parallel N` | `-Parallel N` |
| `--config FILE` | `-ConfigFile FILE` |
| `-v`, `-h`, `--version` | `-Verbose`, `-Help`, `-Version` |
| (none) | `-AlertEmail`, `-AlertSmtpServer`, `-AlertSmtpPort`, `-AlertFrom`, `-AlertOn`, `-AlertAttach`, `-AlertTest` |

## Differences

| Area | Bash | PowerShell |
|---|---|---|
| Requirements | bash, jq, AWS CLI v2 | PowerShell 7.2+, AWS CLI v2 (no jq) |
| `-SaveData` files | Bash data format | Own format (`rds_backup_compliance_ps_data`); the two tools cannot merge each other's files |
| Parallel scans | Background shell jobs | `ForEach-Object -Parallel` runspaces; same deterministic report |
| E-mail alert | None | Optional SMTP alert (`-Alert*`), as in rds-patch-compliance-powershell |
| AWS back end | AWS CLI | AWS CLI only (no AWS.Tools back end, unlike rds-patch-compliance-powershell) |
| HTML `<title>` | Account name not escaped | Escaped (a tampered data file can't inject markup) |
| Error text | Bash wording | Same meaning; parameter names in PowerShell form (`-WeeklyDays`) |

The browser test scripts in `tests/browser` are the Bash repo's, with two test-only fixes (account filter picks the
account by number; the all-mode link check picks a resource that has backups) and Windows-safe `file://` URLs.
