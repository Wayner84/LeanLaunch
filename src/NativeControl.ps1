Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Native handle-bound control closes the PID/service-name replacement races that cannot be closed by
# a CIM re-read followed by Stop-Process/Stop-Service. The same kernel/service handle is used to
# query identity and perform the terminating action; a mismatched or unavailable identity fails closed.
if (-not ('LeanLaunch.NativeControl' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeControl.cs') | Out-Null
}
