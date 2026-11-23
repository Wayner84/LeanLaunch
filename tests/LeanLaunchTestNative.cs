using System;
using System.Runtime.InteropServices;

namespace LeanLaunchTestNative {
    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
            uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    }
}
