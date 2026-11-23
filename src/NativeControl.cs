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
