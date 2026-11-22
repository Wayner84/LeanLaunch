@{
    RootModule = 'src/LeanLaunch.psm1'
    ModuleVersion = '0.1.0'
    GUID = '99b0f853-3985-4e25-a5e9-f6a3212fd44a'
    Author = 'Wayne Townsend and contributors'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Wayne Townsend. MIT License.'
    Description = 'Launch heavyweight Windows applications only with the resources they need, then clean up explicitly configured leftovers.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
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
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Windows', 'launcher', 'performance', 'services', 'PowerToys')
            LicenseUri = 'https://github.com/Wayner84/LeanLaunch/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Wayner84/LeanLaunch'
        }
    }
}
