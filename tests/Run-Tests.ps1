$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$result = Invoke-Pester -Path $PSScriptRoot -PassThru
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
