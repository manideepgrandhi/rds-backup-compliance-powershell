# Changelog

Plain-English features for each release of the PowerShell port. The format follows the Bash tool's
[CHANGELOG.md](https://github.com/manideepgrandhi/rds-backup-compliance/blob/main/CHANGELOG.md).
The What's new page is built from this file.

## 1.0.0

_Released 2026-11-14._

First version: a PowerShell 7 port of `rds_backup_compliance_report.sh` v1.6.0 (Bash repo
[rds-backup-compliance](https://github.com/manideepgrandhi/rds-backup-compliance)).

- `Invoke-RdsBackupCompliance.ps1` writes a read-only backup compliance report covering Aurora
  clusters and standalone RDS instances, across accounts and regions
- Daily (RDS automated), weekly, monthly and optional yearly (AWS Backup) checks with scheduled-date
  tolerance, "so far" counts for new resources and the missing dates in the gaps
- Strict retention (daily 7, weekly 30, monthly 365 days, each ±1), excess backups and backups held
  past retention; primary / secondary / replica roles and `-ReplicaExemptEngines`; DocumentDB and
  Neptune left out
- Compliance exceptions file (same `account_id|identifier|scope|expires|reason` format as the other
  compliance tools), with expiry, expiring-in-14-days flags, an Exception column and filter
- Manual snapshot audit (`-ManualOlderThan`) and orphaned manual snapshots with Shared and
  Unverified handling plus a monthly cost estimate
- Text, CSV, JSON and an offline single-file HTML page (Compliance and Backups tabs and filters).
  Four CSV files: the main report, backups, orphaned snapshots and old manual snapshots. Times in
  UTC and IST (`-Tz` changes the second zone). The HTML page's Export CSV button writes the same
  main report file
- Several accounts with `-SaveData` and an offline `-Merge`; compliance is worked out again at merge
  time. Saved-data files cannot be mixed with the Bash tool in one merge
- Regions scanned in parallel (`-Parallel`, default 4); optional e-mail alert through an SMTP relay
  (`-AlertEmail`); `-ConfigFile` with the Bash tool's key names; `-FailOnNonCompliant` and the same
  exit codes
- Runs on Windows, Linux and macOS; needs PowerShell 7.2+ and AWS CLI v2 (no jq). Pester tests with
  a mock AWS CLI and headless browser checks, including the CSV export and formula-injection prefix.
  CI runs on Windows and Linux
