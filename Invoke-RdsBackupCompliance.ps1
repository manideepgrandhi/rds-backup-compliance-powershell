<#
.SYNOPSIS
Backup compliance report for Aurora clusters and standalone RDS instances, per account and region (read-only).

.DESCRIPTION
PowerShell 7 version of rds_backup_compliance_report.sh v1.6.0: the same rules, statuses, CSV columns and HTML page.
  daily   RDS automated backups: retention >= 7 days, one backup on each of the last 7 UTC days, the newest <= 26 h old
  weekly  an AWS Backup point (retention 25-40 days) for every Saturday of the last 30 days (+/- 1 day)
  monthly an AWS Backup point (retention 300-400 days) for the first Sunday of each of the last 12 months (+/- 1 day)
  strict  expected retention daily 7 d, weekly 30 d, monthly 365 d (+/- 1 d): a difference is highlighted, never a failure
  yearly  off by default (-Yearly N checks N points with retention above the monthly range)
Aurora global secondaries and read replicas: daily only. -ReplicaExemptEngines makes matching ones always COMPLIANT.
Status: COMPLIANT | NON-COMPLIANT | NOT YET DUE (resource too young) | UNKNOWN (a call failed).
Only describe / list / get calls are made (AWS CLI v2). Run with -Help for every option.

.EXAMPLE
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -Region us-east-1,ap-south-1

.EXAMPLE
./Invoke-RdsBackupCompliance.ps1 -ProfileName prod -AllRegions -Format csv,html -OutputDir ./reports -ManualOlderThan 90 -SaveData

.EXAMPLE
./Invoke-RdsBackupCompliance.ps1 -Merge ./data -OutputDir ./reports/all_accounts.html

.NOTES
Exit codes: 0 ok, 5 NON-COMPLIANT with -FailOnNonCompliant, 1 usage, 2 pre-check, 3 bad -Merge input, 4 output error.
#>
#Requires -Version 7.2
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('Profile', 'P')][string[]]$ProfileName, [Alias('r')][string[]]$Region, [Alias('A')][switch]$AllRegions,
    [Alias('e')][string[]]$Engine, [Alias('i')][string[]]$Identifier,
    [string]$Daily, [string]$DailyMaxAge, [string]$Weekly, [string]$WeeklyWindowDays, [string]$WeeklyWeekday, [string]$Monthly, [string]$MonthlyRule,
    [string]$ToleranceDays, [string]$Yearly, [string]$WeeklyDays, [string]$MonthlyDays, [string]$MonthlyMaxDays,
    [string]$DailyRetentionDays, [string]$WeeklyRetentionDays, [string]$MonthlyRetentionDays, [string]$RetentionToleranceDays,
    [string[]]$ReplicaExemptEngines, [switch]$NonCompliantOnly, [switch]$FailOnNonCompliant, [Alias('ExceptionsFile')][string]$Exceptions,
    [Alias('F')][string[]]$Format, [Alias('o')][string]$OutputDir, [string]$ManualOlderThan, [string]$SnapshotPricePerGb,
    [switch]$SaveData, [string]$SaveDataFile, [string]$Prefix, [Alias('TimeZone')][string]$Tz, [Alias('l')][string]$LogFile, [string[]]$Merge,
    [string[]]$AlertEmail, [string]$AlertSmtpServer, [string]$AlertSmtpPort, [string]$AlertFrom, [string]$AlertOn, [switch]$AlertAttach, [switch]$AlertTest,
    [Alias('Config')][string]$ConfigFile, [string]$Parallel, [string]$AwsTimeout, [string]$MaxAttempts, [switch]$KeepWorkdir, [switch]$DryRun,
    [Alias('h')][switch]$Help, [Alias('V')][switch]$Version,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$MoreArgs
)
# Thin wrapper: load the module next to this script and exit with the run's exit code
$ErrorActionPreference = 'Stop'
$vp = $VerbosePreference; $VerbosePreference = 'SilentlyContinue'   # -Verbose is for the tool's own lines, not module loading
Import-Module (Join-Path $PSScriptRoot 'src/RdsBackupCompliance.psm1') -Force -Verbose:$false
$VerbosePreference = $vp
$result = Invoke-RdsBackupCompliance @PSBoundParameters
exit ([int]@($result)[-1])
