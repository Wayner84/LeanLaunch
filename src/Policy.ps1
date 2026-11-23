Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-LeanLaunchApplicationPolicy {
    param([string]$Policy)
    return $Policy -in @('Managed', 'Unmanaged')
}

function Get-LeanLaunchResourceClassificationOptions {
    param([Parameter(Mandatory = $true)][string]$ResourceType)
    switch ($ResourceType) {
        'Service' { return @('Unreviewed', 'Managed', 'Unmanaged') }
        'Process' { return @('Unreviewed', 'Managed', 'Unmanaged') }
        'StartupEntry' { return @('Unreviewed', 'Reviewed') }
        'ScheduledTask' { return @('Unreviewed', 'Reviewed') }
        default { throw "Unknown resource type: $ResourceType" }
    }
}

function New-LeanLaunchAuditRecord {
    [pscustomobject]@{
        auditId = [Guid]::NewGuid().ToString()
        beforeSnapshot = $null
        afterSnapshot = $null
        auditPath = $null
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        completedAtUtc = $null
        classifications = @()
    }
}

function Invoke-LeanLaunchServiceParkingActivation {
    <#
    Parks every Managed service explicitly opted in via parkWhenIdle as a safe stop+disable
    transaction: records its live start mode AND running state, identity-bound-stops it first if it
    is currently running, then disables it only once it is confirmed stopped. A service already
    tracked and currently parked is left alone (idempotent re-activation). Never touches a service
    outside this application's own Managed+opted-in set.
    Atomic: this function is only ever reached while trying to become Managed, so if any service in
    this batch cannot be parked, every service newly parked earlier in the same call is restored
    (start mode, and restarted if it was originally running) before the error propagates - a failed
    activation must never leave an Unmanaged-looking application with a disabled or stopped service
    behind.
    #>
    param(
        [Parameter(Mandatory = $true)]$Application,
        [hashtable]$Adapter
    )
    $toPark = @($Application.currentAudit.classifications | Where-Object {
        [string]$_.resourceType -eq 'Service' -and [string]$_.decision -eq 'Managed' -and
        (Test-LeanLaunchHasProperty $_ 'parkWhenIdle') -and $_.parkWhenIdle
    })
    if ($toPark.Count -eq 0) { return }
    if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
    if ($Adapter.ContainsKey('IsAdministrator') -and -not (& $Adapter.IsAdministrator)) {
        throw 'Idle-parking a service requires administrator rights. Run PowerShell as Administrator, or disable idle parking for this service.'
    }
    $parkedServices = New-Object System.Collections.ArrayList
    foreach ($existing in @($Application.parkedServices)) { [void]$parkedServices.Add($existing) }
    $newlyParkedThisCall = New-Object System.Collections.ArrayList
    try {
        foreach ($item in $toPark) {
            $serviceName = [string]$item.name
            $tracked = $parkedServices | Where-Object { [string]$_.name -eq $serviceName } | Select-Object -First 1
            if ($null -ne $tracked -and $tracked.currentlyParked) { continue }
            $originalStartMode = & $Adapter.GetServiceStartMode $serviceName
            if ([string]::IsNullOrWhiteSpace($originalStartMode)) {
                throw "Cannot park service '$serviceName': unable to determine its current start mode."
            }
            $liveService = & $Adapter.GetService $serviceName
            $originalWasRunning = (Get-LeanLaunchServiceStatus $liveService) -eq 'Running'
            if ($originalWasRunning) {
                $liveProcessId = Get-LeanLaunchServiceProcessId $liveService
                if ($liveProcessId -le 0) {
                    throw "Cannot park service '$serviceName': it is running but reports no process ID to bind the stop to."
                }
                $liveCreationTime = Get-LeanLaunchAdapterProcessCreationTime -Adapter $Adapter -ProcessId $liveProcessId
                & $Adapter.StopService $serviceName $liveProcessId $liveCreationTime
            }
            & $Adapter.SetServiceStartMode $serviceName $originalStartMode 'Disabled'
            if ($null -ne $tracked) {
                $tracked.originalStartMode = $originalStartMode
                $tracked.originalWasRunning = $originalWasRunning
                $tracked.parkedAtUtc = [DateTime]::UtcNow.ToString('o')
                $tracked.currentlyParked = $true
            }
            else {
                $tracked = [pscustomobject]@{
                    name = $serviceName
                    originalStartMode = $originalStartMode
                    originalWasRunning = $originalWasRunning
                    parkedAtUtc = [DateTime]::UtcNow.ToString('o')
                    currentlyParked = $true
                }
                [void]$parkedServices.Add($tracked)
            }
            [void]$newlyParkedThisCall.Add($tracked)
        }
    }
    catch {
        $originalError = $_
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $newlyParkedThisCall) {
            try {
                & $Adapter.SetServiceStartMode ([string]$entry.name) 'Disabled' ([string]$entry.originalStartMode)
                if ((Test-LeanLaunchHasProperty $entry 'originalWasRunning') -and $entry.originalWasRunning) {
                    & $Adapter.StartService ([string]$entry.name) | Out-Null
                }
                $entry.currentlyParked = $false
            }
            catch {
                # Rollback for this entry did not provably succeed - leave currentlyParked as-is
                # (still true) rather than falsely claiming it is safely back to Unmanaged, and record
                # the failure so it is surfaced below instead of silently discarded.
                [void]$rollbackFailures.Add("$($entry.name) ($($_.Exception.Message))")
            }
        }
        if ($rollbackFailures.Count -gt 0) {
            throw "Failed to park service(s) ($($originalError.Exception.Message)), and rollback could not fully restore: $($rollbackFailures -join '; '). These services may still be disabled/stopped even though the application record was never saved as Managed. Manual verification required."
        }
        throw
    }
    finally {
        $Application.parkedServices = @($parkedServices)
    }
}

function Invoke-LeanLaunchServiceReparkPhysical {
    <#
    Physical undo of a single service's "restore" step (start-mode change back to running-capable,
    and StartService if it had been started) when the application-record save meant to PERSIST that
    restore failed for any reason - stops the service (identity-bound, via its live PID/creation time,
    exactly like a normal park) if it is now running, then re-disables it, so the live service and the
    still-unchanged-on-disk "currently parked" record can never disagree.
    Never throws: returns $true if the physical re-park fully succeeded, $false otherwise. The caller
    is already inside a failure path about to re-throw (or report) the original persistence error, and
    a failed rollback attempt must never replace or hide it by throwing here - but the caller MUST
    check the return value and surface a failed rollback rather than assuming success and marking the
    entry parked again.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$OriginalStartMode,
        [Parameter(Mandatory = $true)][hashtable]$Adapter
    )
    try {
        $liveService = & $Adapter.GetService $ServiceName
        if ((Get-LeanLaunchServiceStatus $liveService) -eq 'Running') {
            $liveProcessId = Get-LeanLaunchServiceProcessId $liveService
            if ($liveProcessId -gt 0) {
                $liveCreationTime = Get-LeanLaunchAdapterProcessCreationTime -Adapter $Adapter -ProcessId $liveProcessId
                & $Adapter.StopService $ServiceName $liveProcessId $liveCreationTime
            }
        }
        & $Adapter.SetServiceStartMode $ServiceName $OriginalStartMode 'Disabled'
        return $true
    }
    catch { return $false }
}

function Get-LeanLaunchApplicationRawContentOrNull {
    <# Reads an application record's CURRENT raw on-disk JSON (or $null if absent), for use as a
    freshly re-established -ExpectedCurrentContent CAS baseline immediately before a save - never a
    stale value captured earlier and potentially invalidated by this same caller's own intervening
    writes (for example a batch of per-service saves, each of which must re-baseline against what the
    PREVIOUS iteration of the SAME batch actually just wrote, not a value read before the batch began). #>
    param([Parameter(Mandatory = $true)][string]$Name, [string]$DataRoot)
    $path = Join-Path (Get-LeanLaunchPaths -DataRoot $DataRoot).Apps ($Name + '.json')
    if (Test-Path -LiteralPath $path -PathType Leaf) { return Get-Content -LiteralPath $path -Raw }
    return $null
}

function Invoke-LeanLaunchServiceParkingDeactivation {
    <#
    Restores every currently-parked service to its recorded original start mode - and, if it was
    running when parking stopped it, restarts it - then clears the parked flag. Called whenever an
    application leaves Managed policy, whether by explicit request or by an automatic
    profile-invalidation flip to Unmanaged. A service is only marked restored, and only persisted,
    once both steps (start-mode restore and any required restart) have actually succeeded - "restored"
    means the service is back in its full original state, not merely no longer Disabled.

    The caller supplies the raw application bytes captured by the read that produced $Application.
    That baseline is carried across the complete physical-mutation/write transaction and advanced only
    from the exact bytes this function itself successfully committed. It is never re-read from disk and
    thereby cannot bless a concurrent update as the expected state.
    #>
    param(
        [Parameter(Mandatory = $true)]$Application,
        [hashtable]$Adapter,
        [string]$DataRoot,
        [ref]$ExpectedCurrentContent
    )
    $parked = @($Application.parkedServices | Where-Object { $_.currentlyParked })
    if ($parked.Count -eq 0) { return }
    if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
    if ($Adapter.ContainsKey('IsAdministrator') -and -not (& $Adapter.IsAdministrator)) {
        throw 'Restoring a parked service requires administrator rights. Run PowerShell as Administrator.'
    }
    foreach ($entry in $parked) {
        try {
            & $Adapter.SetServiceStartMode ([string]$entry.name) 'Disabled' ([string]$entry.originalStartMode)
            if ((Test-LeanLaunchHasProperty $entry 'originalWasRunning') -and $entry.originalWasRunning) {
                & $Adapter.StartService ([string]$entry.name) | Out-Null
            }
        }
        catch {
            throw "Failed to restore service '$($entry.name)' to its original state ($($_.Exception.Message))."
        }
        $entry.currentlyParked = $false
        if (-not [string]::IsNullOrWhiteSpace($DataRoot)) {
            if ($null -eq $ExpectedCurrentContent) { throw 'A read-time application content baseline is required for persisted service deactivation.' }
            $committedContent = $null
            try {
                Save-LeanLaunchApplication -Application $Application -DataRoot $DataRoot -ExpectedCurrentContent $ExpectedCurrentContent.Value -CommittedContent ([ref]$committedContent) | Out-Null
                $ExpectedCurrentContent.Value = $committedContent
            }
            catch {
                $originalError = $_
                $rolledBack = Invoke-LeanLaunchServiceReparkPhysical -ServiceName ([string]$entry.name) -OriginalStartMode ([string]$entry.originalStartMode) -Adapter $Adapter
                if ($rolledBack) {
                    $entry.currentlyParked = $true
                    throw
                }
                throw "Failed to persist restored state for service '$($entry.name)' ($($originalError.Exception.Message)), and the physical rollback to re-park it also failed; the live service and the persisted record may now disagree for '$($entry.name)'. Manual verification required."
            }
        }
    }
}

function Invoke-LeanLaunchApplicationPolicyDeactivation {
    <#
    The single place that forces an application record back to a safe Unmanaged state and clears its
    profile binding. Every invalidation path (fresh baseline, changed classification, forged binding)
    must call this instead of inlining the reset, so idle-service unpark/restore always happens
    wherever the binding is invalidated.
    #>
    param(
        [Parameter(Mandatory = $true)]$Application,
        [hashtable]$Adapter,
        [string]$DataRoot,
        [ref]$ExpectedCurrentContent
    )
    $Application.policy = 'Unmanaged'
    $Application.profileName = $null
    $Application.profileAuditId = $null
    Invoke-LeanLaunchServiceParkingDeactivation -Application $Application -Adapter $Adapter -DataRoot $DataRoot -ExpectedCurrentContent $ExpectedCurrentContent
}

function Save-LeanLaunchApplication {
    <#
    -ExpectedCurrentContent (optional; omit for a plain overwrite, matching every pre-existing
    caller's behavior exactly) makes this a compare-and-swap write: the destination's current
    on-disk content is re-verified immediately before the atomic swap, and the write is refused if it
    no longer matches - closing the lost-update race between an earlier read (e.g.
    Import-LeanLaunchApplicationForUpdate) and this write in the same application/audit record.
    -TestHookBeforeCommit is a test-only seam passed straight through to Write-LeanLaunchJsonAtomic: it
    fires after the new content is staged but immediately before the CAS check/commit, so a test can
    simulate a concurrent external write landing in that exact window. $null (the default) in every
    production call site.
    #>
    param([Parameter(Mandatory = $true)]$Application, [string]$DataRoot, [AllowNull()]$ExpectedCurrentContent, [scriptblock]$TestHookBeforeCommit, [ref]$CommittedContent)
    if (-not (Test-LeanLaunchHasProperty $Application 'name') -or -not (Test-LeanLaunchProfileName ([string]$Application.name))) {
        throw 'Application record has an invalid name.'
    }
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
    $Application.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $appsRoot = [IO.Path]::GetFullPath($paths.Apps).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $paths.Apps ($Application.name + '.json')))
    if (-not $path.StartsWith($appsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Application record path escapes the applications directory.'
    }
    $requireUnchanged = $PSBoundParameters.ContainsKey('ExpectedCurrentContent')
    $writeResult = Write-LeanLaunchJsonAtomic -Path $path -InputObject $Application -Depth 12 -RequireUnchanged:$requireUnchanged -ExpectedCurrentContent $ExpectedCurrentContent -TestHookBeforeCommit $TestHookBeforeCommit
    if ($PSBoundParameters.ContainsKey('CommittedContent')) { $CommittedContent.Value = $writeResult.Content }
    return $path
}

function New-LeanLaunchApplication {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string]$DataRoot,
        [switch]$Force
    )
    if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Application name is invalid.' }
    $executable = Expand-LeanLaunchValue $Executable
    if ([string]::IsNullOrWhiteSpace($executable)) { throw 'Application executable is required.' }
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $path = Join-Path $paths.Apps ($Name + '.json')
    if ((Test-Path -LiteralPath $path) -and -not $Force) { throw "Application already exists: $path" }
    if (-not $PSCmdlet.ShouldProcess($path, 'Create LeanLaunch application record')) { return $null }
    $application = [pscustomobject]@{
        schemaVersion = 1
        name = $Name
        displayName = if ([string]::IsNullOrWhiteSpace($DisplayName)) { $Name } else { $DisplayName }
        executable = $executable
        policy = 'Unmanaged'
        profileName = $null
        profileAuditId = $null
        profileContentHash = $null
        currentAudit = $null
        auditHistory = @()
        parkedServices = @()
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot | Out-Null
    return $application
}
