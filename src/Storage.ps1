Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-LeanLaunchPaths {
    [CmdletBinding()]
    param([string]$DataRoot)

    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        $DataRoot = Join-Path $env:LOCALAPPDATA 'LeanLaunch'
    }
    [pscustomobject]@{
        DataRoot = $DataRoot
        Profiles = Join-Path $DataRoot 'profiles'
        Snapshots = Join-Path $DataRoot 'snapshots'
        Sessions = Join-Path $DataRoot 'sessions'
        Apps = Join-Path $DataRoot 'apps'
        Audits = Join-Path $DataRoot 'audits'
    }
}

function Test-LeanLaunchProfileName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    return $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

function Test-LeanLaunchHasProperty {
    <#
    Safe replacement for the common "$obj.PSObject.Properties.Name -contains 'X'" idiom. Under
    Set-StrictMode -Version 2.0, that idiom throws PropertyNotFoundStrict when $obj has zero
    properties (for example a JSON "{}") because an empty member collection cannot resolve the
    projected .Name access. Indexing .PSObject.Properties by name does not have that failure mode
    and returns $null cleanly whether the object has no properties at all or simply lacks this one.
    #>
    param($InputObject, [Parameter(Mandatory = $true)][string]$PropertyName)
    if ($null -eq $InputObject) { return $false }
    return $null -ne $InputObject.PSObject.Properties[$PropertyName]
}

function Test-LeanLaunchAcceptedNumericValue {
    <#
    Accepts only genuine numeric runtime types (the ones CIM/WMI and PowerShell's own process/service
    cmdlets actually produce for IDs and sizes) - never a string, even a numeric-looking one like "42".
    A collector that hands back a JSON- or text-sourced numeric-looking STRING for an ID/size is
    exactly the class of quietly-coercible-but-wrong value this guards against: [int]"42" would cast
    without complaint, silently accepting data of the wrong shape as if it were trustworthy evidence.
    #>
    param($Value)
    return ($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [uint32]) -or ($Value -is [uint64]) -or
        ($Value -is [int16]) -or ($Value -is [int64]) -or ($Value -is [byte]) -or ($Value -is [double])
}

function Expand-LeanLaunchValue {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return $null }
    return [Environment]::ExpandEnvironmentVariables($Value)
}

function ConvertTo-LeanLaunchArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Test-LeanLaunchServiceName {
    param([string]$Name)
    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name -match '^[A-Za-z0-9_.-]{1,256}$'
}

function Test-LeanLaunchProcessName {
    param([string]$Name)
    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name -match '^[A-Za-z0-9_.-]{1,128}$'
}

function Test-LeanLaunchReparsePoint {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-LeanLaunchNoReparseInPath {
    <#
    Walks every EXISTING path component from $TargetPath up to the filesystem root, so a directory
    swapped for a junction/symlink anywhere in the chain between an earlier check and this exact
    write is still caught immediately before the write, not merely by a one-time precheck done
    earlier. A component that does not exist yet cannot itself be a swapped reparse point, so the
    walk simply continues past it to whatever parent does exist. Mirrors install.ps1/uninstall.ps1's
    identically-named helper for the module's own JSON persistence.
    #>
    param([Parameter(Mandatory = $true)][string]$TargetPath)
    $walk = $TargetPath
    while (-not [string]::IsNullOrWhiteSpace($walk)) {
        if (Test-LeanLaunchReparsePoint $walk) {
            throw "Refusing to act through a reparse point (symlink\junction): $walk"
        }
        $parent = Split-Path -Parent $walk
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $walk) { break }
        $walk = $parent
    }
}

function Get-LeanLaunchFileHash {
    <#
    A strong SHA-256 content fingerprint used to bind a record to the exact bytes of a specific file
    on disk (for example, an application record's binding to the profile it was generated from).
    Returns $null for a path that does not currently exist.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Wait-LeanLaunchExclusiveLock {
    <#
    Opens $LockPath with FileShare.None (bounded retry) and returns the held FileStream, serializing
    every COOPERATING caller of this helper for the same path against each other - see the extended
    discussion on Write-LeanLaunchJsonAtomic, the only current caller. Fails closed (throws) rather
    than blocking forever if the lock cannot be acquired within the bound.
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

function Get-LeanLaunchBytesHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') })
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-LeanLaunchJsonAtomic {
    <#
    Writes JSON to $Path by fully writing a same-directory temporary file first, then atomically
    replacing (or, for a brand-new destination, moving) it into place. A failure at any point before
    the final replace/move leaves the original destination file, if any, completely untouched, and
    the temporary file is always cleaned up. Re-checks the full path chain for reparse points both
    before staging AND again immediately adjacent to the swap - not merely at some earlier, already-
    stale checkpoint.

    The comparison-to-swap sequence additionally holds an exclusive OS lock on a same-directory
    "<file>.lock" sidecar for its full duration, serializing this call against every OTHER call to
    this function for the same path (any LeanLaunch process or thread - CLI, GUI, or a concurrent
    call in this process). Among such COOPERATING callers, -RequireUnchanged is therefore a genuine
    compare-and-swap: no other write through this function can land between the comparison and the
    swap. This is deliberately NOT presented as protection against a NON-cooperating writer - a
    process that writes $Path directly instead of calling this function is not blocked by the lock.
    Windows exposes no conditional-replace primitive (ReplaceFile/ MoveFileEx included) that enforces
    a true compare-and-swap against such a writer without its cooperation: [IO.File]::Replace/Move
    take a path, not a handle, so honestly the last remaining window is that single OS call itself,
    between this function's final re-verification (still under the lock) and that call's completion.
    That window is sub-millisecond and only reachable by a process already able to write this exact
    per-user file - i.e. already inside the current user's own trust boundary, not a remote or
    cross-user attacker. This residual is intentionally documented here rather than hidden behind a
    broader "atomic"/"CAS" claim than the primitive actually supports.

    -RequireUnchanged (with -ExpectedCurrentContent, which may be $null to mean "expected absent") is
    the compare-and-swap guard described above: the destination's ACTUAL current content is
    re-verified, while still holding the lock, immediately before the swap, so a concurrent writer
    that changed or removed the destination since this caller's own read is detected and aborts the
    write, rather than silently overwriting or resurrecting it. Omitted by default so existing callers
    that do not need CAS semantics are unaffected.

    Returns a [pscustomobject] with Path and ContentHash - the SHA-256 hash of the exact bytes this
    call wrote, computed from the same in-memory buffer that was written to disk, never by re-opening
    $Path afterward (which could already reflect a different, later write by the time such a re-read
    ran). Callers that need to bind a record to exactly what was just written (for example a profile's
    content-hash binding) must use this returned hash, never a separate post-write file read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$Depth = 8,
        [scriptblock]$TestHookBeforeCommit,
        [switch]$RequireUnchanged,
        # Deliberately untyped (not [string]): a [string]-typed parameter converts an explicitly
        # passed $null into '' even with [AllowNull()], which would make "expected absent" ($null)
        # indistinguishable from "expected an empty file" (''). Leaving it untyped preserves $null.
        [AllowNull()]$ExpectedCurrentContent
    )
    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        Assert-LeanLaunchNoReparseInPath $directory
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Assert-LeanLaunchNoReparseInPath $Path
    $encoding = New-Object Text.UTF8Encoding($true)
    $preamble = $encoding.GetPreamble()
    $encodedText = $encoding.GetBytes($json)
    $bytes = New-Object byte[] ($preamble.Length + $encodedText.Length)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($encodedText, 0, $bytes, $preamble.Length, $encodedText.Length)
    $contentHash = Get-LeanLaunchBytesHash -Bytes $bytes

    $tempPath = Join-Path $directory ([IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $directory ([IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.bak')
    $lockPath = $Path + '.lock'
    $lockStream = $null
    try {
        [IO.File]::WriteAllBytes($tempPath, $bytes)
        if ($null -ne $TestHookBeforeCommit) { & $TestHookBeforeCommit }

        $lockStream = Wait-LeanLaunchExclusiveLock -LockPath $lockPath
        Assert-LeanLaunchNoReparseInPath $Path
        if ($RequireUnchanged) {
            $currentContent = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw } else { $null }
            if ($currentContent -ne $ExpectedCurrentContent) {
                throw "Refusing to write $Path`: it changed concurrently since it was last read."
            }
        }
        # Re-checked a second time, immediately adjacent to the swap itself - closing the gap between
        # the compare-and-swap check immediately above and the actual OS-level replace/move call below.
        Assert-LeanLaunchNoReparseInPath $Path
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # The 3-arg File.Replace overload's $null backup path throws ArgumentException on this
            # runtime, despite being documented as valid; use a same-directory backup and remove it,
            # which the underlying ReplaceFile syscall still performs as a single atomic operation.
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
        # A sidecar is transient coordination state, never persistent application data. Remove an idle
        # one after releasing this handle; a newly acquired FileShare.None handle makes cleanup fail
        # harmlessly, preserving serialization for that writer.
        if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Path = $Path; ContentHash = $contentHash; Content = $json }
}

function Test-LeanLaunchRequiredProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$RequiredProperties,
        [string]$ObjectDescription = 'record'
    )
    foreach ($name in $RequiredProperties) {
        if (-not (Test-LeanLaunchHasProperty $Object $name)) {
            throw "$ObjectDescription is missing required property '$name'."
        }
    }
}

function Test-LeanLaunchPropertyType {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][ValidateSet('Int', 'String', 'Array', 'Bool')]$ExpectedType,
        [string]$ObjectDescription = 'record'
    )
    $value = $Object.$PropertyName
    switch ($ExpectedType) {
        # Explicit -isnot [int] check: ConvertFrom-Json parses a JSON integer literal as
        # System.Int32, but a quoted "1" parses as System.String, so this alone (unlike -ne 1,
        # which coerces both operands to match the left side's type) tells the two apart.
        'Int' { if ($value -isnot [int]) { throw "$ObjectDescription property '$PropertyName' must be an integer." } }
        'String' { if ($value -isnot [string]) { throw "$ObjectDescription property '$PropertyName' must be a string." } }
        'Array' { if ($null -ne $value -and $value -isnot [System.Array]) { throw "$ObjectDescription property '$PropertyName' must be an array." } }
        'Bool' { if ($value -isnot [bool]) { throw "$ObjectDescription property '$PropertyName' must be a boolean." } }
    }
}
