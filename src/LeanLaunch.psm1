Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NativeControl.ps1')
. (Join-Path $PSScriptRoot 'Storage.ps1')
. (Join-Path $PSScriptRoot 'Profiles.ps1')
. (Join-Path $PSScriptRoot 'Audit.ps1')
. (Join-Path $PSScriptRoot 'Policy.ps1')
. (Join-Path $PSScriptRoot 'Applications.ps1')
. (Join-Path $PSScriptRoot 'Classification.ps1')
. (Join-Path $PSScriptRoot 'AppRunView.ps1')
. (Join-Path $PSScriptRoot 'Cleanup.ps1')
. (Join-Path $PSScriptRoot 'Cli.ps1')

Export-ModuleMember -Function @(
    'Get-LeanLaunchPaths', 'Test-LeanLaunchProfileName', 'Expand-LeanLaunchValue',
    'Import-LeanLaunchProfile', 'New-LeanLaunchProfile', 'Get-LeanLaunchProfiles',
    'New-LeanLaunchSnapshot', 'Save-LeanLaunchSnapshot', 'Import-LeanLaunchSnapshot',
    'Compare-LeanLaunchSnapshot', 'New-LeanLaunchRunPlan', 'Invoke-LeanLaunchRun',
    'Invoke-LeanLaunchCommand', 'Get-LeanLaunchDoctorReport', 'ConvertTo-LeanLaunchArgumentString',
    'Test-LeanLaunchApplicationPolicy', 'Get-LeanLaunchResourceClassificationOptions',
    'New-LeanLaunchApplication', 'Import-LeanLaunchApplication', 'Get-LeanLaunchApplications',
    'Set-LeanLaunchApplicationPolicy', 'New-LeanLaunchApplicationBeforeSnapshot',
    'Get-LeanLaunchAuditCandidates', 'Complete-LeanLaunchApplicationAudit',
    'Set-LeanLaunchResourceClassification', 'New-LeanLaunchApplicationProfile',
    'Invoke-LeanLaunchApplicationRun', 'Get-LeanLaunchApplicationAuditStatus',
    'Get-LeanLaunchApplicationSummaryRows', 'Get-LeanLaunchClassificationRows',
    'Get-LeanLaunchApplicationSafetyWarnings', 'Get-LeanLaunchRunPlanSummaryLines', 'Test-LeanLaunchHasProperty',
    'Write-LeanLaunchJsonAtomic', 'Set-LeanLaunchServiceParkingPreference',
    'Test-LeanLaunchApplicationProfileBindingValid', 'Save-LeanLaunchApplication',
    'Import-LeanLaunchApplicationForUpdate', 'Get-LeanLaunchFileHash',
    'Get-LeanLaunchApplicationBoundProfilePath', 'Get-LeanLaunchValidatedManagedProfile'
)
