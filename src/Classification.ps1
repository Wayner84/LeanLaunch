Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-LeanLaunchApplicationBeforeSnapshot {
    <#
    Always captures a brand-new snapshot rather than accepting an existing snapshot name, so a
    "before" baseline cannot be an accidentally stale or reused capture. Any unfinished or previously
    completed audit for this application is archived into history first - evidence is retained, never
    silently discarded.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DataRoot,
        [hashtable]$Collectors,
        [hashtable]$Adapter
    )
    $loaded = Import-LeanLaunchApplicationForUpdate -Name $Name -DataRoot $DataRoot
    $application = $loaded.Application
    $expectedContent = [ref]$loaded.RawContent
    if (-not $PSCmdlet.ShouldProcess($Name, 'Capture a fresh before-install baseline snapshot')) { return $null }
    $snapshot = New-LeanLaunchSnapshot -Collectors $Collectors
    if (@($snapshot.collectionErrors).Count -gt 0) {
        throw "Refusing to start a new audit for '$Name': the before-install collectors reported errors. Fix the collector failures and try again."
    }
    # Deactivate before mutating audit history so any per-service persistence contains only the policy
    # transition, never a partially prepared new audit.
    Invoke-LeanLaunchApplicationPolicyDeactivation -Application $application -Adapter $Adapter -DataRoot $DataRoot -ExpectedCurrentContent $expectedContent
    if ($null -ne $application.currentAudit) {
        $application.auditHistory = @($application.auditHistory) + @($application.currentAudit)
    }
    $safePrefix = $Name.Substring(0, [Math]::Min($Name.Length, 28))
    $uniqueSuffix = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $snapshotName = ($safePrefix + '-before-' + $uniqueSuffix)
    Save-LeanLaunchSnapshot -Snapshot $snapshot -Name $snapshotName -DataRoot $DataRoot | Out-Null
    $audit = New-LeanLaunchAuditRecord
    $audit.beforeSnapshot = $snapshotName
    $application.currentAudit = $audit
    Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot -ExpectedCurrentContent $expectedContent.Value | Out-Null
    return [pscustomobject]@{ application = $application; snapshotName = $snapshotName; snapshot = $snapshot }
}

function Get-LeanLaunchAuditCandidates {
    <#
    Surfaces evidence only; nothing here implies a resource is safe to touch. Process candidates are
    limited to groups whose instance count increased (new persistent consumers), service candidates
    are every meaningful status/start-type change the diff already found, and every added startup
    entry / scheduled task is surfaced for review-only classification.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Diff)
    $candidates = New-Object System.Collections.ArrayList
    foreach ($item in @($Diff.processChanges | Where-Object { [int]$_.countDelta -gt 0 })) {
        [void]$candidates.Add([pscustomobject]@{
            key = ('Process|' + ([string]$item.name).ToLowerInvariant() + '|' + ([string]$item.path).ToLowerInvariant())
            resourceType = 'Process'
            name = [string]$item.name
            path = [string]$item.path
            evidence = "New instances: +$($item.countDelta) (now $($item.afterCount))"
        })
    }
    foreach ($item in @($Diff.serviceChanges)) {
        [void]$candidates.Add([pscustomobject]@{
            key = ('Service|' + ([string]$item.name).ToLowerInvariant())
            resourceType = 'Service'
            name = [string]$item.name
            path = $null
            evidence = "Status $($item.beforeStatus) -> $($item.afterStatus); start type $($item.beforeStartType) -> $($item.afterStartType)"
        })
    }
    foreach ($item in @($Diff.addedStartupEntries)) {
        [void]$candidates.Add([pscustomobject]@{
            key = ('StartupEntry|' + ([string]$item.location).ToLowerInvariant() + '|' + ([string]$item.name).ToLowerInvariant())
            resourceType = 'StartupEntry'
            name = [string]$item.name
            path = [string]$item.command
            evidence = "New startup entry at $($item.location) for user $($item.user)"
        })
    }
    foreach ($item in @($Diff.addedScheduledTasks)) {
        [void]$candidates.Add([pscustomobject]@{
            key = ('ScheduledTask|' + ([string]$item.taskPath).ToLowerInvariant() + '|' + ([string]$item.taskName).ToLowerInvariant())
            resourceType = 'ScheduledTask'
            name = [string]$item.taskName
            path = [string]$item.taskPath
            evidence = "New scheduled task, state $($item.state)"
        })
    }
    return @($candidates)
}

function Complete-LeanLaunchApplicationAudit {
    <#
    Each before-install baseline is single-use for completion: once this audit has already been
    completed (completedAtUtc is set), calling this again against the SAME currentAudit is refused -
    the only way to capture new after-install evidence is a fresh before-install baseline via
    New-LeanLaunchApplicationBeforeSnapshot, which always mints a brand-new auditId and (already)
    unconditionally deactivates any bound profile/Managed policy. This is what makes new evidence and
    an old runnable profile/Managed policy structurally unable to coexist: there is no path from
    "already-completed audit" back to "current audit" without first invalidating the binding.
    A reviewer's prior decision for a resource that reappears is still carried forward, but from the
    immediately preceding archived audit in auditHistory - never from this (always freshly empty,
    not-yet-completed) currentAudit - since that is the only source that can legitimately hold it once
    reuse of the live currentAudit itself is refused.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DataRoot,
        [hashtable]$Collectors
    )
    $loaded = Import-LeanLaunchApplicationForUpdate -Name $Name -DataRoot $DataRoot
    $application = $loaded.Application
    if ($null -eq $application.currentAudit -or [string]::IsNullOrWhiteSpace([string]$application.currentAudit.beforeSnapshot)) {
        throw "No before-install baseline is active for '$Name'. Capture a before snapshot first."
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$application.currentAudit.completedAtUtc)) {
        throw "The before-install baseline for '$Name' has already been used to complete an audit. Capture a fresh before-install baseline to rescan."
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Capture the after-install snapshot and compute the diff')) { return $null }
    $before = Import-LeanLaunchSnapshot -Name $application.currentAudit.beforeSnapshot -DataRoot $DataRoot
    $afterSnapshot = New-LeanLaunchSnapshot -Collectors $Collectors
    if (@($afterSnapshot.collectionErrors).Count -gt 0) {
        throw "Refusing to complete the audit for '$Name': the after-install collectors reported errors. Fix the collector failures and try again."
    }
    $safePrefix = $Name.Substring(0, [Math]::Min($Name.Length, 28))
    $uniqueSuffix = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $snapshotName = ($safePrefix + '-after-' + $uniqueSuffix)
    Save-LeanLaunchSnapshot -Snapshot $afterSnapshot -Name $snapshotName -DataRoot $DataRoot | Out-Null
    $diff = Compare-LeanLaunchSnapshot -Before $before -After $afterSnapshot

    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    New-Item -ItemType Directory -Path $paths.Audits -Force | Out-Null
    $auditPath = Join-Path $paths.Audits ($snapshotName + '.json')
    Write-LeanLaunchJsonAtomic -Path $auditPath -InputObject $diff -Depth 12 | Out-Null

    $priorAudit = @($application.auditHistory) | Select-Object -Last 1
    $existingByKey = @{}
    if ($null -ne $priorAudit) {
        foreach ($entry in @($priorAudit.classifications)) { $existingByKey[[string]$entry.key] = $entry }
    }
    $classifications = New-Object System.Collections.ArrayList
    foreach ($candidate in @(Get-LeanLaunchAuditCandidates -Diff $diff)) {
        if ($existingByKey.ContainsKey($candidate.key)) {
            [void]$classifications.Add($existingByKey[$candidate.key])
        }
        else {
            [void]$classifications.Add([pscustomobject]@{
                key = $candidate.key; resourceType = $candidate.resourceType; name = $candidate.name; path = $candidate.path
                evidence = $candidate.evidence; decision = 'Unreviewed'; note = ''; updatedAtUtc = [DateTime]::UtcNow.ToString('o')
                parkWhenIdle = $false
            })
        }
    }

    $application.currentAudit.afterSnapshot = $snapshotName
    $application.currentAudit.auditPath = $auditPath
    $application.currentAudit.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    $application.currentAudit.classifications = @($classifications)
    Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot -ExpectedCurrentContent $loaded.RawContent | Out-Null
    return [pscustomobject]@{ application = $application; diff = $diff; auditPath = $auditPath }
}

function Set-LeanLaunchResourceClassification {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Decision,
        [string]$Note,
        [string]$DataRoot,
        [hashtable]$Adapter
    )
    $loaded = Import-LeanLaunchApplicationForUpdate -Name $Name -DataRoot $DataRoot
    $application = $loaded.Application
    $expectedContent = [ref]$loaded.RawContent
    if ($null -eq $application.currentAudit) { throw "No active audit for '$Name'." }
    $entry = @($application.currentAudit.classifications) | Where-Object { [string]$_.key -eq $Key } | Select-Object -First 1
    if ($null -eq $entry) { throw "No classification candidate with key '$Key' for '$Name'." }
    $allowed = Get-LeanLaunchResourceClassificationOptions -ResourceType ([string]$entry.resourceType)
    if ($allowed -notcontains $Decision) {
        throw "Decision '$Decision' is not valid for resource type '$($entry.resourceType)'. Allowed: $($allowed -join ', ')"
    }
    if (-not $PSCmdlet.ShouldProcess("$Name/$Key", "Set classification to $Decision")) { return $null }
    $decisionChanged = ([string]$entry.decision -ne $Decision)
    if ($decisionChanged -and -not [string]::IsNullOrWhiteSpace([string]$application.profileName)) {
        Invoke-LeanLaunchApplicationPolicyDeactivation -Application $application -Adapter $Adapter -DataRoot $DataRoot -ExpectedCurrentContent $expectedContent
    }
    $entry.decision = $Decision
    $entry.note = [string]$Note
    $entry.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot -ExpectedCurrentContent $expectedContent.Value | Out-Null
    return $application
}

function Set-LeanLaunchServiceParkingPreference {
    <#
    Marks a single Service classification entry for idle parking. Only ever settable on a service
    already classified Managed - the same Get-LeanLaunchResourceClassificationOptions gate that
    keeps StartupEntry/ScheduledTask from ever becoming Managed also keeps them from ever acquiring
    parkWhenIdle, since neither resource type can reach the Managed decision in the first place.

    Turning idle parking OFF for a service that is currently, actually parked (disabled) restores it
    immediately, regardless of the application's policy - a user asking LeanLaunch to stop idling a
    service must not leave it disabled indefinitely just because the application happens to still be
    Managed. Turning it ON has no immediate effect on any real service: activation only ever happens
    through the already review-gated Set-LeanLaunchApplicationPolicy -Policy Managed transition, so a
    preference change alone can never be the thing that disables a live Windows service.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][bool]$ParkWhenIdle,
        [string]$DataRoot,
        [hashtable]$Adapter,
        # Test-only seam: fires immediately before this operation's own commit/CAS check, i.e. exactly
        # between its internal read (Import-LeanLaunchApplicationForUpdate above) and its internal
        # write below, so a test can simulate a concurrent external record change landing in that
        # precise window. $null (the default) in every production call site.
        [scriptblock]$TestHookBeforeCommit
    )
    $loaded = Import-LeanLaunchApplicationForUpdate -Name $Name -DataRoot $DataRoot
    $application = $loaded.Application
    if ($null -eq $application.currentAudit) { throw "No active audit for '$Name'." }
    $entry = @($application.currentAudit.classifications) | Where-Object { [string]$_.key -eq $Key } | Select-Object -First 1
    if ($null -eq $entry) { throw "No classification candidate with key '$Key' for '$Name'." }
    if ([string]$entry.resourceType -ne 'Service') {
        throw "Idle parking can only be set for a Service resource, not '$($entry.resourceType)'."
    }
    if ($ParkWhenIdle -and [string]$entry.decision -ne 'Managed') {
        throw "Idle parking can only be enabled for a service currently classified Managed."
    }
    $liveParkedEntry = $null
    if (-not $ParkWhenIdle) {
        $liveParkedEntry = @($application.parkedServices) | Where-Object { [string]$_.name -eq [string]$entry.name -and $_.currentlyParked } | Select-Object -First 1
        if ($null -ne $liveParkedEntry) {
            if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
            if ($Adapter.ContainsKey('IsAdministrator') -and -not (& $Adapter.IsAdministrator)) {
                throw 'Restoring a parked service requires administrator rights. Run PowerShell as Administrator.'
            }
        }
    }
    if (-not $PSCmdlet.ShouldProcess("$Name/$Key", "Set idle parking to $ParkWhenIdle")) { return $null }
    if (-not (Test-LeanLaunchHasProperty $entry 'parkWhenIdle')) {
        $entry | Add-Member -MemberType NoteProperty -Name 'parkWhenIdle' -Value $false -Force
    }
    $originalParkWhenIdle = [bool]$entry.parkWhenIdle
    $entry.parkWhenIdle = $ParkWhenIdle
    if ($null -ne $liveParkedEntry) {
        & $Adapter.SetServiceStartMode ([string]$liveParkedEntry.name) 'Disabled' ([string]$liveParkedEntry.originalStartMode)
        $liveParkedEntry.currentlyParked = $false
        # Full-state restoration, matching Invoke-LeanLaunchServiceParkingDeactivation: a service that
        # was actually RUNNING when parking stopped it must be restarted here too, not merely
        # re-enabled at the OS start-mode level and left stopped.
        if ((Test-LeanLaunchHasProperty $liveParkedEntry 'originalWasRunning') -and $liveParkedEntry.originalWasRunning) {
            & $Adapter.StartService ([string]$liveParkedEntry.name) | Out-Null
        }
    }
    try {
        Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot -ExpectedCurrentContent $loaded.RawContent -TestHookBeforeCommit $TestHookBeforeCommit | Out-Null
    }
    catch {
        # Persistence failed after the service (if any) was already restored - roll everything back
        # to the state the still-unchanged disk record continues to claim, so a live service and its
        # persisted record can never diverge into a torn state, then re-throw so the caller knows the
        # request did not complete.
        $originalError = $_
        $entry.parkWhenIdle = $originalParkWhenIdle
        if ($null -ne $liveParkedEntry) {
            $rolledBack = Invoke-LeanLaunchServiceReparkPhysical -ServiceName ([string]$liveParkedEntry.name) -OriginalStartMode ([string]$liveParkedEntry.originalStartMode) -Adapter $Adapter
            if ($rolledBack) {
                $liveParkedEntry.currentlyParked = $true
                throw
            }
            throw "Failed to persist the idle-parking preference change for '$($liveParkedEntry.name)' ($($originalError.Exception.Message)), and the physical rollback to re-park it also failed; the live service and the persisted record may now disagree for '$($liveParkedEntry.name)'. Manual verification required."
        }
        throw
    }
    return $application
}

function New-LeanLaunchApplicationProfile {
    <#
    Builds a profile file from only the resources an operator explicitly marked Managed during
    review. Unreviewed or Unmanaged candidates are never included - silence is not consent.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DataRoot,
        [switch]$Force
    )
    $loaded = Import-LeanLaunchApplicationForUpdate -Name $Name -DataRoot $DataRoot
    $application = $loaded.Application
    if ($null -eq $application.currentAudit) { throw "No audit evidence exists yet for '$Name'. Run a before/after scan first." }
    if ([string]::IsNullOrWhiteSpace([string]$application.currentAudit.afterSnapshot)) {
        throw "No after-install scan has completed yet for '$Name'. Complete the after-install audit first."
    }
    $classifications = @($application.currentAudit.classifications)
    if (@($classifications | Where-Object { [string]$_.decision -eq 'Unreviewed' }).Count -gt 0) {
        throw "Every discovered resource for '$Name' must be reviewed before a profile can be generated."
    }
    $services = @($classifications | Where-Object { $_.resourceType -eq 'Service' -and $_.decision -eq 'Managed' } | ForEach-Object { [string]$_.name })
    $residual = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    foreach ($item in @($classifications | Where-Object { $_.resourceType -eq 'Process' -and $_.decision -eq 'Managed' })) {
        if ([string]::IsNullOrWhiteSpace([string]$item.path)) { [void]$skipped.Add([string]$item.name); continue }
        [void]$residual.Add([ordered]@{ name = [string]$item.name; executablePath = [string]$item.path })
    }

    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $path = Join-Path $paths.Profiles ($Name + '.json')
    if ((Test-Path -LiteralPath $path) -and -not $Force) { throw "Profile already exists: $path" }
    if (-not $PSCmdlet.ShouldProcess($path, 'Create LeanLaunch profile from reviewed resources')) { return $null }

    New-Item -ItemType Directory -Path $paths.Profiles -Force | Out-Null
    $profile = [ordered]@{
        schemaVersion = 1
        name = $Name
        displayName = [string]$application.displayName
        executable = [string]$application.executable
        arguments = @()
        workingDirectory = ''
        services = @($services)
        residualProcesses = @($residual)
        waitForProcessNames = @()
        cleanup = [ordered]@{ stopStartedServices = $true; stopResidualProcesses = $true }
    }
    # ContentHash comes back from the write itself - computed from the exact in-memory bytes handed
    # to the OS, never from a separate post-write read of $path. A separate read would be exactly the
    # generation-time TOCTOU this closes: a replacement landing between the write completing and a
    # later re-read could get its OWN hash recorded as if it were this generation's trusted binding.
    $writeResult = Write-LeanLaunchJsonAtomic -Path $path -InputObject $profile -Depth 8
    $application.profileName = $Name
    $application.profileAuditId = [string]$application.currentAudit.auditId
    $application.profileContentHash = $writeResult.ContentHash
    Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot -ExpectedCurrentContent $loaded.RawContent | Out-Null
    return [pscustomobject]@{ path = (Get-Item -LiteralPath $path); application = $application; skippedResidualProcesses = @($skipped) }
}
