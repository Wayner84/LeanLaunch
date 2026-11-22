Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Native handle-bound control closes the PID/service-name replacement races that cannot be closed by
# a CIM re-read followed by Stop-Process/Stop-Service. The same kernel/service handle is used to
# query identity and perform the terminating action; a mismatched or unavailable identity fails closed.
if (-not ('LeanLaunch.NativeControl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace LeanLaunch {
    public static class NativeControl {
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint WAIT_OBJECT_0 = 0x00000000;
        private const uint SC_MANAGER_CONNECT = 0x0001;
        private const uint SERVICE_QUERY_STATUS = 0x0004;
        private const uint SERVICE_STOP = 0x0020;
        private const uint SERVICE_QUERY_CONFIG = 0x0001;
        private const uint SERVICE_CHANGE_CONFIG = 0x0002;
        private const uint SERVICE_CONTROL_STOP = 0x00000001;
        private const uint SERVICE_STOPPED = 0x00000001;
        private const uint SERVICE_RUNNING = 0x00000004;
        private const uint SERVICE_NO_CHANGE = 0xFFFFFFFF;
        private const int SC_STATUS_PROCESS_INFO = 0;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SERVICE_STATUS_PROCESS {
            public uint ServiceType;
            public uint CurrentState;
            public uint ControlsAccepted;
            public uint Win32ExitCode;
            public uint ServiceSpecificExitCode;
            public uint CheckPoint;
            public uint WaitHint;
            public uint ProcessId;
            public uint ServiceFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SERVICE_STATUS {
            public uint ServiceType;
            public uint CurrentState;
            public uint ControlsAccepted;
            public uint Win32ExitCode;
            public uint ServiceSpecificExitCode;
            public uint CheckPoint;
            public uint WaitHint;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenSCManager(string machineName, string databaseName, uint desiredAccess);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenService(IntPtr manager, string serviceName, uint desiredAccess);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceStatusEx(IntPtr service, int infoLevel, out SERVICE_STATUS_PROCESS status, int bufferSize, out int bytesNeeded);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ControlService(IntPtr service, uint control, out SERVICE_STATUS status);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceConfig(IntPtr service, IntPtr serviceConfig, uint bufSize, out uint bytesNeeded);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ChangeServiceConfig(
            IntPtr service, uint serviceType, uint startType, uint errorControl,
            string binaryPathName, string loadOrderGroup, IntPtr tagId, string dependencies,
            string serviceStartName, string password, string displayName);

        private static long FileTimeValue(FILETIME value) {
            return ((long)value.High << 32) | value.Low;
        }

        private static long ReadCreationTime(IntPtr process) {
            FILETIME creation, exit, kernel, user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetProcessTimes failed");
            }
            return FileTimeValue(creation);
        }

        public static long GetProcessCreationFileTimeUtcOrZero(int processId) {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero) return 0;
            try {
                return ReadCreationTime(process);
            }
            catch {
                return 0;
            }
            finally {
                CloseHandle(process);
            }
        }

        public static void TerminateProcessIfCreationMatches(int processId, long expectedCreationFileTimeUtc) {
            if (expectedCreationFileTimeUtc <= 0) throw new InvalidOperationException("A native process creation identity is required.");
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, false, processId);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
            try {
                long actual = ReadCreationTime(process);
                if (actual != expectedCreationFileTimeUtc) {
                    throw new InvalidOperationException("Process creation identity no longer matches; refusing termination.");
                }
                if (!TerminateProcess(process, 1)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateProcess failed");
                }
                if (WaitForSingleObject(process, 5000) != WAIT_OBJECT_0) {
                    throw new InvalidOperationException("The terminated process did not exit within the safety bound.");
                }
            }
            finally {
                CloseHandle(process);
            }
        }

        public static void WaitForSingleObjectIfCreationMatches(int processId, long expectedCreationFileTimeUtc) {
            if (expectedCreationFileTimeUtc <= 0) throw new InvalidOperationException("A native process creation identity is required.");
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, processId);
            if (process == IntPtr.Zero) {
                // The PID no longer resolves to any process at all - the original process has already exited.
                return;
            }
            try {
                long actual = ReadCreationTime(process);
                if (actual != expectedCreationFileTimeUtc) {
                    // The PID now belongs to an unrelated process created after ours exited; there is
                    // nothing left to wait for and waiting on this handle would wait for the wrong process.
                    return;
                }
                WaitForSingleObject(process, unchecked((uint)System.Threading.Timeout.Infinite));
            }
            finally {
                CloseHandle(process);
            }
        }

        private static uint ReadServiceStartType(IntPtr service) {
            uint bytesNeeded;
            QueryServiceConfig(service, IntPtr.Zero, 0, out bytesNeeded);
            if (bytesNeeded == 0) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceConfig failed to report a buffer size");
            }
            IntPtr buffer = Marshal.AllocHGlobal((int)bytesNeeded);
            try {
                uint actualBytesNeeded;
                if (!QueryServiceConfig(service, buffer, bytesNeeded, out actualBytesNeeded)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceConfig failed");
                }
                // QUERY_SERVICE_CONFIGW's second field (after the leading dwServiceType DWORD) is
                // dwStartType; reading that one DWORD directly avoids marshalling the several
                // trailing LPWSTR fields this call never needs.
                return (uint)Marshal.ReadInt32(buffer, 4);
            }
            finally {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void SetServiceStartModeIfCurrentModeMatches(string serviceName, uint expectedStartType, uint newStartType) {
            if (String.IsNullOrWhiteSpace(serviceName)) throw new InvalidOperationException("A service name is required.");
            IntPtr manager = OpenSCManager(null, null, SC_MANAGER_CONNECT);
            if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager failed");
            IntPtr service = IntPtr.Zero;
            try {
                service = OpenService(manager, serviceName, SERVICE_QUERY_CONFIG | SERVICE_CHANGE_CONFIG);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenService failed");
                uint actual = ReadServiceStartType(service);
                if (actual != expectedStartType) {
                    throw new InvalidOperationException("Service start type no longer matches the recorded value; refusing to change it.");
                }
                if (!ChangeServiceConfig(service, SERVICE_NO_CHANGE, newStartType, SERVICE_NO_CHANGE, null, null, IntPtr.Zero, null, null, null, null)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "ChangeServiceConfig failed");
                }
            }
            finally {
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                CloseServiceHandle(manager);
            }
        }

        public static void StopServiceIfProcessMatches(string serviceName, int expectedProcessId, long expectedProcessCreationFileTimeUtc) {
            if (String.IsNullOrWhiteSpace(serviceName) || expectedProcessId <= 0) {
                throw new InvalidOperationException("A service name and positive owned process ID are required.");
            }
            if (expectedProcessCreationFileTimeUtc <= 0) {
                throw new InvalidOperationException("A native process creation identity is required.");
            }
            IntPtr manager = OpenSCManager(null, null, SC_MANAGER_CONNECT);
            if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager failed");
            IntPtr service = IntPtr.Zero;
            IntPtr process = IntPtr.Zero;
            try {
                service = OpenService(manager, serviceName, SERVICE_QUERY_STATUS | SERVICE_STOP);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenService failed");
                SERVICE_STATUS_PROCESS status;
                int needed;
                if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, out status, Marshal.SizeOf(typeof(SERVICE_STATUS_PROCESS)), out needed)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceStatusEx failed");
                }
                if (status.CurrentState != SERVICE_RUNNING || status.ProcessId != (uint)expectedProcessId) {
                    throw new InvalidOperationException("Service process identity no longer matches; refusing stop.");
                }
                // A PID match alone does not prove this is still the same process instance the caller
                // observed earlier - the service could have been stopped and a wholly unrelated process
                // could have been assigned the same (reused) PID before this call ran. Opening a handle
                // on the reported PID and comparing its native creation time closes that race the same
                // way TerminateProcessIfCreationMatches already does for plain process termination.
                process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, expectedProcessId);
                if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
                long actualCreation = ReadCreationTime(process);
                if (actualCreation != expectedProcessCreationFileTimeUtc) {
                    throw new InvalidOperationException("Service process creation identity no longer matches; refusing stop.");
                }
                SERVICE_STATUS stopped;
                if (!ControlService(service, SERVICE_CONTROL_STOP, out stopped)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "ControlService failed");
                }
                DateTime deadline = DateTime.UtcNow.AddSeconds(30);
                do {
                    if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, out status, Marshal.SizeOf(typeof(SERVICE_STATUS_PROCESS)), out needed)) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceStatusEx failed while waiting for stop");
                    }
                    if (status.CurrentState == SERVICE_STOPPED) return;
                    Thread.Sleep(250);
                } while (DateTime.UtcNow < deadline);
                throw new InvalidOperationException("The service did not stop within the safety bound.");
            }
            finally {
                if (process != IntPtr.Zero) CloseHandle(process);
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                CloseServiceHandle(manager);
            }
        }
    }
}
'@
}

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

function ConvertTo-LeanLaunchProfileFromContent {
    <#
    Parses and strictly validates profile JSON that is ALREADY held in memory as a string - this
    function never performs its own filesystem read. $SourcePath is used only as a label (the
    filename-must-match-declared-name check, and the returned sourcePath field); it is never
    re-opened here. This is the one shared validation body both Import-LeanLaunchProfile (which reads
    $Path's bytes itself, exactly once, then calls this) and Get-LeanLaunchValidatedManagedProfile
    (which already holds the exact bytes it separately hashed for the Managed-run binding check) funnel
    through, so a profile is never validated from a second, potentially different, disk read.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [switch]$SkipExecutableCheck
    )
    try {
        $raw = $Content | ConvertFrom-Json
    }
    catch {
        throw "Profile is not valid JSON: $SourcePath. $($_.Exception.Message)"
    }
    Test-LeanLaunchPropertyType $raw 'schemaVersion' 'Int' 'Profile'
    if ($raw.schemaVersion -ne 1) { throw 'Profile schemaVersion must be 1.' }
    if (-not ($raw.name -is [string]) -or -not (Test-LeanLaunchProfileName $raw.name)) { throw 'Profile name is invalid.' }
    if (-not ($raw.executable -is [string])) { throw 'Profile executable must be a string.' }
    if (-not ([IO.Path]::GetFileNameWithoutExtension($SourcePath)).Equals($raw.name, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Profile filename must match its declared name.'
    }
    foreach ($arrayProperty in @('arguments','services','residualProcesses','waitForProcessNames')) {
        if ((Test-LeanLaunchHasProperty $raw $arrayProperty) -and $null -ne $raw.$arrayProperty -and
            -not ($raw.$arrayProperty -is [System.Array])) {
            throw "Profile property '$arrayProperty' must be an array."
        }
    }
    foreach ($stringProperty in @('displayName','workingDirectory')) {
        if ((Test-LeanLaunchHasProperty $raw $stringProperty) -and $null -ne $raw.$stringProperty -and
            -not ($raw.$stringProperty -is [string])) {
            throw "Profile property '$stringProperty' must be a string."
        }
    }

    $executable = Expand-LeanLaunchValue $raw.executable
    if ([string]::IsNullOrWhiteSpace($executable)) { throw 'Profile executable is required.' }
    if (-not $SkipExecutableCheck -and -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Profile executable was not found: $executable"
    }

    $services = @()
    $rawServices = $null
    if (Test-LeanLaunchHasProperty $raw 'services') { $rawServices = $raw.services }
    foreach ($service in (ConvertTo-LeanLaunchArray $rawServices)) {
        if (-not ($service -is [string])) { throw 'Every service entry must be a string.' }
        $serviceName = [string]$service
        if (-not (Test-LeanLaunchServiceName $serviceName)) { throw "Invalid service name: $serviceName" }
        $services += $serviceName
    }

    $residual = @()
    $rawResidualProcesses = $null
    if (Test-LeanLaunchHasProperty $raw 'residualProcesses') { $rawResidualProcesses = $raw.residualProcesses }
    foreach ($item in (ConvertTo-LeanLaunchArray $rawResidualProcesses)) {
        if ($null -eq $item -or -not (Test-LeanLaunchHasProperty $item 'name') -or -not ($item.name -is [string])) {
            throw 'Every residual process entry must be an object with a string name.'
        }
        $processName = [string]$item.name
        if (-not (Test-LeanLaunchProcessName $processName)) { throw "Invalid residual process name: $processName" }
        $processPath = $null
        if ((Test-LeanLaunchHasProperty $item 'executablePath') -and $item.executablePath) {
            if (-not ($item.executablePath -is [string])) { throw "Residual process '$processName' executablePath must be a string." }
            $processPath = Expand-LeanLaunchValue ([string]$item.executablePath)
        }
        if ([string]::IsNullOrWhiteSpace($processPath)) {
            throw "Residual process '$processName' requires executablePath."
        }
        $residual += [pscustomobject]@{ name = $processName; executablePath = $processPath }
    }

    $waitNames = @()
    $rawWaitNames = $null
    if (Test-LeanLaunchHasProperty $raw 'waitForProcessNames') { $rawWaitNames = $raw.waitForProcessNames }
    foreach ($name in (ConvertTo-LeanLaunchArray $rawWaitNames)) {
        if (-not ($name -is [string])) { throw 'Every waitForProcessNames entry must be a string.' }
        $processName = [string]$name
        if (-not (Test-LeanLaunchProcessName $processName)) { throw "Invalid wait process name: $processName" }
        $waitNames += $processName
    }

    $stopStartedServices = $true
    $stopResidualProcesses = $true
    if ((Test-LeanLaunchHasProperty $raw 'cleanup') -and $null -ne $raw.cleanup) {
        if ($raw.cleanup -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'Profile cleanup must be an object.'
        }
        if (Test-LeanLaunchHasProperty $raw.cleanup 'stopStartedServices') {
            if (-not ($raw.cleanup.stopStartedServices -is [bool])) { throw 'cleanup.stopStartedServices must be boolean.' }
            $stopStartedServices = [bool]$raw.cleanup.stopStartedServices
        }
        if (Test-LeanLaunchHasProperty $raw.cleanup 'stopResidualProcesses') {
            if (-not ($raw.cleanup.stopResidualProcesses -is [bool])) { throw 'cleanup.stopResidualProcesses must be boolean.' }
            $stopResidualProcesses = [bool]$raw.cleanup.stopResidualProcesses
        }
    }

    $displayName = [string]$raw.name
    if ((Test-LeanLaunchHasProperty $raw 'displayName') -and $raw.displayName) {
        $displayName = [string]$raw.displayName
    }
    $workingDirectory = Split-Path -Parent $executable
    if ((Test-LeanLaunchHasProperty $raw 'workingDirectory') -and $raw.workingDirectory) {
        $workingDirectory = Expand-LeanLaunchValue ([string]$raw.workingDirectory)
    }
    $arguments = @()
    if (Test-LeanLaunchHasProperty $raw 'arguments') {
        $arguments = @((ConvertTo-LeanLaunchArray $raw.arguments) | ForEach-Object {
            if (-not ($_ -is [string])) { throw 'Every argument must be a string.' }
            Expand-LeanLaunchValue ([string]$_)
        })
    }

    [pscustomobject]@{
        schemaVersion = 1
        name = [string]$raw.name
        displayName = $displayName
        executable = $executable
        arguments = $arguments
        workingDirectory = $workingDirectory
        services = $services
        residualProcesses = $residual
        waitForProcessNames = $waitNames
        cleanup = [pscustomobject]@{
            stopStartedServices = $stopStartedServices
            stopResidualProcesses = $stopResidualProcesses
        }
        sourcePath = $SourcePath
    }
}

function Import-LeanLaunchProfile {
    <#
    Reads $Path's exact bytes exactly once and validates that same immutable buffer via
    ConvertTo-LeanLaunchProfileFromContent - never re-opening $Path a second time within this call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$SkipExecutableCheck
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Profile not found: $Path"
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $bytes = [IO.File]::ReadAllBytes($resolvedPath)
    $content = [Text.Encoding]::UTF8.GetString($bytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
    return ConvertTo-LeanLaunchProfileFromContent -Content $content -SourcePath $resolvedPath -SkipExecutableCheck:$SkipExecutableCheck
}

function New-LeanLaunchProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string]$DataRoot,
        [switch]$Force
    )
    if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Profile name is invalid.' }
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $path = Join-Path $paths.Profiles ($Name + '.json')
    if ((Test-Path -LiteralPath $path) -and -not $Force) { throw "Profile already exists: $path" }
    if (-not $PSCmdlet.ShouldProcess($path, 'Create LeanLaunch profile')) { return $null }
    New-Item -ItemType Directory -Path $paths.Profiles -Force | Out-Null
    $profile = [ordered]@{
        schemaVersion = 1
        name = $Name
        displayName = $Name
        executable = $Executable
        arguments = @()
        workingDirectory = ''
        services = @()
        residualProcesses = @()
        waitForProcessNames = @()
        cleanup = [ordered]@{ stopStartedServices = $true; stopResidualProcesses = $true }
    }
    Write-LeanLaunchJsonAtomic -Path $path -InputObject $profile -Depth 6 | Out-Null
    return Get-Item -LiteralPath $path
}

function Get-LeanLaunchProfiles {
    [CmdletBinding()]
    param([string]$DataRoot, [string]$RepositoryProfiles)
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $byName = @{}
    foreach ($root in @($paths.Profiles, $RepositoryProfiles)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)) {
                $key = $file.BaseName.ToLowerInvariant()
                if (-not $byName.ContainsKey($key)) {
                    $byName[$key] = [pscustomobject]@{ name = $file.BaseName; path = $file.FullName; source = $root }
                }
            }
        }
    }
    return @($byName.Values | Sort-Object name)
}

function Get-LeanLaunchNormalizedCollectorResults {
    <#
    Wraps BOTH invoking a collector and normalizing its raw results in one failure boundary. A
    collector that throws outright and a collector that returns superficially valid objects whose
    VALUES fail to normalize - a non-numeric ProcessId, for example, which throws only once the
    [int]/[long]/etc. cast in $Normalizer runs - are treated identically: the specific failure is
    recorded as one collectionErrors entry for this resource type, and every OTHER collector's
    evidence is completely unaffected. Without this, a normalization failure would propagate uncaught
    out of New-LeanLaunchSnapshot entirely, losing every other collector's evidence too instead of
    degrading to partial evidence for just the one resource type that failed.
    #>
    param(
        [scriptblock]$Collector,
        [string]$Name,
        [System.Collections.ArrayList]$Errors,
        [scriptblock]$Normalizer
    )
    try {
        $raw = @(& $Collector)
        return @($raw | ForEach-Object -Process $Normalizer)
    }
    catch {
        [void]$Errors.Add([pscustomobject]@{ collector = $Name; message = $_.Exception.Message })
        return @()
    }
}

function New-LeanLaunchSnapshot {
    [CmdletBinding()]
    param([hashtable]$Collectors)

    if ($null -eq $Collectors) {
        $Collectors = @{
            Processes = {
                Get-CimInstance Win32_Process | Select-Object Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine, WorkingSetSize
            }
            Services = {
                Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, ProcessId
            }
            Startup = {
                Get-CimInstance Win32_StartupCommand | Select-Object Location, Name, Command, User
            }
            ScheduledTasks = {
                if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
                    Get-ScheduledTask | Select-Object TaskPath, TaskName, State
                }
            }
        }
    }

    $errors = New-Object System.Collections.ArrayList
    $processes = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.Processes -Name 'Processes' -Errors $errors -Normalizer {
        # Every mandatory field is explicitly checked for presence, a non-null value, AND an accepted
        # runtime type before any cast is attempted - a field that is merely missing or null (as
        # opposed to present but wrong-typed) would otherwise cast silently ($null -> '' or 0), and a
        # numeric-looking STRING (or any other object) would otherwise be silently coerced by [int]/
        # [string]/[long] rather than surfaced as the malformed evidence it actually is.
        # ExecutablePath/Path is the one field exempted from the non-null rule: real Windows processes
        # (System Idle Process, System, Registry, Secure System, Memory Compression) legitimately
        # report a null path, so that field only requires the property to exist at all (a collector
        # that omits BOTH alternates entirely is still malformed) and, when present, to be a string.
        if (-not (Test-LeanLaunchHasProperty $_ 'Name') -or $null -eq $_.Name) { throw 'Process collector entry is missing a name.' }
        if ($_.Name -isnot [string]) { throw 'Process collector entry has a non-string name.' }
        $hasProcessId = (Test-LeanLaunchHasProperty $_ 'ProcessId') -and $null -ne $_.ProcessId
        $hasId = (Test-LeanLaunchHasProperty $_ 'Id') -and $null -ne $_.Id
        if (-not $hasProcessId -and -not $hasId) { throw 'Process collector entry is missing a process ID.' }
        $id = if ($hasProcessId) { $_.ProcessId } else { $_.Id }
        if (-not (Test-LeanLaunchAcceptedNumericValue $id)) { throw 'Process collector entry has a non-numeric process ID.' }
        $hasExecutablePathProperty = Test-LeanLaunchHasProperty $_ 'ExecutablePath'
        $hasPathProperty = Test-LeanLaunchHasProperty $_ 'Path'
        if (-not $hasExecutablePathProperty -and -not $hasPathProperty) { throw 'Process collector entry is missing an executable path.' }
        $path = if ($hasExecutablePathProperty -and $null -ne $_.ExecutablePath) { $_.ExecutablePath } elseif ($hasPathProperty) { $_.Path } else { $null }
        if ($null -ne $path -and $path -isnot [string]) { throw 'Process collector entry has a non-string executable path.' }
        $hasWorkingSetSize = (Test-LeanLaunchHasProperty $_ 'WorkingSetSize') -and $null -ne $_.WorkingSetSize
        $hasWorkingSet64 = (Test-LeanLaunchHasProperty $_ 'WorkingSet64') -and $null -ne $_.WorkingSet64
        if (-not $hasWorkingSetSize -and -not $hasWorkingSet64) { throw 'Process collector entry is missing a working-set size.' }
        $workingSet = if ($hasWorkingSetSize) { $_.WorkingSetSize } else { $_.WorkingSet64 }
        if (-not (Test-LeanLaunchAcceptedNumericValue $workingSet)) { throw 'Process collector entry has a non-numeric working-set size.' }
        [pscustomobject]@{
            name = [string]$_.Name
            id = [int]$id
            parentId = if (Test-LeanLaunchHasProperty $_ 'ParentProcessId') { [int]$_.ParentProcessId } else { 0 }
            path = [string]$path
            commandLine = if (Test-LeanLaunchHasProperty $_ 'CommandLine') { [string]$_.CommandLine } else { '' }
            workingSetBytes = [long]$workingSet
        }
    } | Sort-Object name, id)

    $services = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.Services -Name 'Services' -Errors $errors -Normalizer {
        if (-not (Test-LeanLaunchHasProperty $_ 'Name') -or $null -eq $_.Name) { throw 'Service collector entry is missing a name.' }
        if ($_.Name -isnot [string]) { throw 'Service collector entry has a non-string name.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'DisplayName') -or $null -eq $_.DisplayName) { throw 'Service collector entry is missing a display name.' }
        if ($_.DisplayName -isnot [string]) { throw 'Service collector entry has a non-string display name.' }
        $hasState = (Test-LeanLaunchHasProperty $_ 'State') -and $null -ne $_.State
        $hasStatus = (Test-LeanLaunchHasProperty $_ 'Status') -and $null -ne $_.Status
        if (-not $hasState -and -not $hasStatus) { throw 'Service collector entry is missing a status.' }
        $status = if ($hasState) { $_.State } else { $_.Status }
        if ($status -isnot [string]) { throw 'Service collector entry has a non-string status.' }
        $hasStartMode = (Test-LeanLaunchHasProperty $_ 'StartMode') -and $null -ne $_.StartMode
        $hasStartType = (Test-LeanLaunchHasProperty $_ 'StartType') -and $null -ne $_.StartType
        if (-not $hasStartMode -and -not $hasStartType) { throw 'Service collector entry is missing a start type.' }
        $startType = if ($hasStartMode) { $_.StartMode } else { $_.StartType }
        if ($startType -isnot [string]) { throw 'Service collector entry has a non-string start type.' }
        [pscustomobject]@{
            name = [string]$_.Name
            displayName = [string]$_.DisplayName
            status = [string]$status
            startType = [string]$startType
            processId = if ((Test-LeanLaunchHasProperty $_ 'ProcessId') -and $null -ne $_.ProcessId) {
                if (-not (Test-LeanLaunchAcceptedNumericValue $_.ProcessId)) { throw 'Service collector entry has a non-numeric process ID.' }
                [int]$_.ProcessId
            } else { 0 }
        }
    } | Sort-Object name)

    $startup = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.Startup -Name 'Startup' -Errors $errors -Normalizer {
        if (-not (Test-LeanLaunchHasProperty $_ 'Location') -or $null -eq $_.Location) { throw 'Startup collector entry is missing a location.' }
        if ($_.Location -isnot [string]) { throw 'Startup collector entry has a non-string location.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'Name') -or $null -eq $_.Name) { throw 'Startup collector entry is missing a name.' }
        if ($_.Name -isnot [string]) { throw 'Startup collector entry has a non-string name.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'Command') -or $null -eq $_.Command) { throw 'Startup collector entry is missing a command.' }
        if ($_.Command -isnot [string]) { throw 'Startup collector entry has a non-string command.' }
        $startupUser = ''
        if ((Test-LeanLaunchHasProperty $_ 'User') -and $null -ne $_.User) {
            if ($_.User -isnot [string]) { throw 'Startup collector entry has a non-string user.' }
            $startupUser = [string]$_.User
        }
        [pscustomobject]@{ location = [string]$_.Location; name = [string]$_.Name; command = [string]$_.Command; user = $startupUser }
    } | Sort-Object location, name)

    $tasks = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.ScheduledTasks -Name 'ScheduledTasks' -Errors $errors -Normalizer {
        if (-not (Test-LeanLaunchHasProperty $_ 'TaskPath') -or $null -eq $_.TaskPath) { throw 'ScheduledTask collector entry is missing a task path.' }
        if ($_.TaskPath -isnot [string]) { throw 'ScheduledTask collector entry has a non-string task path.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'TaskName') -or $null -eq $_.TaskName) { throw 'ScheduledTask collector entry is missing a task name.' }
        if ($_.TaskName -isnot [string]) { throw 'ScheduledTask collector entry has a non-string task name.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'State') -or $null -eq $_.State) { throw 'ScheduledTask collector entry is missing a state.' }
        # Real Get-ScheduledTask returns State as a generated enum type (ScheduledTask.StateEnum), not
        # a plain string - a genuinely well-typed representation of state, not the kind of sneaky
        # coercion (a numeric-looking string standing in for a number) this strict typing guards
        # against. Both a string and an enum are accepted; anything else (a bare int, say) is not.
        if ($_.State -isnot [string] -and $_.State -isnot [System.Enum]) { throw 'ScheduledTask collector entry has a non-string, non-enum state.' }
        [pscustomobject]@{ taskPath = [string]$_.TaskPath; taskName = [string]$_.TaskName; state = [string]$_.State }
    } | Sort-Object taskPath, taskName)

    [pscustomobject]@{
        schemaVersion = 1
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        computerName = $env:COMPUTERNAME
        processes = $processes
        services = $services
        startupEntries = $startup
        scheduledTasks = $tasks
        collectionErrors = @($errors)
    }
}

function Save-LeanLaunchSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DataRoot
    )
    if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Snapshot name is invalid.' }
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    New-Item -ItemType Directory -Path $paths.Snapshots -Force | Out-Null
    $path = Join-Path $paths.Snapshots ($Name + '.json')
    Write-LeanLaunchJsonAtomic -Path $path -InputObject $Snapshot -Depth 8 | Out-Null
    return Get-Item -LiteralPath $path
}

function Import-LeanLaunchSnapshot {
    [CmdletBinding()]
    param([string]$Name, [string]$Path, [string]$DataRoot)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Snapshot name is invalid.' }
        $Path = Join-Path (Get-LeanLaunchPaths -DataRoot $DataRoot).Snapshots ($Name + '.json')
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Snapshot not found: $Path" }
    try {
        $snapshot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Snapshot is not valid JSON: $Path. $($_.Exception.Message)"
    }
    Test-LeanLaunchRequiredProperties $snapshot @('schemaVersion', 'processes', 'services', 'startupEntries', 'scheduledTasks', 'collectionErrors') 'Snapshot'
    Test-LeanLaunchPropertyType $snapshot 'schemaVersion' 'Int' 'Snapshot'
    if ($snapshot.schemaVersion -ne 1) { throw 'Unsupported snapshot schema version.' }
    foreach ($arrayProperty in @('processes', 'services', 'startupEntries', 'scheduledTasks', 'collectionErrors')) {
        Test-LeanLaunchPropertyType $snapshot $arrayProperty 'Array' 'Snapshot'
    }
    foreach ($process in @($snapshot.processes)) {
        Test-LeanLaunchRequiredProperties $process @('name', 'id', 'parentId', 'path', 'commandLine', 'workingSetBytes') 'Snapshot process entry'
        Test-LeanLaunchPropertyType $process 'name' 'String' 'Snapshot process entry'
        Test-LeanLaunchPropertyType $process 'path' 'String' 'Snapshot process entry'
        Test-LeanLaunchPropertyType $process 'commandLine' 'String' 'Snapshot process entry'
        if (-not (Test-LeanLaunchAcceptedNumericValue $process.id)) { throw "Snapshot process entry property 'id' must be a genuine numeric value." }
        if (-not (Test-LeanLaunchAcceptedNumericValue $process.parentId)) { throw "Snapshot process entry property 'parentId' must be a genuine numeric value." }
        if (-not (Test-LeanLaunchAcceptedNumericValue $process.workingSetBytes)) { throw "Snapshot process entry property 'workingSetBytes' must be a genuine numeric value." }
    }
    foreach ($service in @($snapshot.services)) {
        Test-LeanLaunchRequiredProperties $service @('name', 'displayName', 'status', 'startType', 'processId') 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'name' 'String' 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'displayName' 'String' 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'status' 'String' 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'startType' 'String' 'Snapshot service entry'
        if (-not (Test-LeanLaunchAcceptedNumericValue $service.processId)) { throw "Snapshot service entry property 'processId' must be a genuine numeric value." }
    }
    foreach ($startupEntry in @($snapshot.startupEntries)) {
        Test-LeanLaunchRequiredProperties $startupEntry @('location', 'name', 'command', 'user') 'Snapshot startup entry'
        foreach ($stringProperty in @('location', 'name', 'command', 'user')) {
            Test-LeanLaunchPropertyType $startupEntry $stringProperty 'String' 'Snapshot startup entry'
        }
    }
    foreach ($task in @($snapshot.scheduledTasks)) {
        Test-LeanLaunchRequiredProperties $task @('taskPath', 'taskName', 'state') 'Snapshot scheduled task entry'
        foreach ($stringProperty in @('taskPath', 'taskName', 'state')) {
            Test-LeanLaunchPropertyType $task $stringProperty 'String' 'Snapshot scheduled task entry'
        }
    }
    foreach ($collectionError in @($snapshot.collectionErrors)) {
        Test-LeanLaunchRequiredProperties $collectionError @('collector', 'message') 'Snapshot collection-error entry'
        Test-LeanLaunchPropertyType $collectionError 'collector' 'String' 'Snapshot collection-error entry'
        Test-LeanLaunchPropertyType $collectionError 'message' 'String' 'Snapshot collection-error entry'
    }
    return $snapshot
}

function Get-LeanLaunchProcessGroups {
    param($Processes)
    $groups = @{}
    foreach ($process in @($Processes)) {
        $key = (([string]$process.name).ToLowerInvariant() + '|' + ([string]$process.path).ToLowerInvariant())
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ name=[string]$process.name; path=[string]$process.path; count=0; workingSetBytes=[long]0 }
        }
        $groups[$key].count++
        $groups[$key].workingSetBytes += [long]$process.workingSetBytes
    }
    return $groups
}

function Get-LeanLaunchKeyedRecords {
    param($Records, [scriptblock]$KeySelector)
    $index = @{}
    foreach ($record in @($Records)) { $index[(& $KeySelector $record)] = $record }
    return $index
}

function Compare-LeanLaunchSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]$Before,
        [Parameter(Mandatory = $true, Position = 1)]$After
    )
    Test-LeanLaunchPropertyType $Before 'schemaVersion' 'Int' 'Snapshot'
    Test-LeanLaunchPropertyType $After 'schemaVersion' 'Int' 'Snapshot'
    if ($Before.schemaVersion -ne 1 -or $After.schemaVersion -ne 1) { throw 'Unsupported snapshot schema version.' }

    $beforeProcesses = Get-LeanLaunchProcessGroups $Before.processes
    $afterProcesses = Get-LeanLaunchProcessGroups $After.processes
    $processChanges = @()
    foreach ($key in @($beforeProcesses.Keys + $afterProcesses.Keys | Sort-Object -Unique)) {
        $beforeItem = $beforeProcesses[$key]
        $afterItem = $afterProcesses[$key]
        $beforeCount = if ($null -eq $beforeItem) { 0 } else { $beforeItem.count }
        $afterCount = if ($null -eq $afterItem) { 0 } else { $afterItem.count }
        $beforeMemory = if ($null -eq $beforeItem) { 0 } else { $beforeItem.workingSetBytes }
        $afterMemory = if ($null -eq $afterItem) { 0 } else { $afterItem.workingSetBytes }
        $name = if ($null -ne $afterItem) { $afterItem.name } else { $beforeItem.name }
        $path = if ($null -ne $afterItem) { $afterItem.path } else { $beforeItem.path }
        $memoryDelta = [long]$afterMemory - [long]$beforeMemory
        if ($beforeCount -ne $afterCount -or [Math]::Abs($memoryDelta) -ge 10MB) {
            $processChanges += [pscustomobject]@{
                name=$name; path=$path; beforeCount=$beforeCount; afterCount=$afterCount
                countDelta=($afterCount-$beforeCount); workingSetDeltaBytes=$memoryDelta
            }
        }
    }

    $beforeServices = Get-LeanLaunchKeyedRecords $Before.services { param($x) ([string]$x.name).ToLowerInvariant() }
    $afterServices = Get-LeanLaunchKeyedRecords $After.services { param($x) ([string]$x.name).ToLowerInvariant() }
    $serviceChanges = @()
    foreach ($key in @($beforeServices.Keys + $afterServices.Keys | Sort-Object -Unique)) {
        $b = $beforeServices[$key]; $a = $afterServices[$key]
        $beforeStatus = if ($null -eq $b) { '<missing>' } else { [string]$b.status }
        $afterStatus = if ($null -eq $a) { '<missing>' } else { [string]$a.status }
        $beforeStart = if ($null -eq $b) { '<missing>' } else { [string]$b.startType }
        $afterStart = if ($null -eq $a) { '<missing>' } else { [string]$a.startType }
        if ($beforeStatus -ne $afterStatus -or $beforeStart -ne $afterStart) {
            $serviceChanges += [pscustomobject]@{
                name=if ($null -ne $a) { $a.name } else { $b.name }
                beforeStatus=$beforeStatus; afterStatus=$afterStatus
                beforeStartType=$beforeStart; afterStartType=$afterStart
            }
        }
    }

    $beforeStartup = Get-LeanLaunchKeyedRecords $Before.startupEntries { param($x) $user = if (Test-LeanLaunchHasProperty $x 'user') { [string]$x.user } else { '' }; (([string]$x.location)+'|'+([string]$x.name)+'|'+([string]$x.command)+'|'+$user).ToLowerInvariant() }
    $afterStartup = Get-LeanLaunchKeyedRecords $After.startupEntries { param($x) $user = if (Test-LeanLaunchHasProperty $x 'user') { [string]$x.user } else { '' }; (([string]$x.location)+'|'+([string]$x.name)+'|'+([string]$x.command)+'|'+$user).ToLowerInvariant() }
    $beforeTasks = Get-LeanLaunchKeyedRecords $Before.scheduledTasks { param($x) (([string]$x.taskPath)+'|'+([string]$x.taskName)).ToLowerInvariant() }
    $afterTasks = Get-LeanLaunchKeyedRecords $After.scheduledTasks { param($x) (([string]$x.taskPath)+'|'+([string]$x.taskName)).ToLowerInvariant() }

    [pscustomobject]@{
        schemaVersion = 1
        comparedAtUtc = [DateTime]::UtcNow.ToString('o')
        processChanges = @($processChanges | Sort-Object countDelta, workingSetDeltaBytes -Descending)
        serviceChanges = @($serviceChanges | Sort-Object name)
        addedStartupEntries = @($afterStartup.Keys | Where-Object { -not $beforeStartup.ContainsKey($_) } | ForEach-Object { $afterStartup[$_] })
        removedStartupEntries = @($beforeStartup.Keys | Where-Object { -not $afterStartup.ContainsKey($_) } | ForEach-Object { $beforeStartup[$_] })
        addedScheduledTasks = @($afterTasks.Keys | Where-Object { -not $beforeTasks.ContainsKey($_) } | ForEach-Object { $afterTasks[$_] })
        removedScheduledTasks = @($beforeTasks.Keys | Where-Object { -not $afterTasks.ContainsKey($_) } | ForEach-Object { $beforeTasks[$_] })
        # Each entry keeps its original 'collector'/'message' fields (existing consumers - the CLI's
        # collector-name warning included - keep working unchanged) and gains a 'source' field so a
        # reviewer can tell which snapshot a given collector failure came from without guessing.
        collectionErrors = @(
            @($Before.collectionErrors | ForEach-Object { [pscustomobject]@{ source = 'before'; collector = $_.collector; message = $_.message } }) +
            @($After.collectionErrors | ForEach-Object { [pscustomobject]@{ source = 'after'; collector = $_.collector; message = $_.message } })
        )
    }
}

# --- Application records: policy toggle + enforced before/after audit workflow -----------------
#
# An "application" record ties a reviewed install together: which resources a before/after snapshot
# diff surfaced, how each was classified, and one explicit policy toggle (Managed/Unmanaged). This is
# the shared model consumed by both the CLI and the GUI so lifecycle logic is never duplicated.
#
# Safety invariant encoded here: startup entries and scheduled tasks can only ever be marked
# Reviewed/Unreviewed, never Managed - LeanLaunch never disables autoruns or scheduled tasks, so the
# classification vocabulary itself makes that action impossible to request.

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

function ConvertTo-LeanLaunchServiceStartTypeCode {
    <#
    Maps Win32_Service.StartMode string values to the native SERVICE_*_START DWORD codes
    ChangeServiceConfig expects. The CIM string vocabulary ('Boot','System','Auto','Manual',
    'Disabled') already matches the native enum order exactly.
    #>
    param([Parameter(Mandatory = $true)][string]$StartMode)
    switch ($StartMode) {
        'Boot' { return 0 }
        'System' { return 1 }
        'Auto' { return 2 }
        'Manual' { return 3 }
        'Disabled' { return 4 }
        default { throw "Unknown service start mode: $StartMode" }
    }
}

function New-LeanLaunchDefaultAdapter {
    $adapter = @{
        IsAdministrator = {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        GetService = { param($name) Get-CimInstance Win32_Service -Filter ("Name='" + $name.Replace("'", "''") + "'") -ErrorAction Stop }
        StartService = {
            param($name)
            $controller = Get-Service -Name $name -ErrorAction Stop
            if ([string]$controller.Status -eq 'Running') { return $false }
            try {
                $controller.Start()
                $controller.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                return $true
            }
            catch {
                $current = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($null -ne $current -and [string]$current.Status -eq 'Running') { return $false }
                throw
            }
        }
        StopService = {
            param($name, $expectedProcessId, $expectedProcessCreationFileTimeUtc)
            # Query and stop through one native service handle, and additionally bind to the native
            # creation time of the process backing that PID. Holding the handle prevents a
            # delete/recreate replacement from being substituted between identity validation and stop,
            # and the creation-time check additionally closes a stop/restart-with-PID-reuse race that
            # a service-name+PID check alone cannot: a service can be stopped and a new, unrelated
            # instance can start under the same PID before this call runs.
            [LeanLaunch.NativeControl]::StopServiceIfProcessMatches([string]$name, [int]$expectedProcessId, [long]$expectedProcessCreationFileTimeUtc)
        }
        GetProcessCreationTime = {
            param($processId)
            [LeanLaunch.NativeControl]::GetProcessCreationFileTimeUtcOrZero([int]$processId)
        }
        GetServiceStartMode = {
            param($name)
            $service = Get-CimInstance Win32_Service -Filter ("Name='" + $name.Replace("'", "''") + "'") -ErrorAction Stop
            return [string]$service.StartMode
        }
        SetServiceStartMode = {
            param($name, $expectedStartMode, $newStartMode)
            # Query and change through one native service handle so an out-of-band start-mode change
            # cannot slip in between validating the recorded mode and applying the new one.
            [LeanLaunch.NativeControl]::SetServiceStartModeIfCurrentModeMatches(
                [string]$name,
                (ConvertTo-LeanLaunchServiceStartTypeCode ([string]$expectedStartMode)),
                (ConvertTo-LeanLaunchServiceStartTypeCode ([string]$newStartMode)))
        }
        GetProcesses = {
            Get-CimInstance Win32_Process | Select-Object @{N='Id';E={[int]$_.ProcessId}}, @{N='Name';E={([IO.Path]::GetFileNameWithoutExtension([string]$_.Name))}}, @{N='Path';E={[string]$_.ExecutablePath}}, @{N='ParentId';E={[int]$_.ParentProcessId}}, @{N='CreationDate';E={[string]$_.CreationDate}}, @{N='CreationFileTimeUtc';E={[LeanLaunch.NativeControl]::GetProcessCreationFileTimeUtcOrZero([int]$_.ProcessId)}}
        }
        StartProcess = {
            param($executable, $arguments, $workingDirectory)
            $parameters = @{ FilePath=$executable; PassThru=$true; ErrorAction='Stop' }
            if (@($arguments).Count -gt 0) { $parameters.ArgumentList = ConvertTo-LeanLaunchArgumentString @($arguments) }
            if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { $parameters.WorkingDirectory = $workingDirectory }
            $started = Start-Process @parameters
            # Start-Process returns a .NET Process object with no CreationDate; re-resolve through CIM so the
            # launched process carries the same WMI creation-identity shape used everywhere else for attribution.
            $identity = $null
            for ($attempt = 0; $attempt -lt 50 -and $null -eq $identity; $attempt++) {
                $identity = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$started.Id) -ErrorAction SilentlyContinue
                if ($null -eq $identity) { Start-Sleep -Milliseconds 20 }
            }
            if ($null -eq $identity) {
                $fallbackStart = $null
                try { $fallbackStart = $started.StartTime.ToUniversalTime() } catch { }
                if ($null -eq $fallbackStart) { throw "Unable to establish creation identity for launched process $([int]$started.Id)." }
                $identity = [pscustomobject]@{
                    ProcessId = [int]$started.Id
                    Name = [IO.Path]::GetFileName([string]$executable)
                    ExecutablePath = [string]$executable
                    ParentProcessId = [int]$PID
                    CreationDate = $fallbackStart.ToString('o')
                }
            }
            $nativeCreation = [LeanLaunch.NativeControl]::GetProcessCreationFileTimeUtcOrZero([int]$started.Id)
            [pscustomobject]@{
                Id = [int]$started.Id
                Name = [IO.Path]::GetFileNameWithoutExtension([string]$identity.Name)
                Path = [string]$identity.ExecutablePath
                ParentId = [int]$identity.ParentProcessId
                CreationDate = [string]$identity.CreationDate
                CreationFileTimeUtc = [long]$nativeCreation
            }
        }
        WaitProcess = {
            param($process)
            if (-not (Test-LeanLaunchHasProperty $process 'CreationFileTimeUtc') -or [long]$process.CreationFileTimeUtc -le 0) {
                Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
                return
            }
            # Bind the wait to the same native creation identity used for termination, so a PID reused
            # by an unrelated process after ours exits is never mistaken for our process still running.
            [LeanLaunch.NativeControl]::WaitForSingleObjectIfCreationMatches([int]$process.Id, [long]$process.CreationFileTimeUtc)
        }
        SleepMilliseconds = { param($milliseconds) Start-Sleep -Milliseconds $milliseconds }
        WaitProcessBounded = {
            param($process, $timeoutSeconds)
            $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
            do {
                $current = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$process.Id) -ErrorAction SilentlyContinue
                if ($null -eq $current -or [string]$current.CreationDate -ne [string]$process.CreationDate) { return $true }
                Start-Sleep -Milliseconds 200
            } while ([DateTime]::UtcNow -lt $deadline)
            return $false
        }
        StopProcess = {
            param($process)
            if (-not (Test-LeanLaunchHasProperty $process 'CreationFileTimeUtc') -or [long]$process.CreationFileTimeUtc -le 0) {
                throw "Refusing to stop process $([int]$process.Id): native creation identity is unavailable."
            }
            # Open, validate, and terminate through the same kernel handle. PID reuse between a CIM
            # check and termination therefore cannot redirect the action to a replacement process.
            [LeanLaunch.NativeControl]::TerminateProcessIfCreationMatches([int]$process.Id, [long]$process.CreationFileTimeUtc)
        }
    }
    return $adapter
}

function ConvertTo-LeanLaunchArgumentString {
    [CmdletBinding()]
    param([Parameter(Position=0)][AllowEmptyCollection()][string[]]$Arguments)
    $quoted = @()
    foreach ($argument in @($Arguments)) {
        if ($argument.Length -eq 0) { $quoted += '""'; continue }
        if ($argument -notmatch '[\s"]') { $quoted += $argument; continue }
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') { $slashes++; continue }
            if ($character -eq '"') {
                [void]$builder.Append((@('\') * (2 * $slashes + 1)) -join '')
                [void]$builder.Append('"')
            }
            else {
                [void]$builder.Append((@('\') * $slashes) -join '')
                [void]$builder.Append($character)
            }
            $slashes = 0
        }
        [void]$builder.Append((@('\') * (2 * $slashes)) -join '')
        [void]$builder.Append('"')
        $quoted += $builder.ToString()
    }
    return ($quoted -join ' ')
}

function Get-LeanLaunchServiceStatus {
    param($Service)
    if ($null -eq $Service) { return $null }
    if (Test-LeanLaunchHasProperty $Service 'State') { return [string]$Service.State }
    if (Test-LeanLaunchHasProperty $Service 'Status') { return [string]$Service.Status }
    return $null
}

function Get-LeanLaunchServiceProcessId {
    param($Service)
    if ($null -eq $Service -or -not (Test-LeanLaunchHasProperty $Service 'ProcessId')) { return 0 }
    return [int]$Service.ProcessId
}

function Get-LeanLaunchAdapterProcessCreationTime {
    <#
    Defensive lookup used to bind service-cleanup ownership to native process creation identity
    (not service name+PID alone). Returns 0 - "unavailable" - for an adapter that does not implement
    GetProcessCreationTime at all, which the identity-bound stop call below always then refuses
    (fails closed) rather than falling back to a PID-only comparison.
    #>
    param([hashtable]$Adapter, [int]$ProcessId)
    if ($null -eq $Adapter -or -not $Adapter.ContainsKey('GetProcessCreationTime') -or $null -eq $Adapter.GetProcessCreationTime) { return 0 }
    $value = & $Adapter.GetProcessCreationTime $ProcessId
    if ($null -eq $value) { return 0 }
    return [long]$value
}

function New-LeanLaunchRunPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Profile, [hashtable]$Adapter)
    if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
    $servicesToStart = @()
    $servicesAlreadyRunning = @()
    foreach ($name in @($Profile.services)) {
        $service = & $Adapter.GetService $name
        if ((Get-LeanLaunchServiceStatus $service) -eq 'Running') { $servicesAlreadyRunning += $name }
        else { $servicesToStart += $name }
    }
    [pscustomobject]@{
        profile = $Profile.name
        executable = $Profile.executable
        arguments = @($Profile.arguments)
        workingDirectory = $Profile.workingDirectory
        servicesToStart = $servicesToStart
        servicesAlreadyRunning = $servicesAlreadyRunning
        residualProcessRules = @($Profile.residualProcesses)
    }
}

function Test-LeanLaunchProcessRule {
    param($Process, $Rule)
    $actualName = [IO.Path]::GetFileNameWithoutExtension([string]$Process.Name)
    $expectedName = [IO.Path]::GetFileNameWithoutExtension([string]$Rule.name)
    if (-not $actualName.Equals($expectedName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Rule.executablePath) -or [string]::IsNullOrWhiteSpace([string]$Process.Path)) { return $false }
    return ([IO.Path]::GetFullPath([string]$Process.Path)).TrimEnd('\').Equals(
        ([IO.Path]::GetFullPath([string]$Rule.executablePath)).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Update-LeanLaunchProcessObservations {
    <#
    Accumulates a persistent Id -> {Id;ParentId;CreationDate} map across every poll taken during a run.
    Unlike a single point-in-time snapshot, this lets ancestry be proven even after an ancestor
    (typically the launcher itself) has already exited. A PID whose CreationDate changes between
    observations has been reused by an unrelated process; it is marked $null (permanently distrusted)
    rather than overwritten, so any chain relying on it fails closed.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Observations, $Processes)
    foreach ($item in @($Processes)) {
        $id = [int]$item.Id
        $creationDate = if (Test-LeanLaunchHasProperty $item 'CreationDate') { [string]$item.CreationDate } else { '' }
        if ([string]::IsNullOrWhiteSpace($creationDate)) { continue }
        $parentId = if (Test-LeanLaunchHasProperty $item 'ParentId') { [int]$item.ParentId } else { 0 }
        if (-not $Observations.ContainsKey($id)) {
            $Observations[$id] = [pscustomobject]@{ Id = $id; ParentId = $parentId; CreationDate = $creationDate }
        }
        elseif ($null -ne $Observations[$id] -and -not ([string]$Observations[$id].CreationDate).Equals($creationDate, [StringComparison]::Ordinal)) {
            $Observations[$id] = $null
        }
    }
}

function Test-LeanLaunchDescendantProcess {
    <#
    Proves $CandidateId descends from $Root using only observations whose creation identity has
    never conflicted. Root must itself be present in $Observations with a matching CreationDate -
    if the root instance was never actually observed (or its slot was reused), attribution is refused.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Observations,
        [Parameter(Mandatory = $true)][int]$CandidateId,
        [Parameter(Mandatory = $true)]$Root
    )
    if ($null -eq $Root -or [string]::IsNullOrWhiteSpace([string]$Root.CreationDate)) { return $false }
    $rootId = [int]$Root.Id
    if ($CandidateId -eq $rootId) { return $false }
    if (-not $Observations.ContainsKey($rootId)) { return $false }
    $rootRecord = $Observations[$rootId]
    if ($null -eq $rootRecord -or -not ([string]$rootRecord.CreationDate).Equals([string]$Root.CreationDate, [StringComparison]::Ordinal)) { return $false }

    $seen = @{}
    $currentId = $CandidateId
    while ($Observations.ContainsKey($currentId) -and -not $seen.ContainsKey($currentId)) {
        $seen[$currentId] = $true
        $record = $Observations[$currentId]
        if ($null -eq $record) { return $false }
        if ($record.ParentId -eq $rootId) { return $true }
        if ($record.ParentId -le 0) { return $false }
        $currentId = [int]$record.ParentId
    }
    return $false
}

function Test-LeanLaunchSameProcessIdentity {
    param($Expected, $Actual)
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Expected.CreationDate) -or [string]::IsNullOrWhiteSpace([string]$Actual.CreationDate)) { return $false }
    return ([int]$Expected.Id -eq [int]$Actual.Id) -and
        ([string]$Expected.CreationDate).Equals([string]$Actual.CreationDate, [StringComparison]::Ordinal)
}

function Invoke-LeanLaunchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Profile,
        [hashtable]$Adapter,
        [switch]$DryRun,
        [switch]$KeepServices,
        [switch]$NoCleanup
    )
    if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
    $plan = New-LeanLaunchRunPlan -Profile $Profile -Adapter $Adapter
    if ($DryRun) {
        return [pscustomobject]@{ status='DryRun'; plan=$plan; startedServices=@(); stoppedServices=@(); stoppedProcesses=@(); cleanupErrors=@() }
    }
    if (@($plan.servicesToStart).Count -gt 0 -and $Adapter.ContainsKey('IsAdministrator') -and -not (& $Adapter.IsAdministrator)) {
        throw 'Service control requires administrator rights. Run PowerShell as Administrator, or remove services from the profile.'
    }

    $beforeProcesses = @(& $Adapter.GetProcesses)
    $beforeIds = @{}
    foreach ($process in $beforeProcesses) { $beforeIds[[int]$process.Id] = $true }
    $startedServices = New-Object System.Collections.ArrayList
    $ownedServiceInstances = New-Object System.Collections.ArrayList
    $stoppedServices = New-Object System.Collections.ArrayList
    $stoppedProcesses = New-Object System.Collections.ArrayList
    $cleanupErrors = New-Object System.Collections.ArrayList
    $launchedProcess = $null
    $status = 'Completed'
    $preserveResources = $false
    # Accumulates every process observed across the whole run so ancestry can still be proven once the
    # launched process (or an intermediate ancestor) has exited and its PID has potentially been reused.
    $observations = @{}
    $root = $null

    try {
        foreach ($service in @($plan.servicesToStart)) {
            $immediate = & $Adapter.GetService $service
            if ((Get-LeanLaunchServiceStatus $immediate) -eq 'Running') { continue }
            $startOwned = & $Adapter.StartService $service
            $started = & $Adapter.GetService $service
            $startedStatus = Get-LeanLaunchServiceStatus $started
            $startedProcessId = Get-LeanLaunchServiceProcessId $started
            if ($startedStatus -ne 'Running') {
                throw "Required service '$service' did not reach the Running state; aborting launch."
            }
            if ($startOwned -eq $true -and $startedProcessId -gt 0) {
                [void]$startedServices.Add($service)
                $ownedCreationTime = Get-LeanLaunchAdapterProcessCreationTime -Adapter $Adapter -ProcessId $startedProcessId
                [void]$ownedServiceInstances.Add([pscustomobject]@{ name=$service; processId=$startedProcessId; processCreationFileTimeUtc=$ownedCreationTime })
            }
        }
        $launchedProcess = & $Adapter.StartProcess $Profile.executable @($Profile.arguments) $Profile.workingDirectory
        if ($null -eq $launchedProcess) { throw 'The process adapter did not return a launched process.' }
        Update-LeanLaunchProcessObservations -Observations $observations -Processes @($launchedProcess)
        $launchedCreationDate = if (Test-LeanLaunchHasProperty $launchedProcess 'CreationDate') { [string]$launchedProcess.CreationDate } else { '' }
        $root = [pscustomobject]@{ Id = [int]$launchedProcess.Id; CreationDate = $launchedCreationDate }
        & $Adapter.WaitProcess $launchedProcess

        if (@($Profile.waitForProcessNames).Count -gt 0) {
            # One global deadline is shared by discovery and by every attributable descendant waited on below,
            # so N matching children cannot multiply the effective timeout to N times the bound.
            $globalDeadlineUtc = [DateTime]::UtcNow.AddSeconds(86400)
            $discoveryDeadlineUtc = [DateTime]::UtcNow.AddSeconds(30)
            if ($discoveryDeadlineUtc -gt $globalDeadlineUtc) { $discoveryDeadlineUtc = $globalDeadlineUtc }
            $matchNames = @($Profile.waitForProcessNames | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension([string]$_).ToLowerInvariant() })
            $discovered = @{}
            $quietPollsAfterDiscovery = 0
            do {
                $pollSnapshot = @(& $Adapter.GetProcesses)
                Update-LeanLaunchProcessObservations -Observations $observations -Processes $pollSnapshot
                $foundNew = $false
                foreach ($candidate in $pollSnapshot) {
                    $candidateId = [int]$candidate.Id
                    if ($discovered.ContainsKey($candidateId) -or $beforeIds.ContainsKey($candidateId)) { continue }
                    if ([string]::IsNullOrWhiteSpace([string]$candidate.CreationDate)) { continue }
                    $shortName = [IO.Path]::GetFileNameWithoutExtension([string]$candidate.Name).ToLowerInvariant()
                    if ($matchNames -notcontains $shortName) { continue }
                    if (Test-LeanLaunchDescendantProcess -Observations $observations -CandidateId $candidateId -Root $root) {
                        $discovered[$candidateId] = $candidate
                        $foundNew = $true
                    }
                }
                if ($discovered.Count -gt 0) {
                    if ($foundNew) { $quietPollsAfterDiscovery = 0 } else { $quietPollsAfterDiscovery++ }
                }
                $continueDiscovery = ([DateTime]::UtcNow -lt $discoveryDeadlineUtc) -and
                    (($discovered.Count -eq 0) -or ($quietPollsAfterDiscovery -lt 10))
                if ($continueDiscovery) {
                    if ($Adapter.ContainsKey('SleepMilliseconds')) { & $Adapter.SleepMilliseconds 500 }
                    else { Start-Sleep -Milliseconds 500 }
                }
            } while ($continueDiscovery)

            foreach ($waitProcess in $discovered.Values) {
                if ($Adapter.ContainsKey('WaitProcessBounded')) {
                    $remainingSeconds = [Math]::Max(0, [Math]::Ceiling(([TimeSpan]($globalDeadlineUtc - [DateTime]::UtcNow)).TotalSeconds))
                    $waitCompleted = & $Adapter.WaitProcessBounded $waitProcess $remainingSeconds
                    if ($waitCompleted -eq $false) {
                        $status = 'WaitTimedOut'
                        $preserveResources = $true
                    }
                }
            }
        }
    }
    catch {
        $status = 'Failed'
        throw
    }
    finally {
        if (-not $NoCleanup -and -not $preserveResources) {
            if ($Profile.cleanup.stopResidualProcesses -and $null -ne $root) {
                try {
                    $cleanupSnapshot = @(& $Adapter.GetProcesses)
                    Update-LeanLaunchProcessObservations -Observations $observations -Processes $cleanupSnapshot
                    foreach ($process in $cleanupSnapshot) {
                        if ($beforeIds.ContainsKey([int]$process.Id)) { continue }
                        foreach ($rule in @($Profile.residualProcesses)) {
                            if ((Test-LeanLaunchProcessRule $process $rule) -and
                                (-not [string]::IsNullOrWhiteSpace([string]$process.CreationDate)) -and
                                (Test-LeanLaunchDescendantProcess -Observations $observations -CandidateId ([int]$process.Id) -Root $root)) {
                                try {
                                    $revalidationSnapshot = @(& $Adapter.GetProcesses)
                                    Update-LeanLaunchProcessObservations -Observations $observations -Processes $revalidationSnapshot
                                    $current = @($revalidationSnapshot | Where-Object { [int]$_.Id -eq [int]$process.Id }) | Select-Object -First 1
                                    if ((Test-LeanLaunchSameProcessIdentity $process $current) -and
                                        (Test-LeanLaunchProcessRule $current $rule) -and
                                        (Test-LeanLaunchDescendantProcess -Observations $observations -CandidateId ([int]$current.Id) -Root $root)) {
                                        & $Adapter.StopProcess $current
                                        [void]$stoppedProcesses.Add([int]$current.Id)
                                    }
                                }
                                catch {
                                    [void]$cleanupErrors.Add([pscustomobject]@{ resourceType='Process'; resource=[string]$process.Id; message=$_.Exception.Message })
                                }
                                break
                            }
                        }
                    }
                }
                catch {
                    [void]$cleanupErrors.Add([pscustomobject]@{ resourceType='ProcessEnumeration'; resource='*'; message=$_.Exception.Message })
                }
            }
            if (-not $KeepServices -and $Profile.cleanup.stopStartedServices) {
                for ($i = $ownedServiceInstances.Count - 1; $i -ge 0; $i--) {
                    $owned = $ownedServiceInstances[$i]
                    $service = [string]$owned.name
                    try {
                        $currentService = & $Adapter.GetService $service
                        $currentStatus = Get-LeanLaunchServiceStatus $currentService
                        $currentProcessId = Get-LeanLaunchServiceProcessId $currentService
                        if ($currentStatus -eq 'Running' -and $currentProcessId -eq [int]$owned.processId) {
                            & $Adapter.StopService $service ([int]$owned.processId) ([long]$owned.processCreationFileTimeUtc)
                            [void]$stoppedServices.Add($service)
                        }
                    }
                    catch {
                        [void]$cleanupErrors.Add([pscustomobject]@{ resourceType='Service'; resource=$service; message=$_.Exception.Message })
                    }
                }
            }
            if ($cleanupErrors.Count -gt 0 -and $status -eq 'Completed') { $status = 'CleanupIncomplete' }
        }
    }

    [pscustomobject]@{
        status=$status; plan=$plan; processId=[int]$launchedProcess.Id
        startedServices=@($startedServices); stoppedServices=@($stoppedServices); stoppedProcesses=@($stoppedProcesses)
        cleanupErrors=@($cleanupErrors)
    }
}

function Find-LeanLaunchProfilePath {
    param([string]$Name, [string]$DataRoot, [string]$RepositoryRoot)
    if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Profile name is invalid.' }
    $userPath = Join-Path (Get-LeanLaunchPaths -DataRoot $DataRoot).Profiles ($Name + '.json')
    if (Test-Path -LiteralPath $userPath -PathType Leaf) { return $userPath }
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $repositoryPath = Join-Path (Join-Path $RepositoryRoot 'profiles') ($Name + '.json')
        if (Test-Path -LiteralPath $repositoryPath -PathType Leaf) { return $repositoryPath }
    }
    throw "Profile not found: $Name"
}

function Get-LeanLaunchApplicationBoundProfilePath {
    <#
    The exact expected identity of a profile generated by New-LeanLaunchApplicationProfile: always
    the per-user profile directory, by construction, never a repository-shipped template. Unlike
    Find-LeanLaunchProfilePath, this never falls back to a same-named repository profile - a Managed
    application's bound profile that is not exactly here is stale or missing, not "found elsewhere".
    #>
    param([Parameter(Mandatory = $true)][string]$ProfileName, [string]$DataRoot)
    if (-not (Test-LeanLaunchProfileName $ProfileName)) { throw 'Profile name is invalid.' }
    return Join-Path (Get-LeanLaunchPaths -DataRoot $DataRoot).Profiles ($ProfileName + '.json')
}

function Get-LeanLaunchDoctorReport {
    [CmdletBinding()]
    param([string]$DataRoot)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    [pscustomobject]@{
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        isWindows = ($env:OS -eq 'Windows_NT')
        isAdministrator = $isAdmin
        dataRoot = $paths.DataRoot
        profileDirectory = $paths.Profiles
        snapshotDirectory = $paths.Snapshots
        residentBackgroundComponents = 0
        serviceControlAvailable = $isAdmin
    }
}

function New-LeanLaunchCommandResult {
    param([int]$ExitCode, [string]$Message, $Data)
    [pscustomobject]@{ exitCode=$ExitCode; message=$Message; data=$Data }
}

function Get-LeanLaunchHelpText {
@'
LeanLaunch - heavyweight apps, only when you need them

Usage:
  leanlaunch doctor
  leanlaunch snapshot <name>
  leanlaunch diff <before> <after>
  leanlaunch list
  leanlaunch show <profile>
  leanlaunch profile init <name> --exe <path>
  leanlaunch run <profile> [--dry-run] [--keep-services] [--no-cleanup]
  leanlaunch gui

Application audit workflow (recommended for every new install):
  leanlaunch app new <name> --exe <path> [--display-name <text>]
  leanlaunch app scan-before <name>
  # install the application, let it settle
  leanlaunch app scan-after <name>
  leanlaunch app show <name>
  leanlaunch app classify <name> <key> <Managed|Unmanaged|Reviewed> [--note <text>]
  leanlaunch app park <name> <key> <On|Off>
  leanlaunch app profile <name> [--force]
  leanlaunch app policy <name> <Managed|Unmanaged>
  leanlaunch app run <name> [--dry-run] [--keep-services] [--no-cleanup]
  leanlaunch app list

Low-level (single before/after snapshot pair without an application record):
  leanlaunch snapshot before-solidworks
  # install one application, then launch it once
  leanlaunch snapshot after-solidworks
  leanlaunch diff before-solidworks after-solidworks
'@
}

function Invoke-LeanLaunchCommand {
    [CmdletBinding()]
    param(
        [string[]]$CommandArguments,
        [string]$DataRoot,
        [string]$RepositoryRoot,
        [hashtable]$Collectors,
        [hashtable]$Adapter
    )
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
    if ($null -eq $CommandArguments -or $CommandArguments.Count -eq 0) { $CommandArguments = @('help') }
    $command = ([string]$CommandArguments[0]).ToLowerInvariant()

    try {
        switch ($command) {
            { $_ -in @('help','--help','-h') } {
                if ($CommandArguments.Count -ne 1) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch help' $null }
                return New-LeanLaunchCommandResult 0 (Get-LeanLaunchHelpText) $null
            }
            'doctor' {
                if ($CommandArguments.Count -ne 1) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch doctor' $null }
                $report = Get-LeanLaunchDoctorReport -DataRoot $DataRoot
                return New-LeanLaunchCommandResult 0 'LeanLaunch doctor completed.' $report
            }
            'snapshot' {
                if ($CommandArguments.Count -ne 2) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch snapshot <name>' $null }
                $snapshot = New-LeanLaunchSnapshot -Collectors $Collectors
                $file = Save-LeanLaunchSnapshot -Snapshot $snapshot -Name $CommandArguments[1] -DataRoot $DataRoot
                if (@($snapshot.collectionErrors).Count -gt 0) {
                    $failedCollectors = (($snapshot.collectionErrors | ForEach-Object { [string]$_.collector }) -join ', ')
                    return New-LeanLaunchCommandResult 5 ("Snapshot saved with partial evidence (collector errors: $failedCollectors): " + $file.FullName) $snapshot
                }
                return New-LeanLaunchCommandResult 0 ("Snapshot saved: " + $file.FullName) $snapshot
            }
            'diff' {
                if ($CommandArguments.Count -ne 3) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch diff <before> <after>' $null }
                $before = Import-LeanLaunchSnapshot -Name $CommandArguments[1] -DataRoot $DataRoot
                $after = Import-LeanLaunchSnapshot -Name $CommandArguments[2] -DataRoot $DataRoot
                $diff = Compare-LeanLaunchSnapshot -Before $before -After $after
                $startupCount = @($diff.addedStartupEntries).Count + @($diff.removedStartupEntries).Count
                $taskCount = @($diff.addedScheduledTasks).Count + @($diff.removedScheduledTasks).Count
                $message = "Changes: {0} process groups, {1} services, {2} startup entries, {3} scheduled tasks." -f @($diff.processChanges).Count,@($diff.serviceChanges).Count,$startupCount,$taskCount
                if (@($diff.collectionErrors).Count -gt 0) {
                    $message += ' Warning: a source snapshot had collector errors; evidence may be incomplete.'
                    return New-LeanLaunchCommandResult 5 $message $diff
                }
                return New-LeanLaunchCommandResult 0 $message $diff
            }
            'list' {
                if ($CommandArguments.Count -ne 1) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch list' $null }
                $profiles = Get-LeanLaunchProfiles -DataRoot $DataRoot -RepositoryProfiles (Join-Path $RepositoryRoot 'profiles')
                return New-LeanLaunchCommandResult 0 ("Profiles: " + @($profiles).Count) $profiles
            }
            'show' {
                if ($CommandArguments.Count -ne 2) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch show <profile>' $null }
                $path = Find-LeanLaunchProfilePath $CommandArguments[1] $DataRoot $RepositoryRoot
                $profile = Import-LeanLaunchProfile -Path $path -SkipExecutableCheck
                return New-LeanLaunchCommandResult 0 ("Profile: " + $profile.name) $profile
            }
            'profile' {
                if ($CommandArguments.Count -ne 5 -or $CommandArguments[1] -ne 'init' -or $CommandArguments[3] -ne '--exe') { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch profile init <name> --exe <path>' $null }
                $file = New-LeanLaunchProfile -Name $CommandArguments[2] -Executable $CommandArguments[4] -DataRoot $DataRoot
                return New-LeanLaunchCommandResult 0 ("Profile created: " + $file.FullName) $file
            }
            'run' {
                if ($CommandArguments.Count -lt 2) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch run <profile> [--dry-run] [--keep-services] [--no-cleanup]' $null }
                $options = @($CommandArguments | Select-Object -Skip 2)
                $allowedOptions = @('--dry-run','--keep-services','--no-cleanup')
                if (@($options | Where-Object { $allowedOptions -notcontains $_ }).Count -gt 0 -or @($options | Select-Object -Unique).Count -ne $options.Count) {
                    return New-LeanLaunchCommandResult 2 'Usage: leanlaunch run <profile> [--dry-run] [--keep-services] [--no-cleanup]' $null
                }
                $path = Find-LeanLaunchProfilePath $CommandArguments[1] $DataRoot $RepositoryRoot
                $profile = Import-LeanLaunchProfile -Path $path
                $run = Invoke-LeanLaunchRun -Profile $profile -Adapter $Adapter -DryRun:($CommandArguments -contains '--dry-run') -KeepServices:($CommandArguments -contains '--keep-services') -NoCleanup:($CommandArguments -contains '--no-cleanup')
                $runExitCode = switch ($run.status) {
                    'CleanupIncomplete' { 3 }
                    'WaitTimedOut' { 4 }
                    default { 0 }
                }
                return New-LeanLaunchCommandResult $runExitCode ("Run status: " + $run.status) $run
            }
            'gui' {
                if ($CommandArguments.Count -ne 1) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch gui' $null }
                return New-LeanLaunchCommandResult 0 'Launching the LeanLaunch GUI.' ([pscustomobject]@{ action = 'LaunchGui' })
            }
            'app' {
                if ($CommandArguments.Count -lt 2) { return New-LeanLaunchCommandResult 2 (Get-LeanLaunchHelpText) $null }
                $sub = ([string]$CommandArguments[1]).ToLowerInvariant()
                switch ($sub) {
                    'new' {
                        $usage = 'Usage: leanlaunch app new <name> --exe <path> [--display-name <text>]'
                        if ($CommandArguments.Count -ne 5 -and $CommandArguments.Count -ne 7) { return New-LeanLaunchCommandResult 2 $usage $null }
                        if ($CommandArguments[3] -ne '--exe') { return New-LeanLaunchCommandResult 2 $usage $null }
                        $displayName = $null
                        if ($CommandArguments.Count -eq 7) {
                            if ($CommandArguments[5] -ne '--display-name') { return New-LeanLaunchCommandResult 2 $usage $null }
                            $displayName = $CommandArguments[6]
                        }
                        $application = New-LeanLaunchApplication -Name $CommandArguments[2] -Executable $CommandArguments[4] -DisplayName $displayName -DataRoot $DataRoot
                        return New-LeanLaunchCommandResult 0 ("Application created: " + $CommandArguments[2]) $application
                    }
                    'list' {
                        if ($CommandArguments.Count -ne 2) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch app list' $null }
                        $applications = @(Get-LeanLaunchApplications -DataRoot $DataRoot)
                        $rows = Get-LeanLaunchApplicationSummaryRows -Applications $applications
                        return New-LeanLaunchCommandResult 0 ("Applications: " + @($rows).Count) $rows
                    }
                    'show' {
                        if ($CommandArguments.Count -ne 3) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch app show <name>' $null }
                        $application = Import-LeanLaunchApplication -Name $CommandArguments[2] -DataRoot $DataRoot
                        return New-LeanLaunchCommandResult 0 ("Application: " + $application.name) $application
                    }
                    'scan-before' {
                        if ($CommandArguments.Count -ne 3) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch app scan-before <name>' $null }
                        $result = New-LeanLaunchApplicationBeforeSnapshot -Name $CommandArguments[2] -DataRoot $DataRoot -Collectors $Collectors -Adapter $Adapter
                        return New-LeanLaunchCommandResult 0 ("Before-install baseline captured: " + $result.snapshotName) $result
                    }
                    'scan-after' {
                        if ($CommandArguments.Count -ne 3) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch app scan-after <name>' $null }
                        $result = Complete-LeanLaunchApplicationAudit -Name $CommandArguments[2] -DataRoot $DataRoot -Collectors $Collectors
                        $candidateCount = @($result.application.currentAudit.classifications).Count
                        return New-LeanLaunchCommandResult 0 ("After-install diff captured: $candidateCount candidate resource(s) to review.") $result
                    }
                    'classify' {
                        $usage = 'Usage: leanlaunch app classify <name> <key> <decision> [--note <text>]'
                        if ($CommandArguments.Count -ne 5 -and $CommandArguments.Count -ne 7) { return New-LeanLaunchCommandResult 2 $usage $null }
                        $note = ''
                        if ($CommandArguments.Count -eq 7) {
                            if ($CommandArguments[5] -ne '--note') { return New-LeanLaunchCommandResult 2 $usage $null }
                            $note = $CommandArguments[6]
                        }
                        $application = Set-LeanLaunchResourceClassification -Name $CommandArguments[2] -Key $CommandArguments[3] -Decision $CommandArguments[4] -Note $note -DataRoot $DataRoot -Adapter $Adapter
                        return New-LeanLaunchCommandResult 0 'Classification updated.' $application
                    }
                    'park' {
                        $usage = 'Usage: leanlaunch app park <name> <key> <On|Off>'
                        if ($CommandArguments.Count -ne 5) { return New-LeanLaunchCommandResult 2 $usage $null }
                        $parkWhenIdle = switch ([string]$CommandArguments[4]) { 'On' { $true } 'Off' { $false } default { $null } }
                        if ($null -eq $parkWhenIdle) { return New-LeanLaunchCommandResult 2 $usage $null }
                        $application = Set-LeanLaunchServiceParkingPreference -Name $CommandArguments[2] -Key $CommandArguments[3] -ParkWhenIdle $parkWhenIdle -DataRoot $DataRoot -Adapter $Adapter
                        return New-LeanLaunchCommandResult 0 ("Idle parking set to " + $CommandArguments[4] + " for " + $CommandArguments[2] + "/" + $CommandArguments[3]) $application
                    }
                    'policy' {
                        if ($CommandArguments.Count -ne 4) { return New-LeanLaunchCommandResult 2 'Usage: leanlaunch app policy <name> <Managed|Unmanaged>' $null }
                        $application = Set-LeanLaunchApplicationPolicy -Name $CommandArguments[2] -Policy $CommandArguments[3] -DataRoot $DataRoot -Adapter $Adapter
                        return New-LeanLaunchCommandResult 0 ("Policy set to " + $CommandArguments[3] + " for " + $CommandArguments[2]) $application
                    }
                    'profile' {
                        $usage = 'Usage: leanlaunch app profile <name> [--force]'
                        if ($CommandArguments.Count -ne 3 -and $CommandArguments.Count -ne 4) { return New-LeanLaunchCommandResult 2 $usage $null }
                        if ($CommandArguments.Count -eq 4 -and $CommandArguments[3] -ne '--force') { return New-LeanLaunchCommandResult 2 $usage $null }
                        $result = New-LeanLaunchApplicationProfile -Name $CommandArguments[2] -DataRoot $DataRoot -Force:($CommandArguments.Count -eq 4)
                        return New-LeanLaunchCommandResult 0 ("Profile written: " + $result.path.FullName) $result
                    }
                    'run' {
                        $usage = 'Usage: leanlaunch app run <name> [--dry-run] [--keep-services] [--no-cleanup]'
                        if ($CommandArguments.Count -lt 3) { return New-LeanLaunchCommandResult 2 $usage $null }
                        $options = @($CommandArguments | Select-Object -Skip 3)
                        $allowedOptions = @('--dry-run','--keep-services','--no-cleanup')
                        if (@($options | Where-Object { $allowedOptions -notcontains $_ }).Count -gt 0 -or @($options | Select-Object -Unique).Count -ne $options.Count) {
                            return New-LeanLaunchCommandResult 2 $usage $null
                        }
                        $run = Invoke-LeanLaunchApplicationRun -Name $CommandArguments[2] -DataRoot $DataRoot -RepositoryRoot $RepositoryRoot -Adapter $Adapter `
                            -DryRun:($CommandArguments -contains '--dry-run') -KeepServices:($CommandArguments -contains '--keep-services') -NoCleanup:($CommandArguments -contains '--no-cleanup')
                        $runExitCode = switch ($run.status) {
                            'CleanupIncomplete' { 3 }
                            'WaitTimedOut' { 4 }
                            default { 0 }
                        }
                        return New-LeanLaunchCommandResult $runExitCode ("Run status: " + $run.status) $run
                    }
                    default {
                        return New-LeanLaunchCommandResult 2 ("Unknown app subcommand: " + $sub + "`n`n" + (Get-LeanLaunchHelpText)) $null
                    }
                }
            }
            default {
                return New-LeanLaunchCommandResult 2 ("Unknown command: " + $CommandArguments[0] + "`n`n" + (Get-LeanLaunchHelpText)) $null
            }
        }
    }
    catch {
        return New-LeanLaunchCommandResult 1 ("Error: " + $_.Exception.Message) $null
    }
}

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
