# Examples

All account numbers and names are fake. Lists take commas: `-Region us-east-1,us-west-2`.

## Scope

```powershell
# current credentials, default region
./Invoke-RdsBackupCompliance.ps1

# one profile, two regions
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Region us-east-1,us-west-2

# several accounts, every enabled region
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod,nonprod -AllRegions -Format html -OutputDir ./reports

# only Aurora PostgreSQL, identifiers starting with orders-
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Engine aurora-postgresql -Identifier 'orders-*'

# see the AWS calls without making them
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -DryRun
```

## Policy variations

```powershell
# exactly the last 4 Saturdays, monthly on the first Monday, 2 days tolerance
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Weekly 4 -MonthlyRule first-mon -ToleranceDays 2

# weekly backups on Sunday, 14 daily backups, newest at most 30 h old
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -WeeklyWeekday sun -Daily 14 -DailyMaxAge 30

# check 3 yearly points (retention above the monthly range)
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Yearly 3

# other retention classes and strict expectations
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -WeeklyDays 20-45 -MonthlyDays 330-400 `
    -WeeklyRetentionDays 35 -MonthlyRetentionDays 366 -RetentionToleranceDays 2

# Oracle and Aurora replicas / secondaries are covered elsewhere: always COMPLIANT
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -ReplicaExemptEngines 'oracle-*','aurora-*'
```

## Results and CI

```powershell
# only the problems
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -NonCompliantOnly

# fail a pipeline (exit 5) when anything is NON-COMPLIANT
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -FailOnNonCompliant
if ($LASTEXITCODE -eq 5) { Write-Error 'backup policy gaps found' }

# exceptions file
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Exceptions ./compliance_exceptions.conf
```

## CSV

```powershell
# compliance CSV on stdout
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Format csv > compliance.csv

# compliance + backups + orphaned snapshots CSV files
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Format csv -OutputDir ./reports

# plus manual snapshots older than 90 days (_manual_older_than_90d.csv)
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Format csv,html -OutputDir ./reports -ManualOlderThan 90

# times in New York instead of IST (columns become *_est)
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Format csv -OutputDir ./reports -Tz America/New_York

# read the CSV back in PowerShell
Import-Csv ./reports/rds_backup_compliance_111111111111_*.csv | Where-Object status -eq 'NON-COMPLIANT' |
    Select-Object region, identifier, gaps
Import-Csv ./reports/*_orphaned_snapshots.csv | Measure-Object est_monthly_usd -Sum
```

## Other formats

```powershell
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Format json | ConvertFrom-Json | Select-Object -ExpandProperty totals
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -OutputDir ./reports/prod.html      # names the HTML file
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Format text,json,csv,html -OutputDir ./reports -Prefix backup_audit
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -SnapshotPricePerGb 0.05            # orphan cost estimate price
```

## Several accounts

```powershell
# collect in each account (CloudShell, jump box ...), one data file per account
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod,nonprod -AllRegions -SaveData -OutputDir ./data
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -SaveDataFile ./data/prod-today.json

# combine offline (0 AWS calls); compliance is evaluated again with today's thresholds and exceptions
./Invoke-RdsBackupCompliance.ps1 -Merge ./data -OutputDir ./reports/all_accounts.html
./Invoke-RdsBackupCompliance.ps1 -Merge ./data/a.json ./data/b.json -Format csv,html -OutputDir ./reports -Weekly 4
```

## Parallel scans

```powershell
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Parallel 8    # 8 regions at a time
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Parallel 1    # one by one
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Verbose       # every region line and debug logs
```

## Config file

```powershell
Copy-Item rds_backup_compliance_report.conf.example rbc.conf    # edit it
./Invoke-RdsBackupCompliance.ps1 -ConfigFile ./rbc.conf
./Invoke-RdsBackupCompliance.ps1 -ConfigFile ./rbc.conf -Weekly 5   # parameters win over the file
```

## E-mail

```powershell
./Invoke-RdsBackupCompliance.ps1 -AlertEmail dba-team@example.com -AlertSmtpServer smtp.example.com -AlertTest
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Format html,csv -OutputDir ./reports `
    -AlertEmail dba-team@example.com,oncall@example.com -AlertSmtpServer smtp.example.com `
    -AlertFrom rds-backup@example.com -AlertOn always -AlertAttach
```

## Scheduling

See [docs/JUMP-BOX-SETUP.md](docs/JUMP-BOX-SETUP.md) for an EC2 jump box with cross-account roles, a wrapper script,
Task Scheduler and cron.
