# rds-backup-compliance-powershell

`Invoke-RdsBackupCompliance.ps1` checks whether Aurora clusters and standalone RDS instances keep the backups the
policy asks for. It is the PowerShell 7 version of
[rds-backup-compliance](https://github.com/manideepgrandhi/rds-backup-compliance) (Bash v1.6.0): the same rules,
statuses, CSV columns and HTML page, on Windows, Linux and macOS. It makes only read-only AWS calls through the
AWS CLI v2.

All account numbers and names in this repository are fake examples.

Release history: [What's new](https://manideepgrandhi.github.io/rds-backup-compliance-powershell/) · also in [CHANGELOG.md](CHANGELOG.md).

## Contents

- [Requirements](#requirements) · [Install](#install) · [Quick start](#quick-start)
- [Policy](#policy) · [Status](#status) · [Outputs](#outputs) · [CSV files](#csv-files)
- [Orphaned manual snapshots](#orphaned-manual-snapshots) · [Several accounts](#several-accounts--savedata-then--merge)
- [Parallel regions](#scanning-regions-in-parallel) · [Compliance exceptions](#compliance-exceptions)
- [Alerts](#e-mail-alert) · [Parameters](#parameters) · [Configuration file](#configuration-file)
- [Exit codes](#exit-codes) · [Permissions](#permissions-read-only) · [Limitations](#limitations) · [Tests](#tests)
- Also: [EXAMPLES.md](EXAMPLES.md), [docs/JUMP-BOX-SETUP.md](docs/JUMP-BOX-SETUP.md),
  [docs/COMPARISON.md](docs/COMPARISON.md), [CHANGELOG.md](CHANGELOG.md)

## Requirements

- PowerShell 7.2 or later (`pwsh`). Windows PowerShell 5.1 is not supported.
- AWS CLI v2 on `PATH`, with a profile, SSO session or instance role that has the [read-only permissions](#permissions-read-only).
- Nothing else: no jq, no Bash, no extra modules.

## Install

```powershell
git clone https://github.com/manideepgrandhi/rds-backup-compliance-powershell.git
cd rds-backup-compliance-powershell
pwsh ./Invoke-RdsBackupCompliance.ps1 -Version
```

Or download the repository ZIP from GitHub and extract it. The tool is `Invoke-RdsBackupCompliance.ps1` plus the
`src/` and `assets/` folders next to it.

## Quick start

```powershell
# one account, two regions, text report on the console
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Region us-east-1,us-west-2

# every enabled region, HTML + CSV files, manual snapshot audit, raw data for a later merge
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Format html,csv -OutputDir ./reports -ManualOlderThan 90 -SaveData
```

Sample console output (mock fleet, fake account; times are the box clock in the log, UTC in the report):

```text
PS> ./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Region us-east-1,us-west-2,eu-west-1 -Format html,csv -OutputDir ./reports -ManualOlderThan 90
2026-11-14 09:57:54 [INFO] Exceptions file ./compliance_exceptions.conf: 3 entries
2026-11-14 09:57:54 [INFO] account 111111111111 (profile prod): 3 region(s)
2026-11-14 09:57:54 [INFO] 111111111111: scanning 3 regions, up to 4 at a time
2026-11-14 09:57:55 [INFO] [2/3] us-west-2: 2 clusters, 0 instances, 8 snapshots, 0 recovery points, 3 without source (0s)
2026-11-14 09:57:55 [INFO] [1/3] us-east-1: 3 clusters, 3 instances, 59 snapshots, 78 recovery points, 4 without source (0s)
2026-11-14 09:57:55 [INFO] 111111111111: 3 regions scanned, 1 empty: eu-west-1
2026-11-14 09:57:55 [INFO] AWS calls: 22 (0 failed)
2026-11-14 09:57:56 [INFO] manual snapshots older than 90 days: 7
2026-11-14 09:57:56 [INFO] resources: 8, non-compliant: 3
2026-11-14 09:57:56 [WARN] Exception compliance_exceptions.conf:24 (222222222222 dev-docdb) matched no server in this report
2026-11-14 09:57:56 [INFO] Exceptions (backup): 1 applied (counted as COMPLIANT), 0 expiring soon or no longer needed, 0 expired, 1 unmatched
2026-11-14 09:57:56 [INFO] 3 orphaned snapshots, 800 GB, ~$17/month (estimate)
Output (5 files):
  ./reports/rds_backup_compliance_111111111111_20261114_100000.html
  ./reports/rds_backup_compliance_111111111111_20261114_100000.csv
  ./reports/rds_backup_compliance_111111111111_20261114_100000_backups.csv
  ./reports/rds_backup_compliance_111111111111_20261114_100000_orphaned_snapshots.csv
  ./reports/rds_backup_compliance_111111111111_20261114_100000_manual_older_than_90d.csv
```

Text report (start of [samples/sample_111111111111_20261114_100000.txt](samples/sample_111111111111_20261114_100000.txt), columns are tab-separated):

```text
RDS backup compliance - account prod-core (111111111111)
Generated 2026-11-14 10:00 UTC / 2026-11-14 15:30 IST
Compliance: 50% (3 of 6), 2 not yet due not counted
Resources 8: compliant 3 (incl. 1 exceptions), non-compliant 3, not yet due 2, unknown 0

ACCOUNT                   REGION     IDENTIFIER            TYPE      ROLE     AGE_DAYS  DAILY                  WEEKLY                    STATUS
prod-core (111111111111)  us-east-1  billing-aurora-mysql  cluster   none     800       7/7                    4/5 · missing Sat 07 Nov  NON-COMPLIANT
prod-core (111111111111)  us-east-1  fresh-pg              instance  none     5         5/5 so far (target 7)  1/1 so far (target 5)     NOT YET DUE
prod-core (111111111111)  us-west-2  orders-dr-pg15        cluster   secondary 600      7/7                    N/A                       COMPLIANT
prod-core (111111111111)  us-east-1  reports-pg            instance  none     900       3/7 · missing Sun 08 Nov, ...                      COMPLIANT (EXCEPTION)
```

All sample files (every output format, fake data): [samples/](samples/).

## Policy

The default rules: RDS automated backups daily (7-day retention), AWS Backup every Saturday (kept about a month) and
on the first Sunday of each month (kept a year). There are no yearly backups, so the yearly check is off.

| Check | Source | Default rule | Applies to |
|---|---|---|---|
| Daily | RDS automated backups | Retention ≥ 7 days, an automated snapshot on each of the last 7 UTC days, the newest ≤ 26 h old | Every resource |
| Weekly | AWS Backup | A recovery point for every Saturday in the last 30 days (`-Weekly auto`), or the last N Saturdays (`-Weekly N`) | Primary clusters, non-global clusters, standalone instances |
| Monthly | AWS Backup | A recovery point for the first Sunday of each of the last 12 months | Same as weekly |
| Yearly | AWS Backup | Off (`-Yearly 0`). `-Yearly N`: N points in distinct years with retention over the monthly range | Same as weekly |

- **Tolerance.** A point counts for a scheduled date when it was taken that UTC day or up to `-ToleranceDays`
  (default 1, 0–3) before or after. A scheduled day that has not ended yet and has no point is not expected yet.
- **"So far".** Dates on or before the day a resource was created are never expected. A resource still building
  up shows `3/3 so far (target 5)` and `weekly full on 24 Nov 2026`.
- **Missing dates.** Failing checks name the dates they miss: `weekly 4/5 missing Sat 07 Nov`,
  `monthly 10/12 missing Jun 2026, Sep 2026`.

AWS Backup recovery points are classified by their retention (CreationDate → CalculatedLifecycle.DeleteAt):
25–40 days = weekly, 300–400 days = monthly, over 400 days or never expires = yearly (only when `-Yearly` > 0),
anything else = mismatch (not counted; yellow warning such as
`retention doesn't match: 2 recovery points (2555d, never expires) not counted`).

**Strict retention.** Each counted point is also compared with the retention the schedule expects
(`-DailyRetentionDays` = `-Daily`, `-WeeklyRetentionDays 30`, `-MonthlyRetentionDays 365`, ±`-RetentionToleranceDays 1`).
A difference is highlighted (`retention mismatch: weekly point has 35d, expected 30d (x5)`) but never fails a check.
Two more highlights that never change the status: **excess backups** (`weekly 9 (expected 4-5)`) and **holds more
than retention** (`holds 21 automated backups for 7d retention; 13 older than 7d, oldest ...`).

**Roles.** Global cluster writers are `primary`, other members `secondary`. Secondaries and read replicas are checked
for daily backups only (weekly / monthly / yearly show N/A). `-ReplicaExemptEngines 'oracle-*','aurora-*'` makes
replicas / secondaries of matching engines always COMPLIANT. Aurora member instances are not listed separately.
DocumentDB and Neptune are excluded.

## Status

| Status | Meaning |
|---|---|
| COMPLIANT | Every applicable check passes |
| NON-COMPLIANT | At least one check fails; **Gaps** says which, with the missing dates |
| NOT YET DUE | Too new for the full set, with a backup for every scheduled date since it was created |
| UNKNOWN | A needed call was denied or failed (for example `backup:ListRecoveryPointsByBackupVault`) |

## Outputs

Every output shows the account number (and name: the config map, else the IAM account alias). Every time is in UTC
and a second zone (IST by default, `-Tz` changes it). File names: `<prefix>_<account>_<UTC stamp>.<ext>`, for example
`rds_backup_compliance_111111111111_20261114_100000.html`; with several accounts the numbers are joined
(`..._111111111111_222222222222_...`), more than 3 accounts give `merged_<N>_accounts`. Regions without databases are
left out.

| `-Format` | What you get |
|---|---|
| `text` (default) | Console summary with a `Compliance: 33% (2 of 6), 2 not yet due not counted` line, one row per resource, region errors, exceptions |
| `csv` | The compliance CSV; with `-OutputDir` also `_backups.csv` and `_orphaned_snapshots.csv` (below) |
| `json` | Thresholds, totals, rows (with every recovery point and why it counted or not), orphaned snapshots |
| `html` | One self-contained page with two tabs: **Compliance** (cards, filters, per-region table, detail rows, Export CSV) and **Backups** (one resource or all, backup type, age, account, source status, Export CSV). Default with `-Merge` |

One format goes to stdout when there is no `-OutputDir`; several formats need `-OutputDir`. `-OutputDir report.html`
names the HTML file. The HTML page script is the Bash tool's `backup_page.js`, unchanged (every value is escaped).

## CSV files

All CSV files are UTF-8 (no BOM), every cell quoted, and a cell starting with `= + - @` gets a leading `'` so Excel
does not run it as a formula. No cell is a value Excel would turn into a date. The columns are exactly the Bash
tool's.

| File | Written when | Columns |
|---|---|---|
| `<name>.csv` | `-Format csv` (stdout without `-OutputDir`) | `account_id, region, identifier, type, engine, engine_version, global_cluster, global_role, retention_days, created_utc, age_days, backup_window, copy_tags_to_snapshot, last_automated_utc, last_automated_ist`, then per check (daily, weekly, monthly, and yearly when on) `<check>_status, _found, _expected, _target, _missing, _full_on`, then `status, not_yet_due, gaps, warnings, weekly_retention, monthly_retention, backup_plans, retention_mismatch_count, retention_mismatch, excess_daily, excess_weekly, excess_monthly, excess, over_retention_count, over_retention, counted_in_compliance_pct, pitr_enabled, pitr_since_utc, account_name`, and with an exceptions file `exception, exception_reason, exception_expires, exception_flag, actual_status` |
| `<name>_backups.csv` | `-Format csv` with `-OutputDir` | `account_id, region, identifier, type, kind, snapshot_or_recovery_point, created_utc, created_ist, age_days, status, size_gb, rule, retention_days, expires_utc, vault, source_status, backup_type, schedule` (every manual snapshot, automated backup and AWS Backup recovery point; same as the Backups tab export) |
| `<name>_orphaned_snapshots.csv` | `-Format csv` with `-OutputDir` | `account_id, region, snapshot_id, type, source_id, engine, engine_version, created_utc, created_ist, age_days, size_gb, est_monthly_usd, encrypted, kms_key` (orphaned only, oldest first) |
| `<name>_manual_older_than_<N>d.csv` | `-ManualOlderThan N` (in `-OutputDir`, else the current folder) | `account_id, region, identifier, type, engine, snapshot, created_utc, created_ist, age_days, status, size_gb, source_status` (oldest first) |

The `_ist` columns follow `-Tz` (`created_est` for America/New_York). The in-page **Export CSV** buttons produce the
same columns and quoting as the files (checked in the tests).

## Orphaned manual snapshots

A manual snapshot is **orphaned** when its source cluster or instance no longer exists in the same account and region.
Snapshots are read in every scanned region (with `--include-shared`), even regions with no databases left
(`snapshots only`).

| Source status | Meaning |
|---|---|
| EXISTING | The source exists (a cross-region copy whose source exists in its scanned source region also counts) |
| ORPHANED | The source is gone: counted in the summary and the cost estimate |
| SHARED | Shared with this account or copied from another account: listed, never counted |
| UNVERIFIED | A cross-region copy whose source region was not scanned |

Summary: `4 orphaned snapshots, 1.8 TB, ~$38/month (estimate)` = size GB × `-SnapshotPricePerGb` (default 0.021). It
is a rough upper estimate: snapshot storage is billed incrementally.

## Several accounts: -SaveData, then -Merge

```powershell
# in each account (one data file per account: rds_backup_<ACCOUNT>_<YYYYMMDD>.json, no ARNs)
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod,nonprod -AllRegions -SaveData -OutputDir ./data
# offline, zero AWS calls
./Invoke-RdsBackupCompliance.ps1 -Merge ./data -OutputDir ./reports/all_accounts.html
./Invoke-RdsBackupCompliance.ps1 -Merge ./data/a.json ./data/b.json -Format csv,html -OutputDir ./reports
```

Compliance is evaluated again at merge time, so threshold parameters and the exceptions file apply to `-Merge` too.
The same account twice: the newer collection wins (the older file is logged). The data file format is this tool's own
(`rds_backup_compliance_ps_data`); the Bash tool's `--save-data` files are not read (see
[COMPARISON](docs/COMPARISON.md)).

## Scanning regions in parallel

With several regions, up to `-Parallel N` regions of an account are scanned at once (default 4; `-Parallel 1` = one by
one). The report is the same whatever order regions finish in. A failed region is listed under Region errors and the
others still finish (`111111111111: 5 regions scanned, 2 empty: ap-south-1, eu-west-1; 1 failed: us-west-2`).
`-Verbose` prints every region line (`started`, `(empty)`) and `regions in order`.

## Compliance exceptions

The same `compliance_exceptions.conf` file and format as rds-patch-compliance, rds-backup-compliance (Bash) and
rds-compliance-report:

```text
# account_id | identifier | scope | expires | reason
111111111111 | reports-pg | patch,backup | 2027-03-31 | Vendor-pinned version | INC-77
```

- File: `-Exceptions FILE` (config `exceptions = FILE`), default `compliance_exceptions.conf` next to the script when
  present. Start from [compliance_exceptions.conf.example](compliance_exceptions.conf.example); the real file is git-ignored.
- Strict: a missing field, bad account / scope / date, wildcard or duplicate stops the run (exit 1) with `file:line`,
  before any AWS call.
- Matched and not expired: **COMPLIANT (EXCEPTION)**, counted as compliant; the evaluated status stays in
  `actual_status`. Flags: `expiring soon` (14 days or less), `no longer needed`; expired entries are evaluated
  normally and flagged `exception expired`. Entries that match no server are logged and listed.
- Applied when the report is built: `-SaveData` files never change.

## E-mail alert

```powershell
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Format html -OutputDir ./reports `
    -AlertEmail dba-team@example.com -AlertSmtpServer smtp.example.com -AlertFrom rds-backup@example.com -AlertAttach
./Invoke-RdsBackupCompliance.ps1 -AlertEmail dba-team@example.com -AlertSmtpServer smtp.example.com -AlertTest
```

The body is the text report; `-AlertAttach` attaches the files written. `-AlertOn noncompliant` (default) sends only
when something is NON-COMPLIANT or a region failed; `-AlertOn always` sends every time. The relay must accept mail
without login or TLS. A failed send is a warning and never changes the exit code.

## Parameters

Run `./Invoke-RdsBackupCompliance.ps1 -Help` for the full list. Lists take commas (`-Region us-east-1,us-west-2`).

| Group | Parameters |
|---|---|
| Scope | `-ProfileName` (`-Profile`), `-Region`, `-AllRegions`, `-Engine`, `-Identifier` (case-insensitive globs) |
| Schedule | `-Daily 7`, `-DailyMaxAge 26`, `-Weekly auto\|N`, `-WeeklyWindowDays 30`, `-WeeklyWeekday sat`, `-Monthly 12`, `-MonthlyRule first-sun`, `-Yearly 0`, `-ToleranceDays 1`, `-WeeklyDays 25-40`, `-MonthlyDays 300-400`, `-MonthlyMaxDays` |
| Strict retention | `-DailyRetentionDays`, `-WeeklyRetentionDays 30`, `-MonthlyRetentionDays 365`, `-RetentionToleranceDays 1` |
| Roles | `-ReplicaExemptEngines` |
| Result | `-NonCompliantOnly`, `-FailOnNonCompliant`, `-Exceptions FILE` |
| Output | `-Format text,csv,json,html`, `-OutputDir`, `-Prefix`, `-Tz`, `-ManualOlderThan N`, `-SnapshotPricePerGb 0.021`, `-SaveData`, `-SaveDataFile`, `-LogFile` |
| Merge | `-Merge FILE\|DIR ...` |
| Alerts | `-AlertEmail`, `-AlertSmtpServer`, `-AlertSmtpPort 25`, `-AlertFrom`, `-AlertOn`, `-AlertAttach`, `-AlertTest` |
| Run | `-ConfigFile`, `-Parallel 4`, `-AwsTimeout 30`, `-MaxAttempts 5`, `-KeepWorkdir`, `-DryRun`, `-Verbose`, `-Help`, `-Version` |

## Configuration file

`-ConfigFile FILE` reads `key = value` lines with the Bash tool's `--config` key names (`weekly = 4`,
`replica-exempt-engines = oracle-*`, `snapshot_price_per_gb = 0.05` ...), plus `alert-*` keys, and
`111111111111 = prod-payments` lines for account names. It is never executed, credentials are refused, an unknown key
stops the run with `file:line`, and parameters on the command line win. See
[rds_backup_compliance_report.conf.example](rds_backup_compliance_report.conf.example).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Usage error (bad parameter, config or exceptions file) |
| 2 | Pre-check failed (aws CLI missing, no credentials, no region, no profile could be scanned) |
| 3 | Bad `-Merge` input |
| 4 | Output error |
| 5 | NON-COMPLIANT resource found, with `-FailOnNonCompliant` |

## Permissions (read-only)

`sts:GetCallerIdentity`, `iam:ListAccountAliases` (optional, account name), `ec2:DescribeRegions` (`-AllRegions`),
`rds:DescribeDBClusters`, `rds:DescribeDBInstances`, `rds:DescribeGlobalClusters`, `rds:DescribeDBClusterSnapshots`,
`rds:DescribeDBSnapshots`, `backup:ListBackupVaults`, `backup:ListRecoveryPointsByBackupVault`. The full policy is in
[docs/JUMP-BOX-SETUP.md](docs/JUMP-BOX-SETUP.md). `-DryRun` prints every call without making it.

## Limitations

- Recovery points are read vault by vault in the scanned account and region; copies in another account or region
  (a central backup account) are not counted.
- Daily backups are counted from automated snapshots; continuous backup / PITR between snapshots is not inspected.
- If `describe-global-clusters` is denied, roles show as `unknown` and the full checks apply.
- Scheduled days are UTC dates.
- The orphan cost is an upper estimate (allocated size, not billed incremental bytes). Orphans are matched by
  identifier within one account and region.
- AWS CLI v2 only (no AWS.Tools back end). E-mail only through an unauthenticated SMTP relay; no webhooks.
- `-SaveData` files are this tool's own format; Bash data files cannot be merged here (and the other way round).

## Tests

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser; Install-Module PSScriptAnalyzer -Scope CurrentUser
cd tests; npm install; cd ..                      # puppeteer-core, for the headless Chrome page checks
Invoke-Pester ./tests -Output Detailed
```

Every test runs the real script in a child `pwsh` against a mock AWS CLI (`tests/mock/aws`, Python 3; on Windows
`tests/mock/win/aws.cmd`) with fake credentials and a frozen clock. Covered: every rule and scenario, all four CSV
files column by column, exceptions, merge, parallel scans, alerts (local SMTP sink), the HTML page in headless Chrome
(filters, tabs, CSV export = CSV file, exceptions, links, XSS), PSScriptAnalyzer. With `RDS_BCR_BASH_DIR` pointing at
a clone of the Bash tool (Linux), `tests/Parity.Tests.ps1` runs both tools on the same mock and requires identical
output files. CI runs on `windows-latest` and `ubuntu-latest`.

## License

[MIT](LICENSE)
