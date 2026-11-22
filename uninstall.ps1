[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [string]$InstallRoot = $(
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.leanlaunch-install.json') -PathType Leaf) { $PSScriptRoot }
        else { Join-Path $env:LOCALAPPDATA 'Programs\LeanLaunch' }
    ),
    [switch]$RemoveData,
    [switch]$SkipPathUpdate,
    [scriptblock]$PreDeleteHook,
    [scriptblock]$PreDeletionPhaseHook,
    [scriptblock]$PreFinalizationHook,
    [scriptblock]$PrePathRemovalConfirmedHook
)
$ErrorActionPreference = 'Stop'
$testHookRequested = @($PreDeleteHook,$PreDeletionPhaseHook,$PreFinalizationHook,$PrePathRemovalConfirmedHook | Where-Object { $null -ne $_ }).Count -gt 0
if (($testHookRequested -or $env:LEANLAUNCH_TEST_ENVIRONMENT_TARGET -eq 'Process') -and $env:LEANLAUNCH_ENABLE_TEST_HOOKS -ne '1') {
    throw 'Uninstaller test hooks and process-local environment targeting are disabled in production. Set LEANLAUNCH_ENABLE_TEST_HOOKS=1 only inside an isolated test harness.'
}
$environmentVariableTarget = if ($env:LEANLAUNCH_TEST_ENVIRONMENT_TARGET -eq 'Process') { 'Process' } else { 'User' }

function Resolve-SafeInstallRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains(';')) {
        throw 'InstallRoot must be a non-empty path and cannot contain a semicolon.'
    }
    $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) {
        throw 'InstallRoot cannot be a drive root.'
    }
    return $full
}

function Get-NormalizedPathEntry([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    try { return [IO.Path]::GetFullPath($value).TrimEnd('\') } catch { return $value.TrimEnd('\') }
}

function Test-LeanLaunchReparsePoint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-LeanLaunchNoReparseInPath {
    <#
    Re-checks reparse-point safety immediately before THIS specific mutation/removal - mirrors
    install.ps1's helper of the same name. Walks every EXISTING path component from TargetPath up to
    the filesystem root (not merely up to InstallRoot), so a directory swapped for a junction/symlink
    anywhere in the chain between an earlier check and this exact removal's turn is still caught here.
    #>
    param([Parameter(Mandatory = $true)][string]$TargetPath)
    $walk = $TargetPath
    while (-not [string]::IsNullOrWhiteSpace($walk)) {
        if (Test-LeanLaunchReparsePoint $walk) {
            throw "Refusing to act through a reparse point (symlink/junction): $walk"
        }
        $parent = Split-Path -Parent $walk
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $walk) { break }
        $walk = $parent
    }
}

function Get-LeanLaunchFileFingerprint([string]$Path) {
    <#
    Mirrors install.ps1's helper of the same name/contract: a SHA256 content fingerprint used to prove
    "this path still holds exactly what was validated" before a transactional step relies on that.
    Returns $null for a path that does not currently exist, so "gone" and "changed" are both
    distinguishable from "unchanged" by comparison.
    #>
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-LeanLaunchTreeFingerprint([string]$Root) {
    <# Produces one SHA-256 identity for a reparse-free directory tree from every relative path,
    entry type, and file-content hash. Enumeration is manual and never follows reparses. #>
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    if (Test-LeanLaunchReparsePoint $Root) { throw "Cannot fingerprint reparse-point tree: $Root" }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pending = New-Object System.Collections.Generic.Queue[string]
    $entries = New-Object System.Collections.Generic.List[string]
    $pending.Enqueue($rootFull)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (Test-LeanLaunchReparsePoint $child.FullName) { throw "Cannot fingerprint tree containing reparse point: $($child.FullName)" }
            $relative = $child.FullName.Substring($rootFull.Length).TrimStart('\')
            if ($child.PSIsContainer) {
                [void]$entries.Add('D|' + $relative)
                $pending.Enqueue($child.FullName)
            }
            else {
                [void]$entries.Add('F|' + $relative + '|' + (Get-LeanLaunchFileFingerprint $child.FullName))
            }
        }
    }
    $payload = (@($entries) | Sort-Object) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)) | ForEach-Object { $_.ToString('X2') }) }
    finally { $sha.Dispose() }
}

function Find-LeanLaunchNestedReparsePoint {
    <#
    Manually walks $Root's descendants ONE DIRECTORY LEVEL AT A TIME - deliberately never
    Get-ChildItem -Recurse, which in Windows PowerShell follows a directory symlink/junction during
    recursive enumeration - so a nested reparse point is detected from its PARENT's own listing and its
    target is never itself listed or traversed into. Returns the first nested reparse point's full path
    the moment one is found (stopping immediately without listing anything beneath it), or $null once the
    entire real (non-reparse) tree beneath $Root has been walked clean. $Root itself is intentionally not
    checked here - callers already check the root separately before deciding whether to descend at all.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $pending = New-Object System.Collections.Generic.Queue[string]
    $pending.Enqueue($Root)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if (Test-LeanLaunchReparsePoint $child.FullName) { return $child.FullName }
            if ($child.PSIsContainer) { $pending.Enqueue($child.FullName) }
        }
    }
    return $null
}

function Get-LeanLaunchUnusedSiblingPath([string]$AnchorPath, [string]$Prefix) {
    <#
    Computes (but does not create) a fresh, GUID-named, currently-unused path as a SIBLING of
    $AnchorPath (never a descendant of it), so it is always same-volume as $AnchorPath - required for
    [IO.File]::Move/[IO.Directory]::Move to commit as true same-volume atomic renames rather than a
    silent, non-atomic copy+delete. Left uncreated deliberately: [IO.Directory]::Move requires its
    destination to NOT already exist, and GUID uniqueness makes a collision here practically impossible.
    #>
    $parent = Split-Path -Parent $AnchorPath
    Assert-LeanLaunchNoReparseInPath $parent
    return (Join-Path $parent ($Prefix + [Guid]::NewGuid().ToString('N')))
}

function New-LeanLaunchSiblingScratchRoot([string]$AnchorPath, [string]$Prefix) {
    <# Same placement contract as Get-LeanLaunchUnusedSiblingPath, but creates the directory - for the
    per-file quarantine case, where individual files are moved INTO this root one at a time below. #>
    $scratchRoot = Get-LeanLaunchUnusedSiblingPath $AnchorPath $Prefix
    New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
    return $scratchRoot
}

function Remove-LeanLaunchDataRootTransactionally {
    <#
    Recursively validates that NO reparse point exists anywhere beneath $DataRoot (the root itself is
    the caller's responsibility, checked before this is ever called) - refusing and touching nothing at
    all if one is found, rather than partially traversing then stopping partway. Once proven clean,
    $DataRoot is quarantined - not deleted - via a single same-volume atomic directory rename into a
    fresh sibling scratch path, so a failure completing the overall removal can still restore it intact;
    the caller alone decides when it is safe to irreversibly delete the returned quarantine path.
    #>
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $nestedReparse = Find-LeanLaunchNestedReparsePoint -Root $DataRoot
    if ($null -ne $nestedReparse) {
        throw "Refusing to remove data root: a nested reparse point (symlink/junction) was found at $nestedReparse. Remove it manually before retrying."
    }
    $quarantineRoot = Get-LeanLaunchUnusedSiblingPath $DataRoot '.leanlaunch-uninstall-quarantine-'
    Assert-LeanLaunchNoReparseInPath $DataRoot
    [IO.Directory]::Move($DataRoot, $quarantineRoot)
    return $quarantineRoot
}

function Remove-LeanLaunchQuarantineRootSafely {
    <#
    The one place a quarantine root is ever irreversibly deleted. Immediately before deleting,
    rescans the ENTIRE tree beneath $QuarantineRoot for a nested reparse point one directory level at
    a time (Find-LeanLaunchNestedReparsePoint - never Get-ChildItem -Recurse, which follows a
    directory symlink/junction during enumeration in Windows PowerShell) - never relying on whatever
    scan happened when its contents were originally quarantined, since a reparse point can be inserted
    directly into an on-disk scratch directory at any time up until this exact moment. Refuses (throws,
    deletes nothing) if the root itself is a reparse point or a nested one is found anywhere inside.

    The physical delete itself ([Remove-Item] against a tree just proven reparse-free) is a best-effort
    OS-level recursive delete, not a single atomic kernel transaction - Windows offers no primitive
    that deletes an arbitrary directory tree as one all-or-nothing operation, so a failure partway
    through IS possible (permission denied on one nested file, a locked handle, ...) and can leave the
    root partially emptied. Callers must treat any exception from this function, or $QuarantineRoot
    still existing afterward, as "finalization did not complete" - the quarantine root (whatever of it
    remains) stays exactly where it is rather than being force-deleted or silently treated as gone.
    #>
    param([Parameter(Mandatory = $true)][string]$QuarantineRoot)
    if (-not (Test-Path -LiteralPath $QuarantineRoot)) { return }
    if (Test-LeanLaunchReparsePoint $QuarantineRoot) {
        throw "Refusing to finalize quarantine root '$QuarantineRoot': it is itself a reparse point (symlink/junction)."
    }
    $nestedReparse = Find-LeanLaunchNestedReparsePoint -Root $QuarantineRoot
    if ($null -ne $nestedReparse) {
        throw "Refusing to finalize quarantine root '$QuarantineRoot': a nested reparse point (symlink/junction) was found at '$nestedReparse' immediately before finalization."
    }
    Remove-Item -LiteralPath $QuarantineRoot -Recurse -Force
    if (Test-Path -LiteralPath $QuarantineRoot) {
        throw "Quarantine root '$QuarantineRoot' still exists after an attempted recursive delete; finalization did not fully complete."
    }
}

$InstallRoot = Resolve-SafeInstallRoot $InstallRoot
$dataRoot = Join-Path $env:LOCALAPPDATA 'LeanLaunch'
$dataRecordPath = Join-Path $dataRoot 'install-record.json'
$markerPath = Join-Path $InstallRoot '.leanlaunch-install.json'

# Only these exact numeric schema versions are ever accepted. A JSON string such as "2" is not the
# same as the integer 2 (ConvertFrom-Json preserves that distinction), and an unrecognized
# future/forged version number (999, say) is rejected rather than silently treated as "new enough" -
# both would otherwise let a forged or corrupted marker/record be accepted as genuine.
$supportedMarkerSchemaVersions = @(1, 2)

function Test-LeanLaunchMarkerShapeValid {
    <#
    Strict, non-coercible shape validation for a parsed marker/install-record object - the same
    contract install.ps1 enforces when reading an existing marker before an upgrade. schemaVersion
    must be an actual JSON number matching a supported version (never a string that merely looks
    numeric); product/installRoot must be non-empty strings matching exactly (installRoot is compared
    against $ExpectedInstallRoot only when that parameter is supplied - the data-root fallback record
    validates shape without requiring the installRoot to match THIS uninstall, since a shared data
    root legitimately holding a record for a different install is not itself corruption). schemaVersion
    1 predates the manifest/PATH-ownership fields and is accepted without them; schemaVersion 2+ must
    additionally carry files/directories as real arrays (never a bare scalar), and pathEntryValue must
    be present as a property AT ALL (even when pathEntryAdded is false - its absence, not merely a
    null/empty value, indicates a malformed record), with pathEntryAdded itself an actual JSON boolean
    (never the string "true"/"false") and pathEntryValue a non-empty string whenever pathEntryAdded is
    true.
    #>
    param($Marker, [string]$ExpectedInstallRoot, [int[]]$SupportedSchemaVersions)
    if ($null -eq $Marker) { return $false }
    if ($Marker.product -isnot [string] -or $Marker.product -ne 'LeanLaunch') { return $false }
    if ($Marker.schemaVersion -isnot [int] -or ($SupportedSchemaVersions -notcontains [int]$Marker.schemaVersion)) { return $false }
    if ($Marker.installRoot -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Marker.installRoot)) { return $false }
    if (-not [string]::IsNullOrEmpty($ExpectedInstallRoot) -and
        -not ([string]$Marker.installRoot).Equals($ExpectedInstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if ([int]$Marker.schemaVersion -ge 2) {
        if ($Marker.files -isnot [array]) { return $false }
        if ($Marker.directories -isnot [array]) { return $false }
        if (-not ($Marker.PSObject.Properties.Name -contains 'pathEntryValue')) { return $false }
        if ($Marker.pathEntryAdded -isnot [bool]) { return $false }
        if ($Marker.pathEntryAdded) {
            if ($Marker.pathEntryValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Marker.pathEntryValue)) { return $false }
        }
        elseif ($null -ne $Marker.pathEntryValue -and $Marker.pathEntryValue -isnot [string]) {
            return $false
        }
    }
    return $true
}

# The data-root install-record.json's content is captured now, before any validation or mutation, so
# its final removal near the end of this script can re-verify nothing changed in between (see the
# matching check right before that removal) rather than blindly deleting whatever a concurrent
# process may have since written there.
$dataRecordContentAtStart = $null
if (Test-Path -LiteralPath $dataRecordPath -PathType Leaf) {
    try { $dataRecordContentAtStart = Get-Content -LiteralPath $dataRecordPath -Raw } catch { $dataRecordContentAtStart = $null }
}

# The install-root marker is authoritative proof that this specific directory was written by
# LeanLaunch (a lexical path match alone is forgeable/stale, so both the marker AND its recorded
# installRoot must agree with the resolved path). Fall back to the data-root copy only when the
# install root's own marker is gone, so PATH ownership can still be cleaned up. Its exact raw content
# is captured too, for the same concurrent-change re-verification before any mutation begins, below.
$record = $null
$markerContentAtValidation = $null
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    try { $markerContentAtValidation = Get-Content -LiteralPath $markerPath -Raw } catch { throw 'The LeanLaunch installation marker is invalid.' }
    try { $record = $markerContentAtValidation | ConvertFrom-Json } catch { throw 'The LeanLaunch installation marker is invalid.' }
    if (-not (Test-LeanLaunchMarkerShapeValid -Marker $record -ExpectedInstallRoot $InstallRoot -SupportedSchemaVersions $supportedMarkerSchemaVersions)) {
        throw 'The LeanLaunch installation marker does not match this directory; nothing was removed.'
    }
}
elseif (Test-Path -LiteralPath $InstallRoot) {
    throw "Refusing to remove unmarked directory: $InstallRoot"
}
elseif ($null -ne $dataRecordContentAtStart) {
    # Fail closed on a genuinely INVALID data-root record (malformed JSON or the wrong shape/types) -
    # that is corruption or tampering and must not be silently treated as "no installation exists
    # here". A record that parses and validates fine but simply names a DIFFERENT install root is not
    # itself an error (the data root is shared across however many installs have existed over time);
    # that case is simply not used as this uninstall's record, without raising anything.
    try { $dataRecord = $dataRecordContentAtStart | ConvertFrom-Json } catch {
        throw 'The LeanLaunch data-root install record is invalid; refusing to proceed without confirming whether an installation exists.'
    }
    if (-not (Test-LeanLaunchMarkerShapeValid -Marker $dataRecord -SupportedSchemaVersions $supportedMarkerSchemaVersions)) {
        throw 'The LeanLaunch data-root install record is malformed; refusing to proceed without confirming whether an installation exists.'
    }
    if (([string]$dataRecord.installRoot).Equals($InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $record = $dataRecord
    }
}

if ($null -eq $record) {
    Write-Output "LeanLaunch installation is already absent from $InstallRoot"
    if ($RemoveData -and (Test-Path -LiteralPath $dataRoot)) {
        if (Test-LeanLaunchReparsePoint $dataRoot) {
            throw "Refusing to remove a reparse point (symlink/junction) data root: $dataRoot"
        }
        if ($PSCmdlet.ShouldProcess($dataRoot, 'Remove LeanLaunch user profiles and snapshots')) {
            # Quarantine (same-volume atomic rename), not a direct recursive delete. Bind the complete
            # tree before the rename and re-verify it before either finalization or rollback; ordinary
            # same-path payload substitution is never deleted or restored as trusted user data.
            $earlyDataQuarantine = $null
            $earlyDataFingerprint = Get-LeanLaunchTreeFingerprint $dataRoot
            try {
                $earlyDataQuarantine = Remove-LeanLaunchDataRootTransactionally -DataRoot $dataRoot
                if ($null -ne $PreFinalizationHook) { & $PreFinalizationHook }
                if ((Get-LeanLaunchTreeFingerprint $earlyDataQuarantine) -ne $earlyDataFingerprint) {
                    throw 'The quarantined data root was substituted before finalization.'
                }
                Remove-LeanLaunchQuarantineRootSafely -QuarantineRoot $earlyDataQuarantine
            }
            catch {
                $earlyOriginalError = $_
                if ($null -ne $earlyDataQuarantine -and (Test-Path -LiteralPath $earlyDataQuarantine -PathType Container) -and -not (Test-Path -LiteralPath $dataRoot)) {
                    try {
                        if ((Get-LeanLaunchTreeFingerprint $earlyDataQuarantine) -ne $earlyDataFingerprint) {
                            throw 'Quarantined data content no longer matches the validated original tree.'
                        }
                        Assert-LeanLaunchNoReparseInPath $dataRoot
                        [IO.Directory]::Move($earlyDataQuarantine, $dataRoot)
                    }
                    catch {
                        throw "Uninstall data removal failed and rollback could not restore '$dataRoot' from quarantine at '$earlyDataQuarantine' (original error: $($earlyOriginalError.Exception.Message))."
                    }
                }
                throw
            }
        }
    }
    return
}

$hasManifest = [int]$record.schemaVersion -ge 2

# All safety validation - reparse-point checks and manifest path containment - happens up front,
# before ANY mutation (PATH removal included), so a substituted install root or forged manifest is
# refused before anything is touched rather than discovered partway through.
$manifestFiles = @()
$manifestDirectories = @()
if (Test-Path -LiteralPath $InstallRoot) {
    if (Test-LeanLaunchReparsePoint $InstallRoot) {
        throw "Refusing to act on a reparse point (symlink/junction) install root: $InstallRoot. Remove it manually."
    }
    if (-not $hasManifest) {
        throw "The installation marker predates manifest-based uninstall; refusing to guess what to delete under $InstallRoot. Remove it manually or reinstall to upgrade the marker."
    }

    $rawManifestFiles = @($record.files)
    $validatedManifestFiles = New-Object System.Collections.Generic.List[string]
    $installPrefix = $InstallRoot.TrimEnd('\') + '\'
    foreach ($relativeValue in $rawManifestFiles) {
        if ($relativeValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$relativeValue)) {
            throw 'The installation manifest contains an invalid file path.'
        }
        $relative = [string]$relativeValue
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) {
            throw "The installation manifest contains an unsafe rooted or device path: $relative"
        }
        $segments = @($relative -split '[\\/]' | Where-Object { $_ -ne '' })
        if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
            throw "The installation manifest contains a path traversal segment: $relative"
        }
        $resolved = [IO.Path]::GetFullPath((Join-Path $InstallRoot $relative))
        if (-not $resolved.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The installation manifest path escapes the install root: $relative"
        }
        [void]$validatedManifestFiles.Add($relative)
    }
    $manifestFiles = @($validatedManifestFiles)
    $manifestDirectories = @($manifestFiles | ForEach-Object { Split-Path -Parent (Join-Path $InstallRoot $_) } | Where-Object { $_ } | Sort-Object -Unique)

    # Baseline fingerprints for the immediately-before-mutation drift check performed on each file below,
    # right before it is quarantined - captured now, at validation time (before any mutation begins), so
    # a concurrent content change is detected and that file preserved rather than silently
    # quarantined/deleted, no matter how long the eventual quarantine loop takes to reach it.
    $validatedFileFingerprints = @{}
    foreach ($relative in $manifestFiles) {
        $validatedFileFingerprints[$relative] = Get-LeanLaunchFileFingerprint (Join-Path $InstallRoot $relative)
    }
}

if ($record.pathEntryAdded -eq $true) {
    if (-not ($record.PSObject.Properties.Name -contains 'pathEntryValue') -or [string]::IsNullOrWhiteSpace([string]$record.pathEntryValue)) {
        throw 'The installation record claims PATH ownership but has no valid pathEntryValue.'
    }
    $expectedOwnedPath = Get-NormalizedPathEntry (Join-Path $InstallRoot 'bin')
    $claimedOwnedPath = Get-NormalizedPathEntry ([string]$record.pathEntryValue)
    if ($null -eq $claimedOwnedPath -or -not $claimedOwnedPath.Equals($expectedOwnedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation record claims an unrelated PATH entry; nothing was removed.'
    }
}

# Re-verify the marker still holds EXACTLY the content validated at the top of this script,
# immediately before this run's FIRST mutation - PATH removal included, not merely file deletion. A
# concurrent process may have legitimately written a newer marker (a fresh install/upgrade racing this
# uninstall) in the time since; no mutation of any kind should proceed against that stale validated
# state. -PreDeletionPhaseHook fires immediately before this check specifically so a test can inject a
# concurrent change at the earliest possible point and prove even the PATH removal below never runs.
if ($null -ne $PreDeletionPhaseHook) { & $PreDeletionPhaseHook }
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    $currentMarkerContentBeforeAnyMutation = $null
    try { $currentMarkerContentBeforeAnyMutation = Get-Content -LiteralPath $markerPath -Raw } catch { }
    if ($currentMarkerContentBeforeAnyMutation -ne $markerContentAtValidation) {
        throw 'The LeanLaunch installation marker changed after it was validated; refusing to remove or modify anything. Re-run uninstall to pick up the current state.'
    }
}
elseif ($null -ne $markerContentAtValidation) {
    throw 'The LeanLaunch installation marker was removed after it was validated; refusing to guess what to modify. Re-run uninstall to pick up the current state.'
}

$pathRemoved = $false
$pathValueBeforeRemoval = $null
$pathValueAfterRemoval = $null
$filesRemoved = $false
$filesPreserved = $false
$installQuarantineRoot = $null
$dataQuarantineRoot = $null
$quarantinedRelatives = New-Object System.Collections.Generic.List[string]
$markerQuarantined = $false
$markerQuarantinePath = $null
$dataRecordQuarantined = $false
$dataRecordQuarantinePath = $null
$dataRootQuarantined = $false
$dataRootQuarantinePath = $null
$dataRootFingerprint = $null

function Undo-LeanLaunchPartialUninstall {
    <#
    Rolls back exactly what THIS invocation mutated so far - and only that. PATH is restored only if
    its CURRENT value still exactly equals what this run itself set it to (a concurrent PATH editor
    since then is left completely alone: the same narrowed-but-not-eliminated residual race already
    accepted throughout this codebase for PATH). Each quarantined item (a file, the marker, the data
    record, or the whole data root) is moved back to its exact original path only when that path is
    currently absent (a concurrent process having since recreated something there is preserved, never
    overwritten) and its full parent chain is still reparse-free. Anything that cannot be safely
    restored is left sitting untouched in its quarantine root - never deleted, never forced back - and
    its original path is collected so the caller can fail loudly with an actionable manual-recovery
    pointer instead of silently claiming a clean rollback. Quarantine scratch roots are removed here
    only once EVERY item they held has been confirmed successfully restored.
    #>
    $unrestored = New-Object System.Collections.Generic.List[string]

    if ($pathRemoved) {
        try {
            $currentPathValue = [Environment]::GetEnvironmentVariable('Path', $environmentVariableTarget)
            if ($currentPathValue -eq $pathValueAfterRemoval) {
                [Environment]::SetEnvironmentVariable('Path', $pathValueBeforeRemoval, $environmentVariableTarget)
            }
            # else: a concurrent PATH editor changed it after our removal; leave it exactly as found.
        }
        catch { [void]$unrestored.Add('User PATH') }
    }

    foreach ($relative in $quarantinedRelatives) {
        $originalPath = Join-Path $InstallRoot $relative
        $quarantinedPath = Join-Path $installQuarantineRoot $relative
        try {
            if (-not (Test-Path -LiteralPath $quarantinedPath -PathType Leaf)) {
                [void]$unrestored.Add($originalPath)
                continue
            }
            if ((Get-LeanLaunchFileFingerprint $quarantinedPath) -ne $validatedFileFingerprints[$relative]) {
                [void]$unrestored.Add($originalPath)
                continue
            }
            Assert-LeanLaunchNoReparseInPath $originalPath
            if (Test-Path -LiteralPath $originalPath) { [void]$unrestored.Add($originalPath); continue }
            $originalParent = Split-Path -Parent $originalPath
            if (-not (Test-Path -LiteralPath $originalParent -PathType Container)) {
                Assert-LeanLaunchNoReparseInPath $originalParent
                New-Item -ItemType Directory -Path $originalParent -Force | Out-Null
            }
            [IO.File]::Move($quarantinedPath, $originalPath)
        }
        catch { [void]$unrestored.Add($originalPath) }
    }

    if ($markerQuarantined) {
        try {
            if (-not (Test-Path -LiteralPath $markerQuarantinePath -PathType Leaf)) {
                [void]$unrestored.Add($markerPath)
            }
            elseif ((Get-Content -LiteralPath $markerQuarantinePath -Raw) -ne $markerContentAtValidation) {
                [void]$unrestored.Add($markerPath)
            }
            else {
                Assert-LeanLaunchNoReparseInPath $markerPath
                if (Test-Path -LiteralPath $markerPath) { [void]$unrestored.Add($markerPath) }
                else { [IO.File]::Move($markerQuarantinePath, $markerPath) }
            }
        }
        catch { [void]$unrestored.Add($markerPath) }
    }

    if ($dataRecordQuarantined) {
        try {
            if (-not (Test-Path -LiteralPath $dataRecordQuarantinePath -PathType Leaf)) {
                [void]$unrestored.Add($dataRecordPath)
            }
            elseif ((Get-Content -LiteralPath $dataRecordQuarantinePath -Raw) -ne $dataRecordContentAtStart) {
                [void]$unrestored.Add($dataRecordPath)
            }
            else {
                Assert-LeanLaunchNoReparseInPath $dataRecordPath
                if (Test-Path -LiteralPath $dataRecordPath) { [void]$unrestored.Add($dataRecordPath) }
                else { [IO.File]::Move($dataRecordQuarantinePath, $dataRecordPath) }
            }
        }
        catch { [void]$unrestored.Add($dataRecordPath) }
    }

    if ($dataRootQuarantined) {
        try {
            if (-not (Test-Path -LiteralPath $dataRootQuarantinePath -PathType Container)) {
                [void]$unrestored.Add($dataRoot)
            }
            elseif ((Get-LeanLaunchTreeFingerprint $dataRootQuarantinePath) -ne $dataRootFingerprint) {
                [void]$unrestored.Add($dataRoot)
            }
            else {
                Assert-LeanLaunchNoReparseInPath $dataRoot
                if (Test-Path -LiteralPath $dataRoot) { [void]$unrestored.Add($dataRoot) }
                else { [IO.Directory]::Move($dataRootQuarantinePath, $dataRoot) }
            }
        }
        catch { [void]$unrestored.Add($dataRoot) }
    }

    if ($unrestored.Count -eq 0) {
        foreach ($scratchRoot in @($installQuarantineRoot, $dataQuarantineRoot)) {
            if ([string]::IsNullOrWhiteSpace($scratchRoot)) { continue }
            try {
                if (Test-Path -LiteralPath $scratchRoot) {
                    Remove-LeanLaunchQuarantineRootSafely -QuarantineRoot $scratchRoot
                }
            }
            catch {
                # A substituted/nested reparse point or partial filesystem failure makes scratch-root
                # cleanup unsafe. Leave the root for manual inspection; all owned payload items above
                # have already been restored, so never recurse through uncertain content here.
            }
        }
    }

    return $unrestored
}

try {
    if (-not $SkipPathUpdate -and $record.pathEntryAdded -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$record.pathEntryValue)) {
        $recordedNormalized = Get-NormalizedPathEntry ([string]$record.pathEntryValue)
        $probePathValue = [Environment]::GetEnvironmentVariable('Path',$environmentVariableTarget)
        $probeRemovedOne = @($probePathValue -split ';' | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            ($normalized = Get-NormalizedPathEntry $_) -and
            $normalized.Equals($recordedNormalized, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        # This read is only ever used to decide whether a confirmation prompt is warranted at all - it
        # is deliberately never the value actually written below. ConfirmImpact 'High' means a real
        # interactive run can pause here for however long the user takes to answer; PATH is re-read
        # fresh immediately below, after confirmation, so a concurrent edit landing during that pause
        # is preserved rather than clobbered by this now-stale snapshot.
        if ($probeRemovedOne -and $PSCmdlet.ShouldProcess('User PATH', "Remove $($record.pathEntryValue)")) {
            if ($null -ne $PrePathRemovalConfirmedHook) { & $PrePathRemovalConfirmedHook }
            $currentPathValue = [Environment]::GetEnvironmentVariable('Path',$environmentVariableTarget)
            $parts = @($currentPathValue -split ';')
            $removedOne = $false
            $newParts = New-Object System.Collections.Generic.List[string]
            foreach ($part in $parts) {
                if (-not $removedOne -and -not [string]::IsNullOrWhiteSpace($part)) {
                    $normalized = Get-NormalizedPathEntry $part
                    if ($null -ne $normalized -and $normalized.Equals($recordedNormalized, [StringComparison]::OrdinalIgnoreCase)) {
                        $removedOne = $true
                        continue
                    }
                }
                [void]$newParts.Add($part)
            }
            # Only the single literal entry this install recorded adding is ever removed; unrelated or
            # user-added equivalent PATH entries (including one added after confirmation but before
            # this fresh read) are left exactly as they were.
            if ($removedOne) {
                $pathValueBeforeRemoval = $currentPathValue
                $pathValueAfterRemoval = ($newParts -join ';')
                [Environment]::SetEnvironmentVariable('Path', $pathValueAfterRemoval, $environmentVariableTarget)
                $pathRemoved = $true
            }
        }
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        if ($PSCmdlet.ShouldProcess($InstallRoot, "Remove $($manifestFiles.Count) LeanLaunch-installed files")) {
            # Quarantine via same-volume atomic per-file rename, never a direct delete: nothing here is
            # irreversible until the single finalization step at the very end of this transaction.
            $installQuarantineRoot = New-LeanLaunchSiblingScratchRoot $InstallRoot '.leanlaunch-uninstall-quarantine-'

            foreach ($relative in $manifestFiles) {
                if ($null -ne $PreDeleteHook) { & $PreDeleteHook $relative }
                $filePath = Join-Path $InstallRoot $relative

                # Re-validate the COMPLETE reparse chain (source and destination are the same path for a
                # removal) immediately before acting on THIS file, rather than relying on a one-time
                # pre-pass done before the loop started - a directory swapped for a junction/symlink
                # between two files is still caught here, not missed.
                Assert-LeanLaunchNoReparseInPath $filePath

                if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                    # Drift is a transaction-wide conflict, not permission to commit a partial
                    # uninstall. Preserve the newer bytes at this path, throw, and let the outer catch
                    # restore every file already quarantined by this invocation.
                    $currentFingerprint = Get-LeanLaunchFileFingerprint $filePath
                    if ($currentFingerprint -ne $validatedFileFingerprints[$relative]) {
                        throw "Installed file '$relative' changed after uninstall validation; aborting and rolling back rather than committing a partial removal."
                    }
                    $quarantineTarget = Join-Path $installQuarantineRoot $relative
                    $quarantineParent = Split-Path -Parent $quarantineTarget
                    if (-not (Test-Path -LiteralPath $quarantineParent -PathType Container)) {
                        Assert-LeanLaunchNoReparseInPath $quarantineParent
                        New-Item -ItemType Directory -Path $quarantineParent -Force | Out-Null
                    }
                    [IO.File]::Move($filePath, $quarantineTarget)
                    [void]$quarantinedRelatives.Add($relative)
                }
            }

            # Final immediate re-compare before quarantining the marker itself. Any marker drift aborts
            # the whole transaction and restores files already moved; the newer marker is never touched.
            if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                $finalMarkerContentBeforeMarkerMove = $null
                try { $finalMarkerContentBeforeMarkerMove = Get-Content -LiteralPath $markerPath -Raw } catch { }
                if ($finalMarkerContentBeforeMarkerMove -ne $markerContentAtValidation) {
                    throw 'The LeanLaunch installation marker changed during uninstall; aborting and rolling back rather than committing a partial removal.'
                }
                Assert-LeanLaunchNoReparseInPath $markerPath
                $markerQuarantinePath = Join-Path $installQuarantineRoot '.leanlaunch-install.json'
                [IO.File]::Move($markerPath, $markerQuarantinePath)
                $markerQuarantined = $true
            }
            elseif ($null -ne $markerContentAtValidation) {
                throw 'The LeanLaunch installation marker disappeared during uninstall; aborting and rolling back rather than committing a partial removal.'
            }

            $filesRemoved = $true
        }
    }
    else {
        Write-Output "LeanLaunch installation files are already absent from $InstallRoot"
    }

    if ($RemoveData) {
        if (Test-Path -LiteralPath $dataRoot) {
            if (Test-LeanLaunchReparsePoint $dataRoot) {
                throw "Refusing to remove a reparse point (symlink/junction) data root: $dataRoot"
            }
            if ($PSCmdlet.ShouldProcess($dataRoot, 'Remove LeanLaunch user profiles and snapshots')) {
                # Rejects - and touches nothing at all - if any reparse point is found anywhere beneath
                # the data root, then quarantines the validated-clean tree via one atomic same-volume
                # rename. Never a direct recursive delete.
                $dataRootFingerprint = Get-LeanLaunchTreeFingerprint $dataRoot
                $dataRootQuarantinePath = Remove-LeanLaunchDataRootTransactionally -DataRoot $dataRoot
                $dataRootQuarantined = $true
                $dataQuarantineRoot = $dataRootQuarantinePath
            }
        }
    }
    elseif (($filesRemoved -or $pathRemoved) -and (Test-Path -LiteralPath $dataRecordPath)) {
        # Drop the now-stale install pointer even when user data is kept, so a future install starts
        # clean - but only if its content still matches exactly what was captured at the very start of
        # this run. A concurrent process may have replaced it with a newer, unrelated record in the
        # meantime (for example a fresh install racing this uninstall); touching that newer record here
        # would destroy state this uninstall never validated and has no business touching. Best-effort
        # by design, matching the original behavior for this specific low-stakes pointer file: a
        # failure here is swallowed rather than aborting/rolling back the whole uninstall.
        $currentDataRecordContentBeforeMove = $null
        try { $currentDataRecordContentBeforeMove = Get-Content -LiteralPath $dataRecordPath -Raw } catch { }
        if ($currentDataRecordContentBeforeMove -eq $dataRecordContentAtStart) {
            try {
                Assert-LeanLaunchNoReparseInPath $dataRecordPath
                $dataQuarantineRoot = New-LeanLaunchSiblingScratchRoot $dataRoot '.leanlaunch-uninstall-quarantine-'
                $dataRecordQuarantinePath = Join-Path $dataQuarantineRoot 'install-record.json'
                [IO.File]::Move($dataRecordPath, $dataRecordQuarantinePath)
                $dataRecordQuarantined = $true
            }
            catch { }
        }
    }

    if ($null -ne $PreFinalizationHook) { & $PreFinalizationHook }

    # The quarantine itself is untrusted mutable state. Before crossing the irreversible boundary,
    # prove every item this invocation moved is still present at the exact quarantine path. Missing or
    # substituted content is a failed transaction, never a successful uninstall.
    foreach ($relative in $quarantinedRelatives) {
        $expectedQuarantinedPath = Join-Path $installQuarantineRoot $relative
        Assert-LeanLaunchNoReparseInPath $expectedQuarantinedPath
        if (-not (Test-Path -LiteralPath $expectedQuarantinedPath -PathType Leaf)) {
            throw "Quarantined installed file '$relative' disappeared before finalization."
        }
        if ((Get-LeanLaunchFileFingerprint $expectedQuarantinedPath) -ne $validatedFileFingerprints[$relative]) {
            throw "Quarantined installed file '$relative' was substituted before finalization."
        }
    }
    if ($markerQuarantined -and -not (Test-Path -LiteralPath $markerQuarantinePath -PathType Leaf)) {
        throw 'The quarantined installation marker disappeared before finalization.'
    }
    if ($markerQuarantined -and (Get-Content -LiteralPath $markerQuarantinePath -Raw) -ne $markerContentAtValidation) {
        throw 'The quarantined installation marker was substituted before finalization.'
    }
    if ($dataRecordQuarantined -and -not (Test-Path -LiteralPath $dataRecordQuarantinePath -PathType Leaf)) {
        throw 'The quarantined install record disappeared before finalization.'
    }
    if ($dataRecordQuarantined -and (Get-Content -LiteralPath $dataRecordQuarantinePath -Raw) -ne $dataRecordContentAtStart) {
        throw 'The quarantined install record was substituted before finalization.'
    }
    if ($dataRootQuarantined -and -not (Test-Path -LiteralPath $dataRootQuarantinePath -PathType Container)) {
        throw 'The quarantined data root disappeared before finalization.'
    }
    if ($dataRootQuarantined -and (Get-LeanLaunchTreeFingerprint $dataRootQuarantinePath) -ne $dataRootFingerprint) {
        throw 'The quarantined data root was substituted before finalization.'
    }

    # POINT OF NO RETURN. Every reversible step above succeeded. Windows has no atomic primitive for
    # deleting one arbitrary directory tree (let alone quarantine roots on potentially different
    # volumes), so a recursive finalization failure can be partial. The catch below attempts rollback
    # of every item still present and, critically, reports every missing/unrestorable original path;
    # it never claims a full rollback after irreversible bytes have already been deleted.
    if ($null -ne $installQuarantineRoot -and (Test-Path -LiteralPath $installQuarantineRoot)) {
        Remove-LeanLaunchQuarantineRootSafely -QuarantineRoot $installQuarantineRoot
    }
    if ($null -ne $dataQuarantineRoot -and (Test-Path -LiteralPath $dataQuarantineRoot)) {
        Remove-LeanLaunchQuarantineRootSafely -QuarantineRoot $dataQuarantineRoot
    }
}
catch {
    $originalUninstallError = $_
    $unrestoredItems = Undo-LeanLaunchPartialUninstall
    if ($unrestoredItems.Count -gt 0) {
        $quarantineNote = (@($installQuarantineRoot, $dataQuarantineRoot) | Where-Object { $_ }) -join ', '
        throw "Uninstall failed and rollback could not fully restore prior state (original error: $($originalUninstallError.Exception.Message)). The following items remain safely quarantined for manual recovery from: $quarantineNote - unrestored original paths: $($unrestoredItems -join ', ')"
    }
    throw
}

if ($filesRemoved -and (Test-Path -LiteralPath $InstallRoot)) {
    # Remove directories bottom-up, but only ones that are now empty and not themselves a reparse
    # point. Anything left over (a preserved newer marker, a preserved drifted file, or a foreign file)
    # was not this run's to delete and is preserved rather than force-deleted. Pure cleanup of now-empty
    # directories at this point - every file that was going to move already has, one way or another (
    # quarantined-then-finalized, or preserved above) - so there is nothing left here for a failure to
    # roll back.
    $orderedDirectories = @($manifestDirectories + $InstallRoot) | Sort-Object -Unique | Sort-Object { $_.Length } -Descending
    foreach ($directory in $orderedDirectories) {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            if (Test-LeanLaunchReparsePoint $directory) {
                $filesPreserved = $true
                continue
            }
            $remaining = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                try { Remove-Item -LiteralPath $directory -Force } catch { }
            }
            else {
                $filesPreserved = $true
            }
        }
    }
    if ($filesPreserved -or (Test-Path -LiteralPath $InstallRoot)) {
        Write-Warning "Some files under $InstallRoot were not removed (not installed by LeanLaunch, or their content changed since this uninstall began) and were preserved. Remove them manually if unwanted."
    }
}

if ($filesRemoved) {
    Write-Output 'LeanLaunch removed. User profiles and snapshots were preserved unless -RemoveData was supplied.'
}
elseif ($pathRemoved) {
    Write-Output 'LeanLaunch PATH entry removed. No installed files were present to remove.'
}
else {
    Write-Output 'No confirmed changes were made.'
}
