$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $ProjectRoot 'LeanLaunch.psd1'
$FixtureRoot = Join-Path $env:TEMP ('LeanLaunchTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
# CI may expose %TEMP% through an 8.3 alias (RUNNER~1), while the filesystem
# returns long paths for saved files. Use the provider's path consistently for
# both fixture assertions and installation markers; do not loosen ownership checks.
$FixtureRoot = (Get-Item -LiteralPath $FixtureRoot).FullName
$env:LOCALAPPDATA = Join-Path $FixtureRoot 'LocalAppData'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
# Installer PATH tests exercise the exact ownership logic against process-local state. Production
# scripts still default to User; this explicit test-only target prevents an interrupted suite from
# ever leaving the developer's real registry-backed PATH changed. Run-Tests.ps1 executes in a child
# PowerShell process, so these process-scoped values disappear automatically when the suite exits;
# no top-level AfterAll is used because Pester 3.4 only permits it inside a Describe block.
$env:LEANLAUNCH_TEST_ENVIRONMENT_TARGET = 'Process'
$env:LEANLAUNCH_ENABLE_TEST_HOOKS = '1'
Import-Module $ModulePath -Force
