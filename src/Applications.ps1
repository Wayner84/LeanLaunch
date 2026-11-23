Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-LeanLaunchClassificationEntryValid {
    <#
    Strictly validates one audit classification candidate: required properties, exact runtime types
    (no coercion), a resourceType/decision pair that is actually in the allowed vocabulary, and - for
    a Service entry specifically - a name that would pass the same syntax gate native service control
    enforces, since a parked or profiled service name reaches an adapter call directly. Hand-editing
    this array to add or reshape a Managed candidate produces a record that fails to load rather than
    one that silently expands what Managed execution is allowed to touch.
    #>
    param($Entry, [string]$ObjectDescription = 'Classification entry')
    Test-LeanLaunchRequiredProperties $Entry @('key','resourceType','name','path','evidence','decision','note','updatedAtUtc') $ObjectDescription
    Test-LeanLaunchPropertyType $Entry 'key' 'String' $ObjectDescription
    if ([string]::IsNullOrWhiteSpace([string]$Entry.key)) { throw "$ObjectDescription has an empty key." }
    Test-LeanLaunchPropertyType $Entry 'resourceType' 'String' $ObjectDescription
    $allowedDecisions = $null
    try { $allowedDecisions = Get-LeanLaunchResourceClassificationOptions -ResourceType ([string]$Entry.resourceType) }
    catch { throw "$ObjectDescription has an unknown resourceType '$($Entry.resourceType)'." }
    Test-LeanLaunchPropertyType $Entry 'name' 'String' $ObjectDescription
    if ([string]::IsNullOrWhiteSpace([string]$Entry.name)) { throw "$ObjectDescription has an empty name." }
    if ([string]$Entry.resourceType -eq 'Service' -and -not (Test-LeanLaunchServiceName ([string]$Entry.name))) {
        throw "$ObjectDescription has an invalid service name."
    }
    if ($null -ne $Entry.path -and $Entry.path -isnot [string]) { throw "$ObjectDescription property 'path' must be a string or null." }
    Test-LeanLaunchPropertyType $Entry 'evidence' 'String' $ObjectDescription
    Test-LeanLaunchPropertyType $Entry 'decision' 'String' $ObjectDescription
    if ($allowedDecisions -notcontains [string]$Entry.decision) {
        throw "$ObjectDescription has decision '$($Entry.decision)', not valid for resourceType '$($Entry.resourceType)'."
    }
    Test-LeanLaunchPropertyType $Entry 'note' 'String' $ObjectDescription
    if ($null -ne $Entry.updatedAtUtc -and $Entry.updatedAtUtc -isnot [string]) { throw "$ObjectDescription property 'updatedAtUtc' must be a string or null." }
    if (Test-LeanLaunchHasProperty $Entry 'parkWhenIdle') {
        Test-LeanLaunchPropertyType $Entry 'parkWhenIdle' 'Bool' $ObjectDescription
        if ([bool]$Entry.parkWhenIdle -and [string]$Entry.resourceType -ne 'Service') {
            throw "$ObjectDescription cannot have parkWhenIdle set for resourceType '$($Entry.resourceType)'."
        }
    }
}

function Assert-LeanLaunchAuditRecordValid {
    <#
    Strictly validates one audit record (either the live currentAudit or an archived auditHistory
    entry, which share the identical shape) and every classification candidate it carries.
    #>
    param($Audit, [string]$ObjectDescription = 'Audit record')
    Test-LeanLaunchRequiredProperties $Audit @('auditId','beforeSnapshot','afterSnapshot','auditPath','startedAtUtc','completedAtUtc','classifications') $ObjectDescription
    Test-LeanLaunchPropertyType $Audit 'auditId' 'String' $ObjectDescription
    if (-not [Guid]::TryParse([string]$Audit.auditId, [ref]([Guid]::Empty))) { throw "$ObjectDescription property 'auditId' must be a GUID." }
    Test-LeanLaunchPropertyType $Audit 'startedAtUtc' 'String' $ObjectDescription
    foreach ($nullableStringProperty in @('beforeSnapshot', 'afterSnapshot', 'auditPath', 'completedAtUtc')) {
        if ($null -ne $Audit.$nullableStringProperty -and $Audit.$nullableStringProperty -isnot [string]) {
            throw "$ObjectDescription property '$nullableStringProperty' must be a string or null."
        }
    }
    Test-LeanLaunchPropertyType $Audit 'classifications' 'Array' $ObjectDescription
    $index = 0
    foreach ($entry in @($Audit.classifications)) {
        Assert-LeanLaunchClassificationEntryValid -Entry $entry -ObjectDescription "$ObjectDescription classification entry [$index]"
        $index++
    }
}

function Assert-LeanLaunchParkedServiceEntryValid {
    <#
    A parked-service record is used directly against native service control (start-mode restore and,
    since the safe stop+disable transaction, an identity-bound stop) without ever passing through
    Import-LeanLaunchProfile's own service-name gate, so it needs the same syntax enforcement here.
    #>
    param($Entry, [string]$ObjectDescription = 'Parked-service entry')
    Test-LeanLaunchRequiredProperties $Entry @('name','originalStartMode','parkedAtUtc','currentlyParked') $ObjectDescription
    Test-LeanLaunchPropertyType $Entry 'name' 'String' $ObjectDescription
    if (-not (Test-LeanLaunchServiceName ([string]$Entry.name))) { throw "$ObjectDescription has an invalid service name." }
    Test-LeanLaunchPropertyType $Entry 'originalStartMode' 'String' $ObjectDescription
    if ([string]::IsNullOrWhiteSpace([string]$Entry.originalStartMode)) { throw "$ObjectDescription has an empty originalStartMode." }
    if ($null -ne $Entry.parkedAtUtc -and $Entry.parkedAtUtc -isnot [string]) { throw "$ObjectDescription property 'parkedAtUtc' must be a string or null." }
    Test-LeanLaunchPropertyType $Entry 'currentlyParked' 'Bool' $ObjectDescription
    if (Test-LeanLaunchHasProperty $Entry 'originalWasRunning') {
        Test-LeanLaunchPropertyType $Entry 'originalWasRunning' 'Bool' $ObjectDescription
    }
}

function Import-LeanLaunchApplication {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [string]$DataRoot)
    if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Application name is invalid.' }
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $path = Join-Path $paths.Apps ($Name + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Application not found: $Name" }
    $application = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Test-LeanLaunchRequiredProperties $application @(
        'schemaVersion','name','displayName','executable','policy','profileName','profileAuditId',
        'profileContentHash','currentAudit','auditHistory','parkedServices','createdAtUtc','updatedAtUtc'
    ) 'Application record'
    Test-LeanLaunchPropertyType $application 'schemaVersion' 'Int' 'Application record'
    if ($application.schemaVersion -ne 1) { throw 'Unsupported application schema version.' }
    Test-LeanLaunchPropertyType $application 'name' 'String' 'Application record'
    if (-not (Test-LeanLaunchProfileName ([string]$application.name)) -or
        -not ([string]$application.name).Equals($Name, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Application record name is invalid or does not match its filename.'
    }
    Test-LeanLaunchPropertyType $application 'displayName' 'String' 'Application record'
    Test-LeanLaunchPropertyType $application 'executable' 'String' 'Application record'
    Test-LeanLaunchPropertyType $application 'policy' 'String' 'Application record'
    Test-LeanLaunchPropertyType $application 'createdAtUtc' 'String' 'Application record'
    Test-LeanLaunchPropertyType $application 'updatedAtUtc' 'String' 'Application record'
    Test-LeanLaunchPropertyType $application 'auditHistory' 'Array' 'Application record'
    Test-LeanLaunchPropertyType $application 'parkedServices' 'Array' 'Application record'
    if ([string]::IsNullOrWhiteSpace([string]$application.displayName) -or [string]::IsNullOrWhiteSpace([string]$application.executable)) {
        throw 'Application displayName and executable must be non-empty strings.'
    }
    if (-not (Test-LeanLaunchApplicationPolicy ([string]$application.policy))) { throw 'Application policy is invalid.' }
    if ($null -ne $application.profileName -and
        (-not ($application.profileName -is [string]) -or -not (Test-LeanLaunchProfileName ([string]$application.profileName)))) {
        throw 'Application profileName is invalid.'
    }
    if ($null -ne $application.profileAuditId -and
        (-not ($application.profileAuditId -is [string]) -or -not ([Guid]::TryParse([string]$application.profileAuditId, [ref]([Guid]::Empty)))) ) {
        throw 'Application profileAuditId is invalid.'
    }
    if ($null -ne $application.profileContentHash -and
        (-not ($application.profileContentHash -is [string]) -or ([string]$application.profileContentHash) -notmatch '^[0-9A-Fa-f]{64}$')) {
        throw 'Application profileContentHash is invalid.'
    }
    if ($null -ne $application.currentAudit) {
        Assert-LeanLaunchAuditRecordValid -Audit $application.currentAudit -ObjectDescription 'Application currentAudit'
    }
    Test-LeanLaunchPropertyType $application 'auditHistory' 'Array' 'Application record'
    $historyIndex = 0
    foreach ($historyEntry in @($application.auditHistory)) {
        Assert-LeanLaunchAuditRecordValid -Audit $historyEntry -ObjectDescription "Application auditHistory entry [$historyIndex]"
        $historyIndex++
    }
    $parkedIndex = 0
    foreach ($parkedEntry in @($application.parkedServices)) {
        Assert-LeanLaunchParkedServiceEntryValid -Entry $parkedEntry -ObjectDescription "Application parkedServices entry [$parkedIndex]"
        $parkedIndex++
    }
    return $application
}

function Import-LeanLaunchApplicationForUpdate {
    <#
    Returns both the validated application object and the raw JSON text it was read from, so a
    caller doing a self-contained read-modify-write (no other write to this same record in between)
    can pass that exact text to Save-LeanLaunchApplication's -ExpectedCurrentContent compare-and-swap
    guard: the eventual write is refused if anything else changed the file first.
    #>
    param([Parameter(Mandatory = $true)][string]$Name, [string]$DataRoot)
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $path = Join-Path $paths.Apps ($Name + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Application not found: $Name" }
    $raw = Get-Content -LiteralPath $path -Raw
    $application = Import-LeanLaunchApplication -Name $Name -DataRoot $DataRoot
    return [pscustomobject]@{ Application = $application; RawContent = $raw }
}

function Get-LeanLaunchApplications {
    [CmdletBinding()]
    param([string]$DataRoot)
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $paths.Apps -PathType Container)) { return @() }
    $applications = foreach ($file in @(Get-ChildItem -LiteralPath $paths.Apps -Filter '*.json' -File | Sort-Object BaseName)) {
        try {
            Import-LeanLaunchApplication -Name $file.BaseName -DataRoot $DataRoot
        }
        catch {
            # A record that fails validation - corruption, a hand-edit, a partially-written file -
            # must still be visible to the operator as something needing attention. Silently dropping
            # it from the list would hide exactly the kind of tampering/drift this validation exists
            # to catch, so it is surfaced as an explicit malformed placeholder instead.
            [pscustomobject]@{
                schemaVersion = $null; name = $file.BaseName; displayName = $file.BaseName; executable = $null
                policy = $null; profileName = $null; profileAuditId = $null; profileContentHash = $null
                currentAudit = $null; auditHistory = @(); parkedServices = @()
                isMalformed = $true; malformedReason = $_.Exception.Message
            }
        }
    }
    return @($applications)
}

function Test-LeanLaunchArraysHaveSameElements {
    <#
    Case-insensitive, order-independent set equality for two string collections. Used to prove a
    generated profile's services/residual-process rules are EXACTLY the Managed-decision set the
    current audit records - no more, no less - rather than merely a matching count or a subset.
    #>
    param([string[]]$Left, [string[]]$Right)
    $leftArray = @($Left)
    $rightArray = @($Right)
    if ($leftArray.Count -ne $rightArray.Count) { return $false }
    $leftSorted = @($leftArray | Sort-Object)
    $rightSorted = @($rightArray | Sort-Object)
    for ($i = 0; $i -lt $leftSorted.Count; $i++) {
        if (-not ([string]$leftSorted[$i]).Equals([string]$rightSorted[$i], [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-LeanLaunchValidatedManagedProfile {
    <#
    The one place that reads a Managed application's bound profile from disk, for the purpose of
    either validating the binding or actually running it. Reads the file's exact bytes exactly once,
    hashes those same bytes, and strictly parses/validates that same immutable byte buffer via
    ConvertTo-LeanLaunchProfileFromContent - this function never re-opens the profile path a second
    time for any reason, and its return value (the already-validated in-memory profile object) is
    exactly what a caller must pass into Managed execution. Re-reading the path again after this
    function returns - as opposed to using its returned object directly - would reintroduce the exact
    TOCTOU gap this function exists to close: a concurrent replacement landing between this validation
    and a second, separate read could supply a completely different profile to the actual run.

    Binding-valid means the bound profile still corresponds EXACTLY to the audit that produced it,
    revalidated against the live filesystem every time this is called rather than trusted from
    in-memory state alone:
      1. A non-null profileName/currentAudit/profileAuditId, with profileAuditId matching the current
         audit's auditId (a fresh audit - New-LeanLaunchApplicationBeforeSnapshot always mints one -
         can never satisfy an old binding).
      2. Every discovered resource is reviewed (no Unreviewed candidate remains) - a stale-but-ID-
         matching audit that has since grown new, unreviewed evidence is never good enough.
      3. The profile file lives at its one expected identity - the per-user profile directory this
         application's own name resolves to, never a same-named repository template, not reached
         through a reparse point - and its exact on-disk byte content still hashes to what was
         recorded when the profile was generated.
      4. The profile's COMPLETE executable policy surface - executable, displayName, arguments,
         working directory, wait rules, cleanup flags, and the services/residual-process-rule sets -
         is structurally identical to what New-LeanLaunchApplicationProfile would deterministically
         generate right now from the application's current reviewed state. This is deliberately
         broader than a content-hash match alone: a compromised *generation* (see the TOCTOU note on
         New-LeanLaunchApplicationProfile's own write) could have recorded the hash of an
         already-malicious file, so the hash check alone is not trusted as sufficient - every field is
         independently re-derived from the application record and current audit and compared.
    Any failure - replacement, hand-edit, staleness, or a generation-time compromise - returns $null;
    callers must fail closed and must never fall back to reading the profile path themselves.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Application, [string]$DataRoot)
    if ([string]::IsNullOrWhiteSpace([string]$Application.profileName)) { return $null }
    if ($null -eq $Application.currentAudit) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Application.profileAuditId)) { return $null }
    if ([string]$Application.profileAuditId -ne [string]$Application.currentAudit.auditId) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Application.currentAudit.afterSnapshot)) { return $null }
    if (@($Application.currentAudit.classifications | Where-Object { [string]$_.decision -eq 'Unreviewed' }).Count -gt 0) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Application.profileContentHash)) { return $null }

    $expectedPath = Get-LeanLaunchApplicationBoundProfilePath -ProfileName ([string]$Application.profileName) -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) { return $null }
    try { Assert-LeanLaunchNoReparseInPath $expectedPath } catch { return $null }

    $bytes = $null
    try { $bytes = [IO.File]::ReadAllBytes($expectedPath) } catch { return $null }
    $actualHash = Get-LeanLaunchBytesHash -Bytes $bytes
    if (-not $actualHash.Equals([string]$Application.profileContentHash, [StringComparison]::OrdinalIgnoreCase)) { return $null }

    $content = [Text.Encoding]::UTF8.GetString($bytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
    $profile = $null
    try { $profile = ConvertTo-LeanLaunchProfileFromContent -Content $content -SourcePath $expectedPath -SkipExecutableCheck }
    catch { return $null }
    if (-not ([string]$profile.name).Equals([string]$Application.profileName, [StringComparison]::OrdinalIgnoreCase)) { return $null }

    # Complete executable policy surface: every field New-LeanLaunchApplicationProfile deterministically
    # controls must still match what it would generate right now, not merely services/residualProcesses.
    if (-not ([string]$profile.executable).Equals([string]$Application.executable, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not ([string]$profile.displayName).Equals([string]$Application.displayName, [StringComparison]::Ordinal)) { return $null }
    if (@($profile.arguments).Count -ne 0) { return $null }
    $expectedWorkingDirectory = Split-Path -Parent ([string]$Application.executable)
    if (-not ([string]$profile.workingDirectory).Equals([string]$expectedWorkingDirectory, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (@($profile.waitForProcessNames).Count -ne 0) { return $null }
    if (-not [bool]$profile.cleanup.stopStartedServices -or -not [bool]$profile.cleanup.stopResidualProcesses) { return $null }

    $expectedServices = @($Application.currentAudit.classifications | Where-Object {
        [string]$_.resourceType -eq 'Service' -and [string]$_.decision -eq 'Managed'
    } | ForEach-Object { [string]$_.name })
    if (-not (Test-LeanLaunchArraysHaveSameElements -Left $expectedServices -Right @($profile.services))) { return $null }

    $expectedResidual = @($Application.currentAudit.classifications | Where-Object {
        [string]$_.resourceType -eq 'Process' -and [string]$_.decision -eq 'Managed' -and -not [string]::IsNullOrWhiteSpace([string]$_.path)
    } | ForEach-Object { ([string]$_.name).ToLowerInvariant() + '|' + ([string]$_.path).ToLowerInvariant() })
    $actualResidual = @($profile.residualProcesses | ForEach-Object { ([string]$_.name).ToLowerInvariant() + '|' + ([string]$_.executablePath).ToLowerInvariant() })
    if (-not (Test-LeanLaunchArraysHaveSameElements -Left $expectedResidual -Right $actualResidual)) { return $null }

    return $profile
}

function Test-LeanLaunchApplicationProfileBindingValid {
    <# Thin boolean wrapper for callers (policy activation gating) that only need a yes/no answer;
    see Get-LeanLaunchValidatedManagedProfile for the full binding contract and rationale. Callers
    that go on to actually EXECUTE the profile must call Get-LeanLaunchValidatedManagedProfile
    directly and use its returned object, never this wrapper followed by a second read. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Application, [string]$DataRoot)
    return $null -ne (Get-LeanLaunchValidatedManagedProfile -Application $Application -DataRoot $DataRoot)
}

function Set-LeanLaunchApplicationPolicy {
    <#
    Both directions now use expected-content CAS for the record write, and a persistence failure never
    leaves physical service state and disk disagreeing:
      - Managed activation: the read that seeds -ExpectedCurrentContent happens once, up front, before
        any physical service mutation (parking never itself touches disk - see
        Invoke-LeanLaunchServiceParkingActivation), so it is still exactly correct at save time. If the
        save fails for any reason after services were physically parked, every service this call just
        parked is unparked again (restored, and restarted if it had been running) before the error
        propagates - a disk record that still says Unmanaged (the save never landed) can therefore
        never correspond to a live service left disabled/stopped with no record of why.
      - Unmanaged deactivation: Invoke-LeanLaunchServiceParkingDeactivation already persists (and, on
        its own save failure, physically rolls back) each service immediately as it restores it, using
        its own freshly-reestablished CAS baseline per service - see that function. The final save here
        only needs to persist the policy flip itself, so its own -ExpectedCurrentContent is likewise
        re-read fresh immediately beforehand rather than reused from a value this function's own prior
        physical-restore step may already have superseded.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Policy,
        [string]$DataRoot,
        [hashtable]$Adapter,
        # Test-only seam, passed straight through to Save-LeanLaunchApplication: fires immediately
        # before that call's own commit/CAS check, i.e. after physical service parking/unparking has
        # already happened, so a test can simulate persistence failing at exactly that point and prove
        # the physical rollback below. $null (the default) in every production call site.
        [scriptblock]$TestHookBeforeCommit
    )
    if (-not (Test-LeanLaunchApplicationPolicy $Policy)) { throw "Policy must be 'Managed' or 'Unmanaged'." }
    $loaded = Import-LeanLaunchApplicationForUpdate -Name $Name -DataRoot $DataRoot
    $application = $loaded.Application
    if ($Policy -eq 'Managed') {
        $unreviewed = @($application.currentAudit.classifications | Where-Object { [string]$_.decision -eq 'Unreviewed' })
        if ($unreviewed.Count -gt 0) {
            throw "Application '$Name' cannot be set to Managed: $($unreviewed.Count) discovered resource(s) are still Unreviewed."
        }
        if (-not (Test-LeanLaunchApplicationProfileBindingValid -Application $application -DataRoot $DataRoot)) {
            throw "Application '$Name' cannot be set to Managed: no profile is bound to the current audit, or the bound profile no longer matches it exactly (replaced, hand-edited, or stale). Regenerate the profile from the current audit."
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Name, "Set LeanLaunch management policy to $Policy")) { return $null }
    if ($Policy -eq 'Managed') {
        Invoke-LeanLaunchServiceParkingActivation -Application $application -Adapter $Adapter
        $application.policy = $Policy
        try {
            Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot -ExpectedCurrentContent $loaded.RawContent -TestHookBeforeCommit $TestHookBeforeCommit | Out-Null
        }
        catch {
            $originalError = $_
            $rollbackError = $null
            try { Invoke-LeanLaunchServiceParkingDeactivation -Application $application -Adapter $Adapter } catch { $rollbackError = $_ }
            if ($null -ne $rollbackError) {
                throw "Managed activation failed to persist ($($originalError.Exception.Message)), and the physical rollback to restore parked service state also failed ($($rollbackError.Exception.Message)). A service may still be parked/disabled with no persisted record of it; manual verification required."
            }
            throw
        }
    }
    else {
        $expectedContent = [ref]$loaded.RawContent
        Invoke-LeanLaunchServiceParkingDeactivation -Application $application -Adapter $Adapter -DataRoot $DataRoot -ExpectedCurrentContent $expectedContent
        $application.policy = $Policy
        Save-LeanLaunchApplication -Application $application -DataRoot $DataRoot -ExpectedCurrentContent $expectedContent.Value -TestHookBeforeCommit $TestHookBeforeCommit | Out-Null
    }
    return $application
}
