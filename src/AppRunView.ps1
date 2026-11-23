Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-LeanLaunchApplicationRun {
    <#
    The single shared launch entry point for both the CLI and the GUI. Unmanaged applications are
    started directly with no service or cleanup action of any kind - LeanLaunch takes no action on
    them by design. Managed applications require a reviewed profile and go through the full
    Invoke-LeanLaunchRun lifecycle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DataRoot,
        [string]$RepositoryRoot,
        [hashtable]$Adapter,
        [switch]$DryRun,
        [switch]$KeepServices,
        [switch]$NoCleanup
    )
    if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
    $application = Import-LeanLaunchApplication -Name $Name -DataRoot $DataRoot
    if ($application.policy -eq 'Unmanaged') {
        if ($DryRun) {
            return [pscustomobject]@{ status = 'DryRun'; applicationName = $Name; policy = 'Unmanaged'; plan = "Launch $($application.executable) directly. LeanLaunch will not start, stop, or clean up anything." }
        }
        $launched = & $Adapter.StartProcess $application.executable @() ''
        if ($null -eq $launched) { throw 'The process adapter did not return a launched process.' }
        return [pscustomobject]@{ status = 'UnmanagedLaunch'; applicationName = $Name; policy = 'Unmanaged'; processId = [int]$launched.Id }
    }
    if ([string]::IsNullOrWhiteSpace([string]$application.profileName)) {
        throw "Application '$Name' is set to Managed but has no profile yet. Review resources and create a profile first."
    }
    # Revalidated immediately before every Managed run (dry or real), never trusted merely because
    # policy=Managed was persisted at some earlier point - a replaced, hand-edited, or stale profile
    # (or a hand-edited application record whose classifications drifted from what was reviewed)
    # fails this and the run is refused, closing exactly the gap a policy-only or ID-only check leaves.
    # Single read: the returned $profile is the SAME in-memory object the validation itself parsed
    # from the exact bytes it hashed - the profile path is never opened again after this call, which
    # is what closes the TOCTOU a separate validate-then-reimport sequence would otherwise leave open.
    $profile = Get-LeanLaunchValidatedManagedProfile -Application $application -DataRoot $DataRoot
    if ($null -eq $profile) {
        throw "Application '$Name' is set to Managed, but its bound profile no longer matches the current audit exactly (replaced, hand-edited, or stale). Refusing to run. Regenerate the profile from the current audit and re-apply Managed policy."
    }
    if (-not (Test-Path -LiteralPath $profile.executable -PathType Leaf)) {
        throw "Profile executable was not found: $($profile.executable)"
    }
    # Parked services are recorded Disabled; restore each to its original start mode only for the
    # duration of this run so Invoke-LeanLaunchRun's normal StartService call can succeed, then
    # re-park it afterwards. The persisted currentlyParked flag never changes - this is a run-scoped
    # loan of the service's original mode, not a policy change. Only entries this call actually
    # restored are re-parked in the finally block: if a later entry's restore fails (for example a
    # drifted start mode the adapter refuses to touch), the run must never start, and any entry
    # already restored earlier in this same batch must not be left stranded off its parked state.
    $parkedForThisRun = @($application.parkedServices | Where-Object { $_.currentlyParked })
    if (-not $DryRun -and $parkedForThisRun.Count -gt 0 -and $Adapter.ContainsKey('IsAdministrator') -and -not (& $Adapter.IsAdministrator)) {
        throw 'Restoring a parked service for this run requires administrator rights. Run PowerShell as Administrator.'
    }
    $restoredForThisRun = New-Object System.Collections.ArrayList
    $unparkedAfterRun = New-Object System.Collections.ArrayList
    try {
        if (-not $DryRun -and $parkedForThisRun.Count -gt 0) {
            foreach ($entry in $parkedForThisRun) {
                & $Adapter.SetServiceStartMode ([string]$entry.name) 'Disabled' ([string]$entry.originalStartMode)
                [void]$restoredForThisRun.Add($entry)
            }
        }
        $run = Invoke-LeanLaunchRun -Profile $profile -Adapter $Adapter -DryRun:$DryRun -KeepServices:$KeepServices -NoCleanup:$NoCleanup
    }
    finally {
        if (-not $DryRun -and $restoredForThisRun.Count -gt 0) {
            # Each entry is handled in its own try/catch so one service's re-park failure can never
            # abort processing of the rest of the batch, or skip persisting the ones that DID succeed -
            # every failure is collected and surfaced together below instead.
            $reparkFailures = New-Object System.Collections.Generic.List[string]
            foreach ($entry in $restoredForThisRun) {
                # Re-parking (disabling) must never proceed unless this service is confirmed stopped.
                # -KeepServices, -NoCleanup, a timeout that preserves resources, or a cleanup failure
                # can all legitimately leave it running when Invoke-LeanLaunchRun's own cleanup (which
                # already stops it through the identity-bound path above when it does run) returns -
                # re-disabling a still-running service now would strand it in a start mode that can
                # never restart it. Any uncertainty (the status check itself fails) is treated the same
                # as "still running": fail closed by leaving the loan outstanding, never by disabling.
                $stillRunning = $true
                try {
                    $current = & $Adapter.GetService ([string]$entry.name)
                    $stillRunning = (Get-LeanLaunchServiceStatus $current) -eq 'Running'
                }
                catch { $stillRunning = $true }
                try {
                    if (-not $stillRunning) {
                        & $Adapter.SetServiceStartMode ([string]$entry.name) ([string]$entry.originalStartMode) 'Disabled'
                    }
                    elseif ($entry.currentlyParked) {
                        [void]$unparkedAfterRun.Add([string]$entry.name)
                    }
                }
                catch {
                    [void]$reparkFailures.Add("$($entry.name) ($($_.Exception.Message))")
                }
            }
            if ($unparkedAfterRun.Count -gt 0) {
                # Never save the stale $application read at the top of this (potentially long-running)
                # call - re-read fresh immediately before committing and merge in ONLY the specific
                # services this run itself determined must be unparked, via CAS, so any concurrent
                # policy/audit/classification/profile change made elsewhere during the run survives
                # instead of being silently reverted to what this call read before the run started.
                try {
                    $freshLoaded = Import-LeanLaunchApplicationForUpdate -Name $Name -DataRoot $DataRoot
                    $freshApplication = $freshLoaded.Application
                    foreach ($serviceName in @($unparkedAfterRun)) {
                        $freshEntry = @($freshApplication.parkedServices) | Where-Object { [string]$_.name -eq $serviceName } | Select-Object -First 1
                        if ($null -ne $freshEntry -and $freshEntry.currentlyParked) { $freshEntry.currentlyParked = $false }
                    }
                    Save-LeanLaunchApplication -Application $freshApplication -DataRoot $DataRoot -ExpectedCurrentContent $freshLoaded.RawContent | Out-Null
                }
                catch {
                    foreach ($serviceName in @($unparkedAfterRun)) {
                        [void]$reparkFailures.Add("$serviceName (failed to persist unparked state: $($_.Exception.Message))")
                    }
                }
            }
            if ($reparkFailures.Count -gt 0) {
                throw "Failed to fully re-park service(s) after the run: $($reparkFailures -join '; '). Physical service state and the persisted record may now disagree; manual verification required."
            }
        }
    }
    $run | Add-Member -MemberType NoteProperty -Name applicationName -Value $Name -Force
    $run | Add-Member -MemberType NoteProperty -Name policy -Value 'Managed' -Force
    $run | Add-Member -MemberType NoteProperty -Name unparkedAfterRunServices -Value @($unparkedAfterRun) -Force
    return $run
}

# --- Shared view-model/controller helpers -------------------------------------------------------
#
# Pure data transforms consumed by both the CLI formatter and the GUI. None of these touch the
# filesystem or an adapter, so they are unit-testable without Windows boundary mocks.

function Get-LeanLaunchApplicationAuditStatus {
    param($Application)
    if ($null -eq $Application.currentAudit) { return 'NoAudit' }
    if ([string]::IsNullOrWhiteSpace([string]$Application.currentAudit.afterSnapshot)) { return 'BeforeCaptured' }
    $unreviewed = @($Application.currentAudit.classifications | Where-Object { [string]$_.decision -eq 'Unreviewed' }).Count
    if ($unreviewed -gt 0) { return 'AwaitingReview' }
    return 'Reviewed'
}

function Get-LeanLaunchApplicationSummaryRows {
    [CmdletBinding()]
    param($Applications)
    $rows = foreach ($application in @($Applications | Where-Object { $null -ne $_ })) {
        if ((Test-LeanLaunchHasProperty $application 'isMalformed') -and $application.isMalformed) {
            [pscustomobject]@{
                name = [string]$application.name
                displayName = [string]$application.displayName
                policy = 'Malformed'
                executable = ''
                hasProfile = $false
                profileName = $null
                auditStatus = 'Malformed'
                pendingReviewCount = 0
                isMalformed = $true
                malformedReason = [string]$application.malformedReason
            }
            continue
        }
        $auditStatus = Get-LeanLaunchApplicationAuditStatus $application
        $pending = 0
        if ($null -ne $application.currentAudit) {
            $pending = @($application.currentAudit.classifications | Where-Object { [string]$_.decision -eq 'Unreviewed' }).Count
        }
        [pscustomobject]@{
            name = [string]$application.name
            displayName = [string]$application.displayName
            policy = [string]$application.policy
            executable = [string]$application.executable
            hasProfile = -not [string]::IsNullOrWhiteSpace([string]$application.profileName)
            profileName = [string]$application.profileName
            auditStatus = $auditStatus
            pendingReviewCount = $pending
            isMalformed = $false
            malformedReason = ''
        }
    }
    return @($rows | Sort-Object name)
}

function Get-LeanLaunchClassificationRows {
    <#
    parkWhenIdle is the persisted PREFERENCE (activation is deferred until Managed policy is next
    applied); currentlyParked is the LIVE state of whether a service is actually disabled right now
    because LeanLaunch parked it. These can legitimately differ (preference on, not yet activated;
    or preference just turned off but the record has not been reloaded) - callers (the GUI grid in
    particular) must show both distinctly and never present one as if it were the other.
    #>
    [CmdletBinding()]
    param($Application)
    if ($null -eq $Application.currentAudit) { return @() }
    $rows = foreach ($entry in @($Application.currentAudit.classifications)) {
        $currentlyParked = $false
        if ([string]$entry.resourceType -eq 'Service') {
            $parkedRecord = @($Application.parkedServices) | Where-Object { [string]$_.name -eq [string]$entry.name -and $_.currentlyParked } | Select-Object -First 1
            $currentlyParked = $null -ne $parkedRecord
        }
        [pscustomobject]@{
            key = [string]$entry.key
            resourceType = [string]$entry.resourceType
            name = [string]$entry.name
            path = [string]$entry.path
            evidence = [string]$entry.evidence
            decision = [string]$entry.decision
            note = [string]$entry.note
            allowedDecisions = @(Get-LeanLaunchResourceClassificationOptions -ResourceType ([string]$entry.resourceType))
            parkWhenIdle = (Test-LeanLaunchHasProperty $entry 'parkWhenIdle') -and [bool]$entry.parkWhenIdle
            currentlyParked = $currentlyParked
        }
    }
    return @($rows | Sort-Object resourceType, name)
}

function Get-LeanLaunchApplicationSafetyWarnings {
    <#
    Surfaces the same warnings the CLI prints and the GUI displays before a run, so neither surface
    can let a user launch Managed with unreviewed resources or a missing profile without being told.
    #>
    [CmdletBinding()]
    param($Application, [string]$DataRoot)
    $warnings = New-Object System.Collections.ArrayList
    if ($Application.policy -eq 'Unmanaged') {
        [void]$warnings.Add('Unmanaged: LeanLaunch will not start, stop, or clean up anything for this application.')
        return @($warnings)
    }
    if ([string]::IsNullOrWhiteSpace([string]$Application.profileName)) {
        [void]$warnings.Add('Managed but no profile exists yet. Review resources and build a profile before running.')
    }
    if ($null -eq $Application.currentAudit) {
        [void]$warnings.Add('No before/after audit has been captured yet for this application.')
    }
    else {
        $unreviewed = @($Application.currentAudit.classifications | Where-Object { [string]$_.decision -eq 'Unreviewed' }).Count
        if ($unreviewed -gt 0) { [void]$warnings.Add("$unreviewed discovered resource(s) have not been reviewed yet.") }
        if ([string]::IsNullOrWhiteSpace([string]$Application.currentAudit.afterSnapshot)) {
            [void]$warnings.Add('A before-install baseline was captured but the after-install scan has not run yet.')
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Application.profileName) -and
            -not (Test-LeanLaunchApplicationProfileBindingValid -Application $Application -DataRoot $DataRoot)) {
            [void]$warnings.Add('The bound profile no longer matches the current audit evidence and must be regenerated.')
        }
    }
    return @($warnings)
}

function Get-LeanLaunchRunPlanSummaryLines {
    <#
    Renders a run plan (or an Unmanaged pass-through) as human-readable lines for a dry-run/action
    plan view, shared by CLI text output and the GUI's plan panel.
    #>
    [CmdletBinding()]
    param($Plan, [string]$Policy = 'Managed')
    $lines = New-Object System.Collections.ArrayList
    if ($Policy -eq 'Unmanaged') {
        [void]$lines.Add('Policy: Unmanaged - LeanLaunch will launch the executable directly and take no other action.')
        return @($lines)
    }
    [void]$lines.Add("Profile: $($Plan.profile)")
    [void]$lines.Add("Executable: $($Plan.executable)")
    if (@($Plan.servicesToStart).Count -gt 0) { [void]$lines.Add('Services to start: ' + (@($Plan.servicesToStart) -join ', ')) }
    else { [void]$lines.Add('Services to start: none') }
    if (@($Plan.servicesAlreadyRunning).Count -gt 0) { [void]$lines.Add('Services already running (left alone): ' + (@($Plan.servicesAlreadyRunning) -join ', ')) }
    if (@($Plan.residualProcessRules).Count -gt 0) {
        [void]$lines.Add('Residual process rules: ' + ((@($Plan.residualProcessRules) | ForEach-Object { "$($_.name) ($($_.executablePath))" }) -join '; '))
    }
    else {
        [void]$lines.Add('Residual process rules: none')
    }
    return @($lines)
}
