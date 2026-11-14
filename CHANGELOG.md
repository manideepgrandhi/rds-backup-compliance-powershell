# Changelog

Plain-English features for each release.

## 1.0.0 (unreleased)
- First PowerShell 7 version of rds-backup-compliance (Bash v1.6.0): same rules, statuses, CSV columns and HTML page
- Daily (RDS automated), weekly, monthly and optional yearly (AWS Backup) checks with tolerance, "so far" counts for
  new resources and the missing dates in the gaps
- Strict retention, excess backups and over-retention highlights; primary / secondary / replica roles and
  `-ReplicaExemptEngines`; DocumentDB and Neptune left out
- Compliance exceptions file (same format as the other compliance tools), with expiry, flags and counts
- Manual snapshot audit (`-ManualOlderThan`) and orphaned manual snapshots with a monthly cost estimate
- Text, CSV, JSON and HTML reports; CSV files for compliance, backups, orphaned snapshots and old manual snapshots
- Several accounts with `-SaveData` and an offline `-Merge`; regions scanned in parallel (`-Parallel`)
- Optional e-mail alert through an SMTP relay; config file with the Bash tool's key names
- Runs on Windows, Linux and macOS; Pester tests with a mock AWS CLI and headless browser checks on both systems
