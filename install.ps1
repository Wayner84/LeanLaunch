[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\LeanLaunch'),
    [switch]$SkipPathUpdate,
    [scriptblock]$PreWriteHook,
    [scriptblock]$PreFileCommitHook,
    [scriptblock]$PreFileCommitWriteHook,
    [scriptblock]$PostFileCommitHook,
    [scriptblock]$PostCommitHook,
    [scriptblock]$PreMarkerWriteHook,
    [scriptblock]$MarkerAtomicWriteTestHook,
    [scriptblock]$DataRecordAtomicWriteTestHook
)
$ErrorActionPreference = 'Stop'
$testHookRequested = @($PreWriteHook,$PreFileCommitHook,$PreFileCommitWriteHook,$PostFileCommitHook,$PostCommitHook,$PreMarkerWriteHook,$MarkerAtomicWriteTestHook,$DataRecordAtomicWriteTestHook | Where-Object { $null -ne $_ }).Count -gt 0
if (($testHookRequested -or $env:LEANLAUNCH_TEST_ENVIRONMENT_TARGET -eq 'Process') -and $env:LEANLAUNCH_ENABLE_TEST_HOOKS -ne '1') {
    throw 'Installer test hooks and process-local environment targeting are disabled in production. Set LEANLAUNCH_ENABLE_TEST_HOOKS=1 only inside an isolated test harness.'
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
    Re-checks reparse-point safety immediately before THIS specific mutation, rather than relying on
    a one-time precheck done before the whole install/rollback began or on a boundary assumed safe.
    Walks every EXISTING path component from TargetPath up to the filesystem root - not merely up to
    some already-validated ancestor - so a directory swapped for a junction/symlink anywhere in the
    chain (the staging tree, the backup tree, the data root, or the install root itself) between an
    earlier check and this exact mutation's turn is still caught here. A component that does not exist
    yet cannot itself be a swapped reparse point, so the walk simply continues past it to whatever
    parent does exist.
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
    A strong content fingerprint (SHA256) used to prove "this path still holds exactly what this run
    installed" before rollback ever restores or removes it. Returns $null for a path that does not
    currently exist, so "gone" and "changed" are both distinguishable from "unchanged" by comparison.
    #>
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Wait-LeanLaunchExclusiveLock {
    <#
    Opens a same-directory "<file>.lock" sidecar with FileShare.None (bounded retry) and returns the
    held FileStream, serializing every COOPERATING caller of this script's own atomic-write helpers
    for the same destination against each other (this invocation of install.ps1 and any other
    concurrently running one). This is NOT a claim of protection against a non-cooperating writer that
    modifies the destination directly - Windows exposes no conditional-replace primitive
    (ReplaceFile/MoveFileEx included) that enforces a true compare-and-swap against such a writer
    without its cooperation. See the extended discussion on Copy-LeanLaunchFileSafelyAtomic and
    Set-LeanLaunchFileContentAtomic below, the two callers of this helper. Fails closed (throws)
    rather than blocking forever if the lock cannot be acquired within the bound.
    #>
    param([Parameter(Mandatory = $true)][string]$LockPath, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            return New-Object -TypeName IO.FileStream -ArgumentList @($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for the write lock on $LockPath." }
            Start-Sleep -Milliseconds 25
        }
    } while ($true)
}

function Copy-LeanLaunchFileSafely {
    <#
    Used only for copies into a scratch area this script exclusively owns and nothing else ever reads
    (the staging tree, or a per-file backup capture) - never for a write to a live, externally
    observable path. Still revalidates BOTH the source and destination path chains for reparse points
    immediately before the copy, and again immediately after creating any missing destination parent.
    #>
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    Assert-LeanLaunchNoReparseInPath $Source
    Assert-LeanLaunchNoReparseInPath $Destination
    $destinationParent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationParent) -and -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        Assert-LeanLaunchNoReparseInPath $destinationParent
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Assert-LeanLaunchNoReparseInPath $destinationParent
    }
    Assert-LeanLaunchNoReparseInPath $Source
    Assert-LeanLaunchNoReparseInPath $Destination
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Copy-LeanLaunchFileSafelyAtomic {
    <#
    Same-volume atomic commit for a write to a LIVE, potentially externally observed path (an
    install-root file, the marker, or the data-root install record): the source's bytes land in a
    same-directory, unique temp file first, then are atomically swapped into place via
    [IO.File]::Replace/Move. A failure anywhere up to that final swap - including one injected via
    -TestHookBeforeCommit, a test-only seam - leaves the destination, if any, completely untouched:
    never partially overwritten or truncated the way an in-place Copy-Item could leave it. Both source
    and destination are revalidated for reparse points immediately before the copy begins, again
    immediately after creating any missing destination parent, and again immediately before the swap.

    When -VerifyExpectedFingerprint is set, the destination's CURRENT fingerprint is re-checked
    against -ExpectedDestinationFingerprint while holding an exclusive same-directory lock (see
    Wait-LeanLaunchExclusiveLock) that is held through the swap itself, and the reparse chain is
    re-checked a second time immediately adjacent to the swap - the tightest sequence this script can
    practically achieve, and a genuine compare-and-swap against every OTHER COOPERATING caller of this
    same helper (another concurrently running install.ps1). It is deliberately not presented as more
    than that: a non-cooperating writer that replaces the destination directly, without going through
    this function, is not blocked by the lock - see Wait-LeanLaunchExclusiveLock's own comment for why
    Windows offers no primitive that could close that last gap unilaterally. Returns the fingerprint of
    what was actually written (computed from the temp file - i.e. from the source bytes - immediately
    after they land there and before anything else can touch them), so callers can record
    installed-file identity from bytes they controlled the whole time, never by re-reading the live
    destination after publication.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [scriptblock]$TestHookBeforeCommit,
        [switch]$VerifyExpectedFingerprint,
        $ExpectedDestinationFingerprint
    )
    Assert-LeanLaunchNoReparseInPath $Source
    Assert-LeanLaunchNoReparseInPath $Destination
    $destinationParent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationParent) -and -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        Assert-LeanLaunchNoReparseInPath $destinationParent
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Assert-LeanLaunchNoReparseInPath $destinationParent
    }
    $tempPath = Join-Path $destinationParent ([IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $destinationParent ([IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.bak')
    $lockPath = $Destination + '.lock'
    $lockStream = $null
    try {
        Assert-LeanLaunchNoReparseInPath $Source
        Copy-Item -LiteralPath $Source -Destination $tempPath -Force
        $stagedFingerprint = Get-LeanLaunchFileFingerprint $tempPath
        if ($null -ne $TestHookBeforeCommit) { & $TestHookBeforeCommit }
        $lockStream = Wait-LeanLaunchExclusiveLock -LockPath $lockPath
        Assert-LeanLaunchNoReparseInPath $Destination
        if ($VerifyExpectedFingerprint) {
            $actualFingerprint = Get-LeanLaunchFileFingerprint $Destination
            if ($actualFingerprint -ne $ExpectedDestinationFingerprint) {
                throw "Refusing to overwrite '$Destination': its content changed concurrently immediately before the atomic swap."
            }
        }
        # Re-checked a second time, immediately adjacent to the swap itself.
        Assert-LeanLaunchNoReparseInPath $Destination
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Destination, $backupPath)
        }
        else {
            [IO.File]::Move($tempPath, $Destination)
        }
        return $stagedFingerprint
    }
    finally {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        # The sidecar is synchronization state, not installed content. Remove it only after releasing
        # our handle. If another cooperating writer acquired it meanwhile, FileShare.None causes this
        # best-effort removal to fail harmlessly rather than deleting that writer's live lock.
        if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    }
}

function Set-LeanLaunchFileContentAtomic {
    <#
    Same-directory unique temp file + atomic Replace/Move commit for writing text content to a live
    path (mirrors Copy-LeanLaunchFileSafelyAtomic, but for in-memory content rather than an existing
    source file - install.ps1 cannot depend on the module's Write-LeanLaunchJsonAtomic here, since
    installing the module is exactly what may still be in progress). A failure at any point up to the
    final Replace/Move leaves the destination, if any, completely untouched, and the temp file is
    always cleaned up.

    -ExpectedCurrentContent (mandatory, may be $null to mean "expected absent") is re-verified against
    the destination's ACTUAL current content, while holding an exclusive same-directory lock (see
    Wait-LeanLaunchExclusiveLock) that is held through the swap itself, and the reparse chain is
    re-checked a second time immediately adjacent to the swap - the tightest sequence this script can
    practically achieve, and a genuine compare-and-swap against every OTHER COOPERATING caller (another
    concurrently running install.ps1). As with Copy-LeanLaunchFileSafelyAtomic above, this is not a
    claim of protection against a non-cooperating writer that replaces the destination directly without
    going through this function - see Wait-LeanLaunchExclusiveLock's own comment.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][AllowNull()]$ExpectedCurrentContent,
        [scriptblock]$TestHookBeforeCommit
    )
    Assert-LeanLaunchNoReparseInPath $Path
    $directory = Split-Path -Parent $Path
    $tempPath = Join-Path $directory ([IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $directory ([IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.bak')
    $lockPath = $Path + '.lock'
    $lockStream = $null
    try {
        [IO.File]::WriteAllText($tempPath, $Content, (New-Object Text.UTF8Encoding($true)))
        if ($null -ne $TestHookBeforeCommit) { & $TestHookBeforeCommit }
        $lockStream = Wait-LeanLaunchExclusiveLock -LockPath $lockPath
        Assert-LeanLaunchNoReparseInPath $Path
        $actualCurrentContent = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw } else { $null }
        if ($actualCurrentContent -ne $ExpectedCurrentContent) {
            throw "Refusing to overwrite '$Path': its content changed concurrently immediately before the atomic swap."
        }
        # Re-checked a second time, immediately adjacent to the swap itself.
        Assert-LeanLaunchNoReparseInPath $Path
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Path, $backupPath)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    }
}

function Test-LeanLaunchMarkerShapeValid {
    <#
    Strict, non-coercible shape validation for a parsed marker/install-record object. schemaVersion
    must be an actual JSON number matching a supported version (never a string that merely looks
    numeric); product/installRoot must be non-empty strings matching exactly. schemaVersion 1
    predates the manifest/PATH-ownership fields and is accepted without them, preserving it as a
    deliberately still-supported, lighter-weight shape; schemaVersion 2+ must additionally carry
    files/directories as real arrays (never a bare scalar), pathEntryValue present as a PROPERTY at
    all (even when pathEntryAdded is false - its absence, not merely a null/empty value, indicates a
    malformed record), pathEntryAdded as an actual JSON boolean (never the string "true"/"false"), and
    a non-empty string pathEntryValue whenever pathEntryAdded is true.
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

$sourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
$InstallRoot = Resolve-SafeInstallRoot $InstallRoot
if ($sourceRoot.Equals($InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run install.ps1 from the source checkout, not from the destination.'
}
if (Test-LeanLaunchReparsePoint $InstallRoot) {
    throw "Refusing to install into a reparse point (symlink/junction): $InstallRoot"
}

# Only these exact numeric schema versions are ever accepted as a valid prior installation. A JSON
# string such as "2" is not the same as the integer 2 (ConvertFrom-Json preserves that distinction),
# and an unrecognized future/forged version number is rejected rather than silently treated as "new
# enough" - both would otherwise let a forged or corrupted marker be accepted as genuine.
$supportedMarkerSchemaVersions = @(1, 2)

$markerPath = Join-Path $InstallRoot '.leanlaunch-install.json'
if (Test-Path -LiteralPath $InstallRoot) {
    $items = @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction Stop)
    if ($items.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "Refusing to install into non-empty, unmarked directory: $InstallRoot"
        }
        try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch { throw 'The existing LeanLaunch installation marker is invalid.' }
        if (-not (Test-LeanLaunchMarkerShapeValid -Marker $marker -ExpectedInstallRoot $InstallRoot -SupportedSchemaVersions $supportedMarkerSchemaVersions)) {
            throw 'The existing LeanLaunch installation marker does not match this directory.'
        }
    }
}

$copyDirectories = @('bin','src','profiles')
$copyFiles = @('leanlaunch.ps1','LeanLaunch.psd1','LICENSE','README.md','uninstall.ps1')

# Preliminary manifest built straight from source, used only to size the ShouldProcess confirmation
# message; the manifest actually recorded is rebuilt from the staged copy below.
$previewManifestFiles = New-Object System.Collections.Generic.List[string]
foreach ($directory in $copyDirectories) {
    $dirSource = Join-Path $sourceRoot $directory
    foreach ($file in @(Get-ChildItem -LiteralPath $dirSource -File -Recurse -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $previewManifestFiles.Add($relative)
    }
}
foreach ($file in $copyFiles) { $previewManifestFiles.Add($file) }

$binPath = Join-Path $InstallRoot 'bin'
$normalizedBin = Get-NormalizedPathEntry $binPath
$previewPathValue = [Environment]::GetEnvironmentVariable('Path',$environmentVariableTarget)
$previewParts = @($previewPathValue -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$previewPathAlreadyPresent = @($previewParts | Where-Object {
    $normalized = Get-NormalizedPathEntry $_
    $null -ne $normalized -and $normalized.Equals($normalizedBin, [StringComparison]::OrdinalIgnoreCase)
}).Count -gt 0
$previewWillAddPath = (-not $SkipPathUpdate) -and (-not $previewPathAlreadyPresent)

# One ShouldProcess call gates files, data directories, and the PATH entry together so a declined or
# WhatIf install can never add a PATH entry for a nonexistent installation (no PATH-only partial install).
$actionDescription = "Install $($previewManifestFiles.Count) files to $InstallRoot"
if ($previewWillAddPath) { $actionDescription += " and add $binPath to the user PATH" }
if (-not $PSCmdlet.ShouldProcess($InstallRoot, $actionDescription)) {
    Write-Output 'Install cancelled; no changes were made.'
    return
}

# Stage the entire install into a sibling temp directory first. Nothing under $InstallRoot, the user
# PATH, or the install marker is touched until the staged copy is fully built and validated, so any
# failure up to that point (including one injected via -PreWriteHook, a test-only seam) leaves zero
# orphaned PATH entries or markers behind - only the staging directory itself needs cleanup.
$stagingParent = Split-Path -Parent $InstallRoot
Assert-LeanLaunchNoReparseInPath $stagingParent
New-Item -ItemType Directory -Path $stagingParent -Force | Out-Null
$stagingRoot = Join-Path $stagingParent ('.leanlaunch-staging-' + [Guid]::NewGuid().ToString('N'))

try {
    Assert-LeanLaunchNoReparseInPath $stagingRoot
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    # Per-file, individually validated copies instead of a broad recursive Copy-Item: a single
    # Copy-Item -Recurse would follow every nested reparse point inside the source tree without any
    # per-item check. Copy-LeanLaunchFileSafely revalidates both source and destination for every
    # single file. (This is a scratch-area copy - stagingRoot is never externally observed - so it
    # does not need the atomic swap primitive used for live-path writes below.)
    foreach ($directory in $copyDirectories) {
        $dirSource = Join-Path $sourceRoot $directory
        Assert-LeanLaunchNoReparseInPath $dirSource
        foreach ($file in @(Get-ChildItem -LiteralPath $dirSource -File -Recurse -ErrorAction Stop)) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
            Copy-LeanLaunchFileSafely -Source $file.FullName -Destination (Join-Path $stagingRoot $relative)
        }
    }
    foreach ($file in $copyFiles) {
        Copy-LeanLaunchFileSafely -Source (Join-Path $sourceRoot $file) -Destination (Join-Path $stagingRoot $file)
    }

    # Build (and validate) the manifest against what was actually staged, not merely what was intended.
    $manifestFiles = New-Object System.Collections.Generic.List[string]
    foreach ($directory in $copyDirectories) {
        $dirStaged = Join-Path $stagingRoot $directory
        foreach ($file in @(Get-ChildItem -LiteralPath $dirStaged -File -Recurse -ErrorAction Stop)) {
            $relative = $file.FullName.Substring($stagingRoot.Length).TrimStart('\')
            $manifestFiles.Add($relative)
        }
    }
    foreach ($file in $copyFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot $file) -PathType Leaf)) {
            throw "Staged copy is missing expected file: $file"
        }
        $manifestFiles.Add($file)
    }

    if ($null -ne $PreWriteHook) { & $PreWriteHook }
}
catch {
    if (Test-Path -LiteralPath $stagingRoot) {
        try {
            Assert-LeanLaunchNoReparseInPath $stagingRoot
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
    throw
}

# From here on, $InstallRoot (and, for PATH/data directories/marker/install record, state outside it)
# may be mutated. Everything below is one rollback-capable region: ANY failure - during the commit
# copy itself, PATH update, data-directory creation, or the marker/install-record write - undoes
# exactly what THIS invocation did and restores exactly what existed before, rather than leaving a
# partially upgraded install or an orphaned PATH entry behind. Two properties hold throughout: (1)
# rollback never recursively deletes $InstallRoot wholesale - for a fresh install it is only ever
# removed file-by-owned-file and then, last, as an empty directory, so any file that appears in it
# from outside this invocation survives untouched; and (2) rollback only ever undoes a path (file,
# marker, or install record) whose CURRENT content still matches exactly what THIS run itself wrote
# there - a path a concurrent process has since replaced, or deleted, is left completely alone rather
# than clobbered or resurrected.
$isNewInstall = -not (Test-Path -LiteralPath $InstallRoot)
$backupRoot = Join-Path $stagingParent ('.leanlaunch-backup-' + [Guid]::NewGuid().ToString('N'))
$backedUpMarker = $false
$markerWrittenByThisRun = $false
$markerContentWritten = $null
$backedUpDataRecord = $false
$dataRecordWrittenByThisRun = $false
$dataRecordContentWritten = $null
$createdInstallDirectories = New-Object System.Collections.Generic.List[string]
$createdDataDirectories = New-Object System.Collections.Generic.List[string]
$committedRelatives = New-Object System.Collections.Generic.List[string]
$installedFingerprints = @{}
$pathEntryAdded = $false
$dataRoot = Join-Path $env:LOCALAPPDATA 'LeanLaunch'
$dataRecordPath = Join-Path $dataRoot 'install-record.json'

function Undo-LeanLaunchPartialInstall {
    <#
    Returns the list of human-readable descriptions of anything this rollback attempt could not
    actually restore (an exception was thrown while restoring it) - never merely swallowing that
    failure the way each individual restore step's own try/catch necessarily still does internally
    (a failure restoring one item must not prevent every OTHER item from still being attempted). An
    empty list means every tracked item this run had touched was successfully restored (or was
    correctly left alone because a concurrent process had already changed it - see the per-step
    comments below). The caller must treat a non-empty list as "rollback did not fully undo this
    attempt" and surface it loudly rather than silently re-throwing only the original failure, which
    would otherwise look identical to a fully successful rollback.
    #>
    param($NormalizedBin)
    $unrestored = New-Object System.Collections.Generic.List[string]
    if ($pathEntryAdded) {
        # PATH is a single environment-variable value: there is no OS-level transaction spanning the
        # read-modify-write, so this remains a read-modify-write like the forward path, not a true
        # atomic rollback - a concurrent PATH editor in this exact window is an accepted, unavoidable
        # residual race, identical in kind to the one already accepted for the forward PATH update.
        try {
            $current = [Environment]::GetEnvironmentVariable('Path',$environmentVariableTarget)
            $parts = @($current -split ';')
            $removedOne = $false
            $newParts = New-Object System.Collections.Generic.List[string]
            foreach ($part in $parts) {
                if (-not $removedOne -and -not [string]::IsNullOrWhiteSpace($part)) {
                    $normalized = Get-NormalizedPathEntry $part
                    if ($null -ne $normalized -and $normalized.Equals($NormalizedBin, [StringComparison]::OrdinalIgnoreCase)) {
                        $removedOne = $true
                        continue
                    }
                }
                [void]$newParts.Add($part)
            }
            if ($removedOne) { [Environment]::SetEnvironmentVariable('Path', ($newParts -join ';'), $environmentVariableTarget) }
        }
        catch { [void]$unrestored.Add("user PATH entry '$NormalizedBin'") }
    }

    foreach ($dir in ($createdDataDirectories | Sort-Object { $_.Length } -Descending)) {
        try {
            Assert-LeanLaunchNoReparseInPath $dir
            if (Test-Path -LiteralPath $dir -PathType Container) {
                $remaining = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
                if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $dir -Force -ErrorAction Stop }
            }
        }
        catch { [void]$unrestored.Add("data directory '$dir'") }
    }

    # install-record.json lives in the shared data root, not under $InstallRoot, so unlike the
    # install-root files below it is never assumed to be exclusively this invocation's to delete.
    # Rollback only ever acts on it when the CURRENT content still matches either what this run itself
    # wrote (proven by $dataRecordWrittenByThisRun plus an exact content match) or the untouched
    # original this run backed up (proven by an exact match against the backup). Any other current
    # content means a concurrent process created or changed it after this run touched it, and it is
    # left completely alone rather than clobbered or deleted.
    if (Test-Path -LiteralPath $dataRecordPath -PathType Leaf) {
        try {
            Assert-LeanLaunchNoReparseInPath $dataRecordPath
            $currentContent = Get-Content -LiteralPath $dataRecordPath -Raw -ErrorAction Stop
            if ($backedUpDataRecord) {
                $backupRecordPath = Join-Path $backupRoot 'install-record.json.bak'
                $backupContent = Get-Content -LiteralPath $backupRecordPath -Raw -ErrorAction Stop
                $matchesOurWrite = $dataRecordWrittenByThisRun -and ($currentContent -eq $dataRecordContentWritten)
                $matchesOriginal = ($currentContent -eq $backupContent)
                if ($matchesOurWrite -or $matchesOriginal) {
                    # The fingerprint of what is currently there (already proven above to match either
                    # our own write or the untouched original) is passed through so the atomic swap
                    # re-verifies, immediately before committing, that nothing changed again in the
                    # narrow window since - closing the gap rather than trusting this earlier check alone.
                    $expectedFingerprint = Get-LeanLaunchFileFingerprint $dataRecordPath
                    Copy-LeanLaunchFileSafelyAtomic -Source $backupRecordPath -Destination $dataRecordPath -VerifyExpectedFingerprint -ExpectedDestinationFingerprint $expectedFingerprint | Out-Null
                }
            }
            elseif ($dataRecordWrittenByThisRun -and ($currentContent -eq $dataRecordContentWritten)) {
                # Re-read immediately before the delete itself (Remove-Item has no atomic
                # pre-condition check of its own) to shrink the window since $currentContent was read
                # above as tightly as this script practically can.
                Assert-LeanLaunchNoReparseInPath $dataRecordPath
                $contentImmediatelyBeforeDelete = if (Test-Path -LiteralPath $dataRecordPath -PathType Leaf) { Get-Content -LiteralPath $dataRecordPath -Raw } else { $null }
                if ($contentImmediatelyBeforeDelete -eq $dataRecordContentWritten) {
                    Remove-Item -LiteralPath $dataRecordPath -Force
                }
            }
        }
        catch { [void]$unrestored.Add("data-root install record '$dataRecordPath'") }
    }
    # If the path is currently ABSENT despite having been backed up, that can only mean a concurrent
    # process deleted the original in the window since the backup was captured (this script itself
    # never deletes it before writing) - resurrecting it here would clobber that concurrent deletion,
    # so nothing is done and the absence is left exactly as found.

    # Only a relative path this attempt actually committed (tracked in $committedRelatives, only after
    # its atomic commit genuinely succeeded - see the commit loop below) is ever considered here, and
    # even then only if its current content fingerprint still exactly matches what this run installed;
    # a file never reached by the commit loop, already gone, or since replaced by a concurrent process
    # is left completely alone.
    foreach ($relative in $committedRelatives) {
        try {
            $destination = Join-Path $InstallRoot $relative
            Assert-LeanLaunchNoReparseInPath $destination
            $currentFingerprint = Get-LeanLaunchFileFingerprint $destination
            $writtenFingerprint = $installedFingerprints[$relative]
            if ($null -eq $currentFingerprint -or $currentFingerprint -ne $writtenFingerprint) { continue }
            $backupFile = Join-Path $backupRoot $relative
            Assert-LeanLaunchNoReparseInPath $backupFile
            if (Test-Path -LiteralPath $backupFile -PathType Leaf) {
                # $writtenFingerprint (already proven above to match the current destination) is passed
                # through so the atomic swap re-verifies it again immediately before committing,
                # closing the gap between this check and the actual restore.
                Copy-LeanLaunchFileSafelyAtomic -Source $backupFile -Destination $destination -VerifyExpectedFingerprint -ExpectedDestinationFingerprint $writtenFingerprint | Out-Null
            }
            else {
                Assert-LeanLaunchNoReparseInPath $destination
                $fingerprintImmediatelyBeforeDelete = Get-LeanLaunchFileFingerprint $destination
                if ($fingerprintImmediatelyBeforeDelete -eq $writtenFingerprint) {
                    Remove-Item -LiteralPath $destination -Force
                }
            }
        }
        catch { [void]$unrestored.Add("installed file '$relative'") }
    }

    # The marker gets the identical concurrent-ownership treatment as install-record.json above.
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        try {
            Assert-LeanLaunchNoReparseInPath $markerPath
            $currentMarkerContent = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop
            if ($backedUpMarker) {
                $backupMarkerPath = Join-Path $backupRoot '.leanlaunch-install.marker.bak'
                $backupMarkerContent = Get-Content -LiteralPath $backupMarkerPath -Raw -ErrorAction Stop
                $matchesOurWrite = $markerWrittenByThisRun -and ($currentMarkerContent -eq $markerContentWritten)
                $matchesOriginal = ($currentMarkerContent -eq $backupMarkerContent)
                if ($matchesOurWrite -or $matchesOriginal) {
                    $expectedFingerprint = Get-LeanLaunchFileFingerprint $markerPath
                    Copy-LeanLaunchFileSafelyAtomic -Source $backupMarkerPath -Destination $markerPath -VerifyExpectedFingerprint -ExpectedDestinationFingerprint $expectedFingerprint | Out-Null
                }
            }
            elseif ($markerWrittenByThisRun -and ($currentMarkerContent -eq $markerContentWritten)) {
                Assert-LeanLaunchNoReparseInPath $markerPath
                $contentImmediatelyBeforeDelete = if (Test-Path -LiteralPath $markerPath -PathType Leaf) { Get-Content -LiteralPath $markerPath -Raw } else { $null }
                if ($contentImmediatelyBeforeDelete -eq $markerContentWritten) {
                    Remove-Item -LiteralPath $markerPath -Force
                }
            }
        }
        catch { [void]$unrestored.Add("installation marker '$markerPath'") }
    }
    # Same reasoning as install-record.json above: an absent marker despite having been backed up can
    # only mean a concurrent deletion, which is left exactly as found rather than resurrected.

    foreach ($dir in ($createdInstallDirectories | Sort-Object { $_.Length } -Descending)) {
        try {
            Assert-LeanLaunchNoReparseInPath $dir
            if (Test-Path -LiteralPath $dir -PathType Container) {
                $remaining = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
                if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $dir -Force }
            }
        }
        catch { [void]$unrestored.Add("install directory '$dir'") }
    }

    try {
        Assert-LeanLaunchNoReparseInPath $backupRoot
        if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
    }
    catch { [void]$unrestored.Add("rollback backup scratch area '$backupRoot' (may still contain a backup copy of prior state)") }
    try {
        Assert-LeanLaunchNoReparseInPath $stagingRoot
        if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
    }
    catch { [void]$unrestored.Add("staging scratch area '$stagingRoot'") }
    return $unrestored
}

try {
    Assert-LeanLaunchNoReparseInPath $backupRoot
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

    if (-not $isNewInstall) {
        Assert-LeanLaunchNoReparseInPath $InstallRoot
        foreach ($directory in $copyDirectories) {
            $destDir = Join-Path $InstallRoot $directory
            if (-not (Test-Path -LiteralPath $destDir -PathType Container)) { [void]$createdInstallDirectories.Add($destDir) }
        }
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            Copy-LeanLaunchFileSafely -Source $markerPath -Destination (Join-Path $backupRoot '.leanlaunch-install.marker.bak')
            $backedUpMarker = $true
        }

        # Backup capture (a plain copy into our own scratch backup area) happens first; only once
        # that state capture is complete does the atomic commit run. $relative is added to
        # $committedRelatives, and its installed fingerprint recorded, ONLY after the atomic commit
        # genuinely succeeds - with an atomic same-volume temp+swap commit, a failed write can never
        # leave the destination partially overwritten, so there is no "corrupted but untracked" state
        # to guard against the way a non-atomic Copy-Item would have required.
        foreach ($relative in $manifestFiles) {
            if ($null -ne $PreFileCommitHook) { & $PreFileCommitHook $relative }
            $destination = Join-Path $InstallRoot $relative
            $stagedSource = Join-Path $stagingRoot $relative
            Assert-LeanLaunchNoReparseInPath $destination
            # Captured immediately before backup - this is the ownership baseline for the forward
            # write below, exactly mirroring how rollback already protects its own restores. $null
            # here correctly means "expected absent" for a file this install root does not yet have.
            $destinationFingerprintBeforeBackup = Get-LeanLaunchFileFingerprint $destination
            if ($null -ne $destinationFingerprintBeforeBackup) {
                $backupTarget = Join-Path $backupRoot $relative
                Copy-LeanLaunchFileSafely -Source $destination -Destination $backupTarget
            }
            $currentRelative = $relative
            $atomicHook = $null
            if ($null -ne $PreFileCommitWriteHook) { $atomicHook = { & $PreFileCommitWriteHook $currentRelative }.GetNewClosure() }
            # The fingerprint recorded as "what this run installed" comes back from the atomic copy
            # itself, computed from the staged source bytes at the moment they landed in the temp file
            # - never by re-reading the live destination afterward, which could already reflect a
            # concurrent replacement by the time this line ran. -VerifyExpectedFingerprint closes the
            # matching ownership gap on this FORWARD write: the destination fingerprint captured
            # immediately above (before backup) is re-checked immediately before the atomic swap, so a
            # concurrent replacement landing in the backup/staging window aborts this file's swap (and,
            # via the outer catch, rolls back everything this upgrade already committed) instead of
            # silently overwriting whatever a concurrent process just wrote there.
            $stagedFingerprint = Copy-LeanLaunchFileSafelyAtomic -Source $stagedSource -Destination $destination -TestHookBeforeCommit $atomicHook -VerifyExpectedFingerprint -ExpectedDestinationFingerprint $destinationFingerprintBeforeBackup
            [void]$committedRelatives.Add($relative)
            $installedFingerprints[$relative] = $stagedFingerprint
            if ($null -ne $PostFileCommitHook) { & $PostFileCommitHook $relative }
        }
        Assert-LeanLaunchNoReparseInPath $stagingRoot
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    else {
        # Fingerprints are computed from the STAGED (pre-publication) copies, before Move-Item ever
        # runs - stagingRoot is exclusively this run's own scratch area up to this exact point, so
        # these bytes cannot yet have been touched by anything else. Hashing the live destination
        # AFTER the move (as before) would risk recording a concurrent replacement's content as if it
        # were this run's own install, if that replacement landed in the instant after publication.
        foreach ($relative in $manifestFiles) {
            $installedFingerprints[$relative] = Get-LeanLaunchFileFingerprint (Join-Path $stagingRoot $relative)
        }

        # A fresh install root is moved into place as a single atomic rename (stagingRoot and
        # InstallRoot always share the same parent, hence the same volume - Move-Item here is a true
        # single MoveFileEx rename, not a copy+delete, so there is no partial-file corruption mode to
        # guard against). Both the source and destination are revalidated immediately before the move.
        Assert-LeanLaunchNoReparseInPath $stagingRoot
        Assert-LeanLaunchNoReparseInPath $InstallRoot
        Move-Item -LiteralPath $stagingRoot -Destination $InstallRoot
        $committedRelatives.AddRange($manifestFiles)
        [void]$createdInstallDirectories.Add($InstallRoot)
        foreach ($directory in $copyDirectories) { [void]$createdInstallDirectories.Add((Join-Path $InstallRoot $directory)) }
    }

    if ($null -ne $PostCommitHook) { & $PostCommitHook }

    # PATH is re-read fresh here - never the snapshot taken before staging/copying began - so a
    # concurrent edit to the user PATH during install is preserved rather than clobbered. The .NET
    # Environment PATH API offers no read-modify-write transaction of its own, so this remains a
    # narrowed, not eliminated, race: the window between this read and the SetEnvironmentVariable call
    # immediately below is the smallest it can practically be made, and a concurrent PATH edit landing
    # inside that exact window is an accepted residual risk, not something claimed to be atomic.
    $currentPathValue = [Environment]::GetEnvironmentVariable('Path',$environmentVariableTarget)
    $existingParts = @($currentPathValue -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $pathAlreadyPresent = @($existingParts | Where-Object {
        $normalized = Get-NormalizedPathEntry $_
        $null -ne $normalized -and $normalized.Equals($normalizedBin, [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    $willAddPath = (-not $SkipPathUpdate) -and (-not $pathAlreadyPresent)
    if ($willAddPath) {
        [Environment]::SetEnvironmentVariable('Path', ((@($existingParts) + $binPath) -join ';'), $environmentVariableTarget)
        $pathEntryAdded = $true
    }

    # Every mutation from here on reaches outside $InstallRoot into $dataRoot (normally
    # %LOCALAPPDATA%\LeanLaunch) - a location this script does not own the same way it owns the
    # install root, so each write is revalidated immediately, exactly like the install-root files
    # above, rather than trusting the single Test-Path/New-Item -Force calls to be safe by construction.
    Assert-LeanLaunchNoReparseInPath $dataRecordPath
    if (Test-Path -LiteralPath $dataRecordPath -PathType Leaf) {
        Copy-LeanLaunchFileSafely -Source $dataRecordPath -Destination (Join-Path $backupRoot 'install-record.json.bak')
        $backedUpDataRecord = $true
    }
    Assert-LeanLaunchNoReparseInPath $dataRoot
    $dataRootExisted = Test-Path -LiteralPath $dataRoot -PathType Container
    foreach ($sub in @('profiles','snapshots','apps','audits')) {
        $dir = Join-Path $dataRoot $sub
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void]$createdDataDirectories.Add($dir) }
    }
    if (-not $dataRootExisted) { [void]$createdDataDirectories.Add($dataRoot) }
    foreach ($sub in @('profiles','snapshots','apps','audits')) {
        $dir = Join-Path $dataRoot $sub
        Assert-LeanLaunchNoReparseInPath $dir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($null -ne $PreMarkerWriteHook) { & $PreMarkerWriteHook }

    # schemaVersion 2: records the exact installed-file manifest and whether/what literal PATH entry
    # this install added, so uninstall can remove exactly and only what this install did (nothing
    # forged/guessed).
    $record = [ordered]@{
        schemaVersion = 2
        product = 'LeanLaunch'
        installRoot = $InstallRoot
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        files = @($manifestFiles)
        directories = @($copyDirectories)
        pathEntryAdded = $pathEntryAdded
        pathEntryValue = if ($pathEntryAdded) { $binPath } else { $null }
    }
    $recordJson = $record | ConvertTo-Json -Depth 6

    # Immediately before overwriting the marker, re-verify it is still exactly what was backed up (or,
    # if none existed, that it still does not exist) - a concurrent writer that changed or removed it
    # in the window since the backup was taken must abort this install rather than silently clobbering
    # or losing that concurrent state. This narrows, without fully eliminating, the same class of
    # read-modify-write race already accepted for the PATH update above.
    $currentMarkerContentBeforeWrite = if (Test-Path -LiteralPath $markerPath -PathType Leaf) { Get-Content -LiteralPath $markerPath -Raw } else { $null }
    $expectedMarkerContentBeforeWrite = if ($backedUpMarker) { Get-Content -LiteralPath (Join-Path $backupRoot '.leanlaunch-install.marker.bak') -Raw } else { $null }
    if ($currentMarkerContentBeforeWrite -ne $expectedMarkerContentBeforeWrite) {
        throw 'The LeanLaunch installation marker changed concurrently; aborting rather than overwriting or losing it.'
    }
    Set-LeanLaunchFileContentAtomic -Path $markerPath -Content $recordJson -ExpectedCurrentContent $expectedMarkerContentBeforeWrite -TestHookBeforeCommit $MarkerAtomicWriteTestHook
    $markerWrittenByThisRun = $true
    $markerContentWritten = $recordJson

    # Duplicated in the user data root (outside InstallRoot) so uninstall can still find and remove
    # the recorded PATH entry even if InstallRoot was already deleted by some other means. The same
    # immediate-before-overwrite concurrency re-check applies here as for the marker above.
    $currentDataRecordContentBeforeWrite = if (Test-Path -LiteralPath $dataRecordPath -PathType Leaf) { Get-Content -LiteralPath $dataRecordPath -Raw } else { $null }
    $expectedDataRecordContentBeforeWrite = if ($backedUpDataRecord) { Get-Content -LiteralPath (Join-Path $backupRoot 'install-record.json.bak') -Raw } else { $null }
    if ($currentDataRecordContentBeforeWrite -ne $expectedDataRecordContentBeforeWrite) {
        throw 'The LeanLaunch install-record.json changed concurrently; aborting rather than overwriting or losing it.'
    }
    Set-LeanLaunchFileContentAtomic -Path $dataRecordPath -Content $recordJson -ExpectedCurrentContent $expectedDataRecordContentBeforeWrite -TestHookBeforeCommit $DataRecordAtomicWriteTestHook
    $dataRecordWrittenByThisRun = $true
    $dataRecordContentWritten = $recordJson
}
catch {
    $originalException = $_
    $unrestored = @(Undo-LeanLaunchPartialInstall -NormalizedBin $normalizedBin)
    if ($unrestored.Count -gt 0) {
        throw "Install failed ($($originalException.Exception.Message)), and rollback could not fully restore prior state for: $($unrestored -join '; '). Manual recovery may be required."
    }
    throw
}

try {
    Assert-LeanLaunchNoReparseInPath $backupRoot
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
catch { }

Write-Output "LeanLaunch installed at $InstallRoot"
Write-Output 'No service, scheduled task, startup entry, tray process, or daemon was installed.'
Write-Output 'Open a new terminal (and restart PowerToys if necessary), then run: leanlaunch doctor'
