# Jump box setup: multi-account collection, merge, e-mail and schedule

This guide sets up a Windows EC2 jump box to run `Invoke-RdsBackupCompliance.ps1` on a schedule. One job collects
data from every account, merges it into one report and e-mails it. All account numbers below are fake examples;
replace them with yours. A Linux jump box works the same way ([cron](#linux-jump-box) at the end).

## How it works

1. The jump box's **EC2 instance role** gives the box credentials. No access keys are stored.
2. Each other account has a read-only role, `RdsComplianceReadOnly`, that the jump box role may assume.
3. `~\.aws\config` has one profile per account (`credential_source = Ec2InstanceMetadata`).
4. A wrapper script collects with `-SaveData`, merges with `-Merge` (0 AWS calls) and mails the HTML report.
5. Task Scheduler runs the wrapper every week.

## 1. Find your AWS config

These commands only read; nothing changes.

```powershell
"AWS_CONFIG_FILE=$env:AWS_CONFIG_FILE"
"AWS_SHARED_CREDENTIALS_FILE=$env:AWS_SHARED_CREDENTIALS_FILE"
Get-ChildItem "$env:USERPROFILE\.aws" -Force      # default folder: C:\Users\<you>\.aws
aws configure list
aws configure list-profiles
aws sts get-caller-identity
```

- If neither variable is set, the files are `C:\Users\<you>\.aws\config` and `C:\Users\<you>\.aws\credentials`.
- `iam-role` in the **Location** column of `aws configure list` means the instance role supplies the credentials.
- The ARN from `get-caller-identity`, such as `arn:aws:sts::999999999999:assumed-role/<JumpBoxRoleName>/i-...`,
  gives the jump box account number and role name used below.
- A scheduled task must run as the **same Windows user** that owns this `.aws` folder.

## 2. IAM permissions

### 2a. Read-only policy for the report

Attach this inline policy, named `RdsBackupComplianceReadOnly`, to the jump box role (to report on the jump box's own
account) and to each account's `RdsComplianceReadOnly` role. IAM → **Roles** → the role → **Add permissions** →
**Create inline policy** → **JSON**.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "RdsBackupComplianceReadOnly",
    "Effect": "Allow",
    "Action": [
      "rds:DescribeDBClusters",
      "rds:DescribeDBInstances",
      "rds:DescribeGlobalClusters",
      "rds:DescribeDBClusterSnapshots",
      "rds:DescribeDBSnapshots",
      "backup:ListBackupVaults",
      "backup:ListRecoveryPointsByBackupVault",
      "ec2:DescribeRegions",
      "iam:ListAccountAliases"
    ],
    "Resource": "*"
  }]
}
```

| Permission | Used for | If denied |
|---|---|---|
| `rds:DescribeDBClusters`, `rds:DescribeDBInstances` | The resources, retention, backup window | The region fails (listed under Region errors) |
| `rds:DescribeGlobalClusters` | Primary / secondary roles | Roles show `unknown`, full checks apply |
| `rds:DescribeDBClusterSnapshots`, `rds:DescribeDBSnapshots` | Daily backups, manual snapshots, orphans | Daily check UNKNOWN |
| `backup:ListBackupVaults`, `backup:ListRecoveryPointsByBackupVault` | Weekly / monthly / yearly points | Those checks UNKNOWN |
| `ec2:DescribeRegions` | `-AllRegions` only | Use `-Region` |
| `iam:ListAccountAliases` | Account name (optional) | Account number only, or the name from the config file |

- Everything here is read-only; `sts:GetCallerIdentity` needs no permission. The tool never creates, changes or
  deletes anything; `-DryRun` prints every call.
- Encrypted vaults need no KMS permission: listing recovery points reads metadata only.
- The jump box usually can't edit its own role, so someone with IAM admin rights makes these changes.

### 2b. A role in each other account

In each other account, create `RdsComplianceReadOnly`, attach the policy from 2a and give it this trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::999999999999:role/<JumpBoxRoleName>" },
    "Action": "sts:AssumeRole"
  }]
}
```

### 2c. Let the jump box role assume those roles

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": [
      "arn:aws:iam::111111111111:role/RdsComplianceReadOnly",
      "arn:aws:iam::222222222222:role/RdsComplianceReadOnly"
    ]
  }]
}
```

## 3. Create the AWS config

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.aws" | Out-Null
@"
[profile base]
credential_source = Ec2InstanceMetadata
region = us-east-1

[profile prod]
role_arn = arn:aws:iam::111111111111:role/RdsComplianceReadOnly
credential_source = Ec2InstanceMetadata
region = us-east-1

[profile nonprod]
role_arn = arn:aws:iam::222222222222:role/RdsComplianceReadOnly
credential_source = Ec2InstanceMetadata
region = ap-south-1
"@ | Set-Content -Encoding ascii "$env:USERPROFILE\.aws\config"

aws sts get-caller-identity --profile prod
aws backup list-backup-vaults --profile prod --region us-east-1 --query 'BackupVaultList[].BackupVaultName'
```

`credential_source = Ec2InstanceMetadata` makes the CLI assume each account's role with the instance role's
credentials: no keys to store or rotate. The `base` profile reports on the jump box's own account.

## 4. Get the tool

You need PowerShell 7.2 or later (`pwsh`) and the AWS CLI v2.

```powershell
Set-Location $env:USERPROFILE
git clone https://github.com/manideepgrandhi/rds-backup-compliance-powershell.git
# or without git:
# Invoke-WebRequest https://github.com/manideepgrandhi/rds-backup-compliance-powershell/archive/refs/heads/main.zip -OutFile rbc.zip
# Expand-Archive rbc.zip -DestinationPath . ; Rename-Item rds-backup-compliance-powershell-main rds-backup-compliance-powershell
pwsh .\rds-backup-compliance-powershell\Invoke-RdsBackupCompliance.ps1 -Version
```

Optional: put shared settings and account names in `C:\compliance\rbc.conf` (see
`rds_backup_compliance_report.conf.example`) and exceptions in `compliance_exceptions.conf` next to the script.

## 5. Collect, merge and e-mail by hand

```powershell
$tool = "$env:USERPROFILE\rds-backup-compliance-powershell"

# collect: one rds_backup_<ACCOUNTID>_<YYYYMMDD>.json per account
& "$tool\Invoke-RdsBackupCompliance.ps1" -ProfileName base,prod,nonprod -AllRegions -SaveData -OutputDir C:\compliance\data

# merge (0 AWS calls): HTML + all CSV files, e-mail the text report with the files attached
& "$tool\Invoke-RdsBackupCompliance.ps1" -Merge C:\compliance\data -Format html,csv -OutputDir C:\compliance\combined `
    -ManualOlderThan 90 -AlertEmail dba-team@example.com -AlertFrom rds-backup@example.com `
    -AlertSmtpServer smtp.example.com -AlertSmtpPort 25 -AlertOn always -AlertAttach
```

- `-AlertOn always` mails every run; the default mails only when something is NON-COMPLIANT or a region failed.
- The built-in e-mail works only through an SMTP relay that needs no login or TLS.
- Data files from the Bash tool cannot be merged here (different data format); collect with this tool.

## 6. Wrapper script

Save as `C:\compliance\Run-BackupCompliance.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$tool  = "$env:USERPROFILE\rds-backup-compliance-powershell"
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$data  = "C:\compliance\data\$stamp"
$out   = "C:\compliance\reports\$stamp"
New-Item -ItemType Directory -Force $data, $out | Out-Null

# 1. collect (one data file per account); a failed account or region does not stop the others
& "$tool\Invoke-RdsBackupCompliance.ps1" -ProfileName base,prod,nonprod -AllRegions `
    -SaveData -OutputDir $data -LogFile C:\compliance\run.log

# 2. merge and mail (0 AWS calls)
& "$tool\Invoke-RdsBackupCompliance.ps1" -Merge $data -Format html,csv -OutputDir $out -ManualOlderThan 90 `
    -AlertEmail dba-team@example.com -AlertFrom rds-backup@example.com -AlertSmtpServer smtp.example.com `
    -AlertOn always -AlertAttach -LogFile C:\compliance\run.log

# 3. keep 30 days of data and reports
Get-ChildItem C:\compliance\data, C:\compliance\reports |
    Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -Recurse -Force
```

## 7. Schedule it (Task Scheduler)

Every Monday at 9:30 AM in the box's time zone. Run once in an admin PowerShell:

```powershell
$a = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File C:\compliance\Run-BackupCompliance.ps1'
$t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 9:30am
Register-ScheduledTask -TaskName 'RDS Backup Compliance' -Action $a -Trigger $t -User $env:USERNAME -RunLevel Limited

Start-ScheduledTask 'RDS Backup Compliance'
Get-ScheduledTaskInfo 'RDS Backup Compliance'   # LastTaskResult 0 = success
```

- The task asks for the password so it can run while you're signed out.
- It must run as the user that owns `C:\Users\<you>\.aws\config`; otherwise set `AWS_CONFIG_FILE` in the wrapper.
- Add `-FailOnNonCompliant` to the collect step if the task result should show 5 when something is NON-COMPLIANT.

### Linux jump box

Same wrapper with Linux paths, then `crontab -e`:

```
30 9 * * 1  pwsh -NoProfile -File $HOME/compliance/Run-BackupCompliance.ps1 >> $HOME/compliance/cron.log 2>&1
```

The config is `~/.aws/config` of the user that owns the crontab.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Unable to locate credentials` | The instance role isn't attached, or the task runs as another user |
| `AccessDenied ... sts:AssumeRole` | The policy from 2c is missing, or the trust policy in 2b names the wrong role |
| A region under Region errors | `rds:Describe*` missing on that account's role, or the region is disabled |
| Weekly / monthly `UNKNOWN` | `backup:ListBackupVaults` or `backup:ListRecoveryPointsByBackupVault` missing |
| Roles `unknown` | `rds:DescribeGlobalClusters` missing |
| No e-mail | The relay needs login or TLS, or port 25 is blocked from EC2 |
| `exit 3` on merge | A file in the data folder isn't a valid `-SaveData` file of this tool |
