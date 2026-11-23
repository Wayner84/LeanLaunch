using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
namespace LeanLaunch {
    public static class GuiBoundedCleanup {
        public static bool Run(PowerShell pipeline, Runspace runspace, int timeoutMilliseconds) {
            Thread worker = new Thread(() => {
                try { pipeline.Stop(); } catch { }
                try { pipeline.Dispose(); } catch { }
                try { runspace.Close(); } catch { }
                try { runspace.Dispose(); } catch { }
            });
            worker.IsBackground = true;
            worker.Name = "LeanLaunch bounded GUI scan cleanup";
            worker.Start();
            return worker.Join(Math.Max(0, timeoutMilliseconds));
        }
    }
}
