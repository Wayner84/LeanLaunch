. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

if (-not ('LeanLaunchTestNative.NativeMethods' -as [type])) {
    Add-Type -Namespace LeanLaunchTestNative -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
    uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
'@
}

function Lock-LeanLaunchDirectoryHandle {
    <#
    Opens a native handle to an EXISTING, empty directory with no FILE_SHARE_DELETE, so any later
    attempt in this same process to Remove-Item that exact directory fails with a genuine, deterministic
    "in use" IOException - entirely in-process (no real service/process/UAC involved) - letting a test
    prove a directory-removal failure path without depending on timing or external state. Caller must
    close the returned handle (Close-LeanLaunchDirectoryHandle) once the test assertion is complete.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $GENERIC_READ = [Convert]::ToUInt32('80000000', 16)
    $FILE_SHARE_READ = [uint32]0x1
    $OPEN_EXISTING = [uint32]3
    $FILE_FLAG_BACKUP_SEMANTICS = [uint32]0x02000000
    $handle = [LeanLaunchTestNative.NativeMethods]::CreateFile($Path, $GENERIC_READ, $FILE_SHARE_READ, [IntPtr]::Zero, $OPEN_EXISTING, $FILE_FLAG_BACKUP_SEMANTICS, [IntPtr]::Zero)
    if ($handle.IsInvalid) { throw "Failed to open a locking handle on '$Path'." }
    return $handle
}

Describe 'LeanLaunch installer safety' {
    It 'honours WhatIf without creating an installation' {
        $root = Join-Path $FixtureRoot 'whatif-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -WhatIf | Out-Null
        Test-Path -LiteralPath $root | Should Be $false
    }

    It 'rejects an install root containing a PATH delimiter' {
        $root = (Join-Path $FixtureRoot 'unsafe') + ';other'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
    }

    It 'refuses to install over an existing unmarked directory' {
        $root = Join-Path $FixtureRoot 'existing'
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'creates a marker and includes an installed uninstaller without persisting coordination sidecars' {
        $root = Join-Path $FixtureRoot 'marked-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        Test-Path -LiteralPath (Join-Path $root '.leanlaunch-install.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $root 'uninstall.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $root '.leanlaunch-install.json.lock') | Should Be $false
        Test-Path -LiteralPath (Join-Path (Join-Path $env:LOCALAPPDATA 'LeanLaunch') 'install-record.json.lock') | Should Be $false
    }

    It 'refuses to delete an unmarked directory' {
        $root = Join-Path $FixtureRoot 'unmarked-uninstall'
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'installed uninstaller defaults to its own marked custom root' {
        $root = Join-Path $FixtureRoot 'custom-self-uninstall'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        & (Join-Path $root 'uninstall.ps1') -SkipPathUpdate -Confirm:$false | Out-Null
        Test-Path -LiteralPath $root | Should Be $false
    }

    It 'honours uninstall WhatIf and then removes only a marked installation' {
        $root = Join-Path $FixtureRoot 'uninstall-target'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -WhatIf | Out-Null
        Test-Path -LiteralPath $root | Should Be $true
        & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false | Out-Null
        Test-Path -LiteralPath $root | Should Be $false
    }

    It 'detects quarantine substitution when installation is already absent and -RemoveData uses the early data-only path' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'early-data-substitution-appdata'
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        $profilePath = Join-Path $dataRoot 'profiles\sentinel.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        Set-Content -LiteralPath $profilePath -Value '{"original":true}' -Encoding UTF8 -NoNewline
        $absentInstallRoot = Join-Path $FixtureRoot 'early-data-substitution-absent-install'
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        $replacement = '{"substituted":true}'
        $hook = {
            $quarantine = @(Get-ChildItem -LiteralPath $fakeLocalAppData -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force | Select-Object -First 1)
            Set-Content -LiteralPath (Join-Path $quarantine.FullName 'profiles\sentinel.json') -Value $replacement -Encoding UTF8 -NoNewline
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $absentInstallRoot -SkipPathUpdate -RemoveData -Confirm:$false -PreFinalizationHook $hook } | Should Throw
            Test-Path -LiteralPath $dataRoot | Should Be $false
            $preserved = @(Get-ChildItem -LiteralPath $fakeLocalAppData -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force | Select-Object -First 1)
            $preserved.Count | Should Be 1
            (Get-Content -LiteralPath (Join-Path $preserved[0].FullName 'profiles\sentinel.json') -Raw) | Should Be $replacement
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
            Remove-Item -LiteralPath $fakeLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'records an installed-file manifest and removes exactly those files' {
        $root = Join-Path $FixtureRoot 'manifest-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $marker = Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw | ConvertFrom-Json
        [int]$marker.schemaVersion | Should Be 2
        @($marker.files) -contains 'src\LeanLaunch.psm1' | Should Be $true
        @($marker.files) -contains 'src\LeanLaunch.Gui.ps1' | Should Be $true
        @($marker.files) -contains 'bin\leanlaunch.cmd' | Should Be $true
    }

    It 'refuses a forged manifest path that escapes the install root' {
        $root = Join-Path $FixtureRoot 'forged-manifest-install'
        $outside = Join-Path $FixtureRoot 'must-survive.txt'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath $outside -Value 'keep'
        $record = [ordered]@{
            schemaVersion = 2
            product = 'LeanLaunch'
            installRoot = $root
            files = @('..\must-survive.txt')
            directories = @()
            pathEntryAdded = $false
            pathEntryValue = $null
        }
        $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8

        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false } | Should Throw
        Test-Path -LiteralPath $outside | Should Be $true
    }

    It 'refuses to install over a marker with an unrecognized numeric schemaVersion (999)' {
        $root = Join-Path $FixtureRoot 'marker-schema-999-install'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [ordered]@{ schemaVersion = 999; product = 'LeanLaunch'; installRoot = $root; files = @(); directories = @(); pathEntryAdded = $false; pathEntryValue = $null } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to install over a marker with a string-coerced schemaVersion ("2") instead of accepting it as integer 2' {
        $root = Join-Path $FixtureRoot 'marker-schema-string-install'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        # Hand-crafted JSON with schemaVersion as a JSON STRING, not a JSON number - ConvertFrom-Json
        # keeps these distinguishable, and install.ps1 must not silently coerce the string to an int
        # and accept it as if it were the real integer 2.
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":`"2`",`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":[],`"directories`":[],`"pathEntryAdded`":false,`"pathEntryValue`":null}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to uninstall when the marker has an unrecognized numeric schemaVersion (999)' {
        $root = Join-Path $FixtureRoot 'marker-schema-999-uninstall'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [ordered]@{ schemaVersion = 999; product = 'LeanLaunch'; installRoot = $root; files = @(); directories = @(); pathEntryAdded = $false; pathEntryValue = $null } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to uninstall when the marker has a string-coerced schemaVersion ("2")' {
        $root = Join-Path $FixtureRoot 'marker-schema-string-uninstall'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":`"2`",`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":[],`"directories`":[],`"pathEntryAdded`":false,`"pathEntryValue`":null}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to install over a marker with a scalar files field instead of an array' {
        $root = Join-Path $FixtureRoot 'marker-scalar-files-install'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":2,`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":`"not-an-array`",`"directories`":[],`"pathEntryAdded`":false,`"pathEntryValue`":null}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to install over a marker with a string-coerced pathEntryAdded boolean instead of a real boolean' {
        $root = Join-Path $FixtureRoot 'marker-string-bool-install'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":2,`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":[`"a`",`"b`"],`"directories`":[],`"pathEntryAdded`":`"true`",`"pathEntryValue`":null}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to install over a marker with a malformed (non-string) product field' {
        $root = Join-Path $FixtureRoot 'marker-malformed-product-install'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":2,`"product`":123,`"installRoot`":$installRootJson,`"files`":[`"a`",`"b`"],`"directories`":[],`"pathEntryAdded`":false,`"pathEntryValue`":null}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to uninstall a marker with a scalar files field instead of an array' {
        $root = Join-Path $FixtureRoot 'marker-scalar-files-uninstall'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":2,`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":`"not-an-array`",`"directories`":[],`"pathEntryAdded`":false,`"pathEntryValue`":null}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to uninstall a marker with a string-coerced pathEntryAdded boolean instead of a real boolean' {
        $root = Join-Path $FixtureRoot 'marker-string-bool-uninstall'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":2,`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":[`"a`",`"b`"],`"directories`":[],`"pathEntryAdded`":`"true`",`"pathEntryValue`":null}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to install over a marker missing the pathEntryValue property entirely even though pathEntryAdded is false' {
        $root = Join-Path $FixtureRoot 'marker-missing-pathentryvalue-install'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":2,`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":[`"a`",`"b`"],`"directories`":[],`"pathEntryAdded`":false}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'refuses to uninstall a marker missing the pathEntryValue property entirely even though pathEntryAdded is false' {
        $root = Join-Path $FixtureRoot 'marker-missing-pathentryvalue-uninstall'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $installRootJson = $root | ConvertTo-Json
        "{`"schemaVersion`":2,`"product`":`"LeanLaunch`",`"installRoot`":$installRootJson,`"files`":[`"a`",`"b`"],`"directories`":[],`"pathEntryAdded`":false}" |
            Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'keep.txt') -Value 'keep'
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'keep.txt') | Should Be $true
    }

    It 'accepts a schema-1 marker without manifest fields as a valid existing install to upgrade (schema-1 compatibility preserved)' {
        $root = Join-Path $FixtureRoot 'schema1-compat-root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [ordered]@{ schemaVersion = 1; product = 'LeanLaunch'; installRoot = $root } |
            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'legacy-file.txt') -Value 'legacy'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $marker = Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw | ConvertFrom-Json
        [int]$marker.schemaVersion | Should Be 2
        Test-Path -LiteralPath (Join-Path $root 'legacy-file.txt') | Should Be $true
        Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $true
    }

    It 'fails closed on an invalid (malformed) data-root install record instead of silently reporting no installation' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'invalid-datarecord-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dataRoot 'install-record.json') -Value 'not valid json at all {{{' -Encoding UTF8
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'invalid-datarecord-root'
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false } | Should Throw
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'does not treat a data-root record naming a different install root as an error (legitimate shared data root)' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'different-root-datarecord-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $otherRoot = Join-Path $FixtureRoot 'different-root-datarecord-otherinstall'
        [ordered]@{ schemaVersion = 2; product = 'LeanLaunch'; installRoot = $otherRoot; files = @('a'); directories = @(); pathEntryAdded = $false; pathEntryValue = $null } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dataRoot 'install-record.json') -Encoding UTF8
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'different-root-datarecord-thisroot'
            $result = & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false
            $result | Should Match 'already absent'
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'aborts and rolls back when a newer marker is written during the file-quarantine loop, preserving the newer marker and restoring every previously moved file' {
        $root = Join-Path $FixtureRoot 'uninstall-newer-marker-during-loop-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $installedMarkerPath = Join-Path $root '.leanlaunch-install.json'
        $script:newerMarkerDuringLoopWritten = $false
        $hook = {
            param($relative)
            if (-not $script:newerMarkerDuringLoopWritten) {
                $script:newerMarkerDuringLoopWritten = $true
                [ordered]@{
                    schemaVersion = 2; product = 'LeanLaunch'; installRoot = $root
                    files = @('leanlaunch.ps1'); directories = @('bin','src','profiles')
                    pathEntryAdded = $false; pathEntryValue = $null
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $installedMarkerPath -Encoding UTF8
            }
        }.GetNewClosure()
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -PreDeleteHook $hook } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $root 'bin\leanlaunch.cmd') | Should Be $true
        Test-Path -LiteralPath $installedMarkerPath | Should Be $true
        (Get-Content -LiteralPath $installedMarkerPath -Raw) | Should Match 'leanlaunch\.ps1'
    }

    It 'aborts and rolls back when a manifest file is concurrently replaced, preserving that newer file and restoring every unaffected file already moved' {
        $root = Join-Path $FixtureRoot 'uninstall-concurrent-file-survives-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $psm1Path = Join-Path $root 'src\LeanLaunch.psm1'
        $cmdPath = Join-Path $root 'bin\leanlaunch.cmd'
        $hook = {
            param($relative)
            if ($relative -eq 'src\LeanLaunch.psm1') {
                Set-Content -LiteralPath $psm1Path -Value 'CONCURRENTLY-REPLACED-DURING-UNINSTALL' -Encoding UTF8 -NoNewline
            }
        }.GetNewClosure()

        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -PreDeleteHook $hook } | Should Throw
        Test-Path -LiteralPath $psm1Path | Should Be $true
        (Get-Content -LiteralPath $psm1Path -Raw) | Should Be 'CONCURRENTLY-REPLACED-DURING-UNINSTALL'
        Test-Path -LiteralPath $cmdPath | Should Be $true
        Test-Path -LiteralPath (Join-Path $root '.leanlaunch-install.json') | Should Be $true
    }

    It 'actually removes a clean data root via -RemoveData (quarantine-then-finalize happy path)' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'removedata-happy-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'removedata-happy-installroot'
            & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
            $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
            Test-Path -LiteralPath $dataRoot | Should Be $true
            $sentinelProfile = Join-Path $dataRoot 'profiles\keep.json'
            Set-Content -LiteralPath $sentinelProfile -Value '{}' -Encoding UTF8

            & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -RemoveData -Confirm:$false | Out-Null

            Test-Path -LiteralPath $dataRoot | Should Be $false
            @(Get-ChildItem -LiteralPath $fakeLocalAppData -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'rejects -RemoveData when a nested (non-root) reparse point exists anywhere beneath the data root, before any destructive traversal, and preserves the reparse target and the rest of the tree' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'nested-reparse-removedata-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'nested-reparse-removedata-installroot'
            & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
            $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
            $sentinelInOtherTree = Join-Path $dataRoot 'snapshots\real-snapshot.json'
            Set-Content -LiteralPath $sentinelInOtherTree -Value '{}' -Encoding UTF8

            # Replace a NESTED subdirectory (not the data root itself) with a junction to an unrelated
            # target that holds its own sentinel file - proving both that the nested reparse point is
            # detected without following it, and that its target is never touched.
            $profilesDir = Join-Path $dataRoot 'profiles'
            Remove-Item -LiteralPath $profilesDir -Recurse -Force
            $decoyTarget = Join-Path $FixtureRoot 'nested-reparse-removedata-decoy'
            New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
            $decoySentinel = Join-Path $decoyTarget 'do-not-touch.txt'
            Set-Content -LiteralPath $decoySentinel -Value 'must survive' -Encoding UTF8
            New-Item -ItemType Junction -Path $profilesDir -Target $decoyTarget | Out-Null

            try {
                { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -RemoveData -Confirm:$false } | Should Throw

                # Nothing was touched: the reparse target survives untouched, the rest of the data root
                # (including a real, non-reparse subtree) survives untouched, and the data root itself
                # was never partially traversed/deleted.
                Test-Path -LiteralPath $decoySentinel | Should Be $true
                (Get-Content -LiteralPath $decoySentinel -Raw) | Should Match 'must survive'
                Test-Path -LiteralPath $sentinelInOtherTree | Should Be $true
                Test-Path -LiteralPath $dataRoot | Should Be $true
                @(Get-ChildItem -LiteralPath $fakeLocalAppData -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
            }
            finally {
                if (Test-Path -LiteralPath $profilesDir) {
                    $item = Get-Item -LiteralPath $profilesDir -Force
                    if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
                }
            }
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'detects ordinary quarantine payload substitution and preserves it for manual recovery instead of deleting or restoring forged bytes' {
        $root = Join-Path $FixtureRoot 'quarantine-payload-substitution-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $parent = Split-Path -Parent $root
        $replacement = 'SUBSTITUTED-IN-QUARANTINE'
        $hook = {
            $quarantine = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'src\LeanLaunch.psm1') } | Select-Object -First 1)
            Set-Content -LiteralPath (Join-Path $quarantine.FullName 'src\LeanLaunch.psm1') -Value $replacement -Encoding UTF8 -NoNewline
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -PreFinalizationHook $hook } | Should Throw
            Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $false
            $preserved = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'src\LeanLaunch.psm1') } | Select-Object -First 1)
            $preserved.Count | Should Be 1
            (Get-Content -LiteralPath (Join-Path $preserved[0].FullName 'src\LeanLaunch.psm1') -Raw) | Should Be $replacement
            Test-Path -LiteralPath (Join-Path $root '.leanlaunch-install.json') | Should Be $true
        }
        finally {
            foreach ($quarantine in @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $quarantine.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'detects a nested reparse point introduced into quarantine after initial validation and before final recursive deletion' {
        $root = Join-Path $FixtureRoot 'late-quarantine-reparse-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $parent = Split-Path -Parent $root
        $decoy = Join-Path $FixtureRoot 'late-quarantine-reparse-decoy'
        New-Item -ItemType Directory -Path $decoy -Force | Out-Null
        $sentinel = Join-Path $decoy 'must-survive.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        $hook = {
            $quarantine = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force)[0].FullName
            New-Item -ItemType Junction -Path (Join-Path $quarantine 'late-linked-tree') -Target $decoy | Out-Null
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -PreFinalizationHook $hook } | Should Throw
            Test-Path -LiteralPath $sentinel | Should Be $true
            Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $true
            Test-Path -LiteralPath (Join-Path $root '.leanlaunch-install.json') | Should Be $true
        }
        finally {
            foreach ($quarantine in @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue)) {
                $link = Join-Path $quarantine.FullName 'late-linked-tree'
                if (Test-Path -LiteralPath $link) { (Get-Item -LiteralPath $link -Force).Delete() }
                Remove-Item -LiteralPath $quarantine.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'refuses to delete based on stale validation when the marker changes concurrently before deletion begins' {
        $root = Join-Path $FixtureRoot 'uninstall-newer-marker-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $installedMarkerPath = Join-Path $root '.leanlaunch-install.json'
        $hook = {
            # Simulate a concurrent, legitimate re-install/upgrade writing a newer, still-validly-shaped
            # marker after this uninstall already read and validated the original one.
            [ordered]@{
                schemaVersion = 2; product = 'LeanLaunch'; installRoot = $root
                files = @('leanlaunch.ps1'); directories = @('bin','src','profiles')
                pathEntryAdded = $false; pathEntryValue = $null
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $installedMarkerPath -Encoding UTF8
        }.GetNewClosure()
        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -PreDeletionPhaseHook $hook } | Should Throw
        # Nothing should have been deleted - the original install's files must all survive.
        Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $true
        Test-Path -LiteralPath $installedMarkerPath | Should Be $true
    }

    It 'preserves install-record.json when it changes concurrently between the start of uninstall and its final removal' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'uninstall-concurrent-record-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'uninstall-concurrent-record-root'
            & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
            $dataRecordPath = Join-Path (Join-Path $fakeLocalAppData 'LeanLaunch') 'install-record.json'
            Test-Path -LiteralPath $dataRecordPath | Should Be $true
            $hook = {
                param($relative)
                # Simulate a concurrent process (for example a fresh install elsewhere sharing the same
                # data root) replacing install-record.json partway through this uninstall's own
                # file-deletion loop.
                Set-Content -LiteralPath $dataRecordPath -Value '{"concurrent":"newer-record"}' -Encoding UTF8
            }.GetNewClosure()
            & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -PreDeleteHook $hook | Out-Null
            (Get-Content -LiteralPath $dataRecordPath -Raw) | Should Match 'concurrent'
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'preserves a file it did not install and warns instead of forcing recursive delete' {
        $root = Join-Path $FixtureRoot 'leftover-file-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $leftover = Join-Path $root 'not-mine.txt'
        Set-Content -LiteralPath $leftover -Value 'user data left here after install'
        & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -WarningVariable uninstallWarnings | Out-Null
        Test-Path -LiteralPath $leftover | Should Be $true
        Test-Path -LiteralPath (Join-Path $root '.leanlaunch-install.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $false
        @($uninstallWarnings).Count | Should BeGreaterThan 0
    }

    It 'refuses to act when the install root is a reparse point' {
        $target = Join-Path $FixtureRoot 'junction-target'
        $root = Join-Path $FixtureRoot 'junction-install-root'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path $root -Target $target | Out-Null
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
        }
        finally {
            (Get-Item -LiteralPath $root -Force).Delete()
        }
    }

    It 'refuses to uninstall through a reparse point substituted after install' {
        $root = Join-Path $FixtureRoot 'junction-uninstall-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $binDir = Join-Path $root 'bin'
        $binTarget = Join-Path $FixtureRoot 'junction-uninstall-bin-target'
        Remove-Item -LiteralPath $binDir -Recurse -Force
        New-Item -ItemType Directory -Path $binTarget -Force | Out-Null
        New-Item -ItemType Junction -Path $binDir -Target $binTarget | Out-Null
        try {
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false } | Should Throw
        }
        finally {
            (Get-Item -LiteralPath $binDir -Force).Delete()
        }
    }

    It 'detects a reparse point substituted between two files deletions instead of relying on a one-time pre-pass' {
        $root = Join-Path $FixtureRoot 'reparse-mid-delete-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $srcDir = Join-Path $root 'src'
        $decoyTarget = Join-Path $FixtureRoot 'reparse-mid-delete-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        $script:reparseMidDeleteSrcFilesSeen = 0
        $hook = {
            param($relative)
            if ($relative -like 'src\*') {
                $script:reparseMidDeleteSrcFilesSeen++
                if ($script:reparseMidDeleteSrcFilesSeen -eq 2) {
                    Remove-Item -LiteralPath $srcDir -Recurse -Force
                    New-Item -ItemType Junction -Path $srcDir -Target $decoyTarget | Out-Null
                }
            }
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -Confirm:$false -PreDeleteHook $hook } | Should Throw
        }
        finally {
            if (Test-Path -LiteralPath $srcDir) { (Get-Item -LiteralPath $srcDir -Force).Delete() }
        }
    }

    It 'refuses -RemoveData against a reparse-point data root when no install record exists' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'removedata-norecord-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        $decoyTarget = Join-Path $FixtureRoot 'removedata-norecord-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        New-Item -ItemType Junction -Path $dataRoot -Target $decoyTarget | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'removedata-norecord-installroot'
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -RemoveData -Confirm:$false } | Should Throw
            Test-Path -LiteralPath $dataRoot | Should Be $true
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
            if (Test-Path -LiteralPath $dataRoot) { (Get-Item -LiteralPath $dataRoot -Force).Delete() }
        }
    }

    It 'rolls back the entire install root and leaves no orphaned staging/backup directories when a failure occurs right after the filesystem commit (fresh install)' {
        $root = Join-Path $FixtureRoot 'postcommit-fresh-rollback'
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostCommitHook { throw 'simulated failure after commit' } } | Should Throw
        Test-Path -LiteralPath $root | Should Be $false
        $parent = Split-Path -Parent $root
        @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-staging-*' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-backup-*' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'preserves an unrelated file created concurrently in a fresh InstallRoot during a late-failure rollback, while removing all LeanLaunch-owned additions' {
        $root = Join-Path $FixtureRoot 'fresh-concurrent-file-root'
        $hook = {
            # Simulate an unrelated concurrent process dropping a file into the just-committed fresh
            # install root before this run's own later steps fail.
            Set-Content -LiteralPath (Join-Path $root 'concurrent-unrelated.txt') -Value "not LeanLaunch's file"
            throw 'simulated late failure after an unrelated concurrent file appeared'
        }.GetNewClosure()
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostCommitHook $hook } | Should Throw

        # The unrelated concurrent file must survive...
        Test-Path -LiteralPath (Join-Path $root 'concurrent-unrelated.txt') | Should Be $true
        # ...while every LeanLaunch-owned file/directory this run added must be gone...
        Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root 'bin\leanlaunch.cmd') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root '.leanlaunch-install.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root 'src') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root 'bin') | Should Be $false
        # ...and InstallRoot itself must survive, not be recursively force-deleted wholesale, because
        # it is not actually empty.
        Test-Path -LiteralPath $root | Should Be $true
    }

    It 'leaves the destination byte-identical to its prior content when the atomic commit write is interrupted before the swap' {
        $root = Join-Path $FixtureRoot 'midcopy-corruption-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $targetFile = Join-Path $root 'src\LeanLaunch.psm1'
        $originalHash = (Get-FileHash -LiteralPath $targetFile).Hash

        # The commit copy is now a same-volume atomic temp-file-then-swap: the source is fully copied
        # into a throwaway temp file first, and only a successful [IO.File]::Replace/Move ever touches
        # the live destination. This hook fires as that atomic operation's own TestHookBeforeCommit -
        # after the temp file is fully written, but before the swap - so throwing here proves the live
        # destination is never touched at all (not merely "restored after" being corrupted).
        $hook = {
            param($relative)
            if ($relative -eq 'src\LeanLaunch.psm1') {
                throw 'simulated write failure before the atomic swap'
            }
        }
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreFileCommitWriteHook $hook } | Should Throw

        (Get-FileHash -LiteralPath $targetFile).Hash | Should Be $originalHash
        @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.tmp' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.bak' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'refuses to follow a substituted backup source during rollback and leaves the destination untouched instead of deleting it' {
        $root = Join-Path $FixtureRoot 'backup-source-reparse-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $targetFile = Join-Path $root 'src\LeanLaunch.psm1'
        $originalContent = Get-Content -LiteralPath $targetFile -Raw
        $decoyTarget = Join-Path $FixtureRoot 'backup-source-reparse-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null

        $hook = {
            param($relative)
            if ($relative -eq 'src\LeanLaunch.psm1') {
                # This file's own backup was captured moments earlier in this same commit-loop
                # iteration. Substitute its container for a reparse point before rollback ever gets a
                # chance to read it back.
                $parentDir = Split-Path -Parent $root
                $backupRoot = @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter '.leanlaunch-backup-*' -Force)[0].FullName
                $backupSrcDir = Join-Path $backupRoot 'src'
                Remove-Item -LiteralPath $backupSrcDir -Recurse -Force
                New-Item -ItemType Junction -Path $backupSrcDir -Target $decoyTarget | Out-Null
                throw 'simulated failure after the backup source was substituted for a reparse point'
            }
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreFileCommitWriteHook $hook } | Should Throw
            Test-Path -LiteralPath $targetFile | Should Be $true
            (Get-Content -LiteralPath $targetFile -Raw) | Should Be $originalContent
        }
        finally {
            $parentDir = Split-Path -Parent $root
            $leftoverBackups = @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter '.leanlaunch-backup-*' -Force -ErrorAction SilentlyContinue)
            foreach ($b in $leftoverBackups) {
                $srcDir = Join-Path $b.FullName 'src'
                if (Test-Path -LiteralPath $srcDir) {
                    $item = Get-Item -LiteralPath $srcDir -Force
                    if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
                }
                Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'refuses to follow a backup substituted after a successful commit, leaving the just-committed content intact' {
        $root = Join-Path $FixtureRoot 'postcommit-backup-source-reparse-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $targetFile = Join-Path $root 'src\LeanLaunch.psm1'
        # Simulate that the PRIOR install had different (older) content at this exact path, without
        # touching the real source checkout, so "restored to the prior original" and "left as the
        # newly committed content" are distinguishable outcomes.
        Set-Content -LiteralPath $targetFile -Value 'SIMULATED-OLDER-ORIGINAL-CONTENT' -Encoding UTF8 -NoNewline
        $newContentHash = (Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'src\LeanLaunch.psm1')).Hash
        $decoyTarget = Join-Path $FixtureRoot 'postcommit-backup-source-reparse-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null

        $postCommitHook = {
            param($relative)
            if ($relative -eq 'src\LeanLaunch.psm1') {
                # This file's commit already succeeded (fingerprint recorded) by the time this hook
                # fires. Substitute its backup for a reparse point now, then let the rest of the
                # install proceed and fail later elsewhere.
                $parentDir = Split-Path -Parent $root
                $backupRoot = @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter '.leanlaunch-backup-*' -Force)[0].FullName
                $backupSrcDir = Join-Path $backupRoot 'src'
                Remove-Item -LiteralPath $backupSrcDir -Recurse -Force
                New-Item -ItemType Junction -Path $backupSrcDir -Target $decoyTarget | Out-Null
            }
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostFileCommitHook $postCommitHook -PreMarkerWriteHook { throw 'simulated late failure' } } | Should Throw
            Test-Path -LiteralPath $targetFile | Should Be $true
            (Get-FileHash -LiteralPath $targetFile).Hash | Should Be $newContentHash
        }
        finally {
            $parentDir = Split-Path -Parent $root
            $leftoverBackups = @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter '.leanlaunch-backup-*' -Force -ErrorAction SilentlyContinue)
            foreach ($b in $leftoverBackups) {
                $srcDir = Join-Path $b.FullName 'src'
                if (Test-Path -LiteralPath $srcDir) {
                    $item = Get-Item -LiteralPath $srcDir -Force
                    if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
                }
                Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'surfaces an error when rollback itself cannot fully restore a previously committed file' {
        $root = Join-Path $FixtureRoot 'rollback-restore-failure-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        # $global: (not $script:) is required here: the hook below is invoked from WITHIN install.ps1's
        # own script scope (a separate .ps1 file), so a $script:-scoped assignment inside it would land
        # in install.ps1's script scope, not this test file's - leaving this test unable to see or
        # dispose the lock it thinks it created, and leaking a real open file handle.
        $global:leanLaunchRollbackFailureLockStream = $null
        $postCommitHook = {
            param($relative)
            if ($relative -eq 'bin\leanlaunch.cmd') {
                $parentDir = Split-Path -Parent $root
                $backupRoot = @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter '.leanlaunch-backup-*' -Force)[0].FullName
                $backupFile = Join-Path $backupRoot 'bin\leanlaunch.cmd'
                # Exclusively lock this file's own backup so rollback's later attempt to read it back
                # (to restore this already-committed file) genuinely fails - a real restore-step
                # failure, not merely one simulated via a throwing test hook.
                $global:leanLaunchRollbackFailureLockStream = New-Object -TypeName IO.FileStream -ArgumentList @(
                    $backupFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            }
        }.GetNewClosure()
        try {
            $errorMessage = $null
            try {
                & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostFileCommitHook $postCommitHook -PreMarkerWriteHook { throw 'simulated late failure requiring rollback' }
            }
            catch { $errorMessage = $_.Exception.Message }
            $errorMessage | Should Not Be $null
            $errorMessage | Should Match 'simulated late failure requiring rollback'
            # Rollback's own inability to restore this specific file must be surfaced, not silently
            # swallowed behind the original failure's message alone.
            $errorMessage | Should Match ([regex]::Escape('bin\leanlaunch.cmd'))
        }
        finally {
            if ($null -ne $global:leanLaunchRollbackFailureLockStream) {
                $global:leanLaunchRollbackFailureLockStream.Dispose()
                Remove-Variable -Name leanLaunchRollbackFailureLockStream -Scope Global -ErrorAction SilentlyContinue
            }
            # Rollback's own best-effort backupRoot cleanup necessarily failed silently while the lock
            # above was held (that failure is exactly what this test proves must be surfaced) - clean
            # up the now-unlocked leftover backup directory so it cannot leak into other tests' counts.
            $parentDir = Split-Path -Parent $root
            foreach ($b in @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter '.leanlaunch-backup-*' -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'preserves a concurrently replaced manifest file instead of restoring/removing it on a fresh-install rollback' {
        $root = Join-Path $FixtureRoot 'fresh-concurrent-replace-root'
        $hook = {
            # Simulate a concurrent process replacing an installed file's content right after this
            # run's fresh install committed it.
            Set-Content -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') -Value 'CONCURRENTLY-REPLACED-CONTENT' -Encoding UTF8 -NoNewline
            throw 'simulated late failure after a concurrent replacement'
        }.GetNewClosure()
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostCommitHook $hook } | Should Throw

        (Get-Content -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') -Raw) | Should Match 'CONCURRENTLY-REPLACED-CONTENT'
        # Every OTHER LeanLaunch-owned file (untouched by the concurrent process) is still removed.
        Test-Path -LiteralPath (Join-Path $root 'bin\leanlaunch.cmd') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root 'bin') | Should Be $false
    }

    It 'preserves a concurrently replaced manifest file instead of restoring/removing it on an upgrade rollback' {
        $root = Join-Path $FixtureRoot 'upgrade-concurrent-replace-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $guiHash = (Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'src\LeanLaunch.Gui.ps1')).Hash
        $hook = {
            Set-Content -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') -Value 'CONCURRENTLY-REPLACED-CONTENT' -Encoding UTF8 -NoNewline
            throw 'simulated late failure after a concurrent replacement'
        }.GetNewClosure()
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostCommitHook $hook } | Should Throw

        (Get-Content -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') -Raw) | Should Match 'CONCURRENTLY-REPLACED-CONTENT'
        # Every OTHER file this run overwrote (untouched by the concurrent process) is still restored
        # to its pre-upgrade original content.
        (Get-FileHash -LiteralPath (Join-Path $root 'src\LeanLaunch.Gui.ps1')).Hash | Should Be $guiHash
    }

    It 'aborts an upgrade (via its own internal check, not a throwing hook) instead of overwriting a destination file that changed concurrently between backup and its own atomic swap, and rolls back files already committed earlier in the same upgrade attempt' {
        $root = Join-Path $FixtureRoot 'upgrade-forward-write-concurrent-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $cmdPath = Join-Path $root 'bin\leanlaunch.cmd'
        $psm1Path = Join-Path $root 'src\LeanLaunch.psm1'

        # Fake distinguishable "prior install" content on a file committed EARLIER in manifest order
        # ('bin' precedes 'src') so a later assertion can prove rollback genuinely restored THIS exact
        # content, not merely that an unchanged re-copy happened to match the real source bytes.
        Set-Content -LiteralPath $cmdPath -Value 'SIMULATED-OLDER-ORIGINAL-CMD-CONTENT' -Encoding UTF8 -NoNewline
        $oldCmdContent = Get-Content -LiteralPath $cmdPath -Raw
        $realNewPsm1Hash = (Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'src\LeanLaunch.psm1')).Hash

        # This hook fires as the atomic copy's own TestHookBeforeCommit for src\LeanLaunch.psm1 - after
        # its staged temp file is fully written, but before the reparse re-check/fingerprint-verify/
        # swap - and does NOT throw itself. It simulates a concurrent writer replacing the destination
        # in exactly that window. install.ps1's own -VerifyExpectedFingerprint check (using the
        # destination fingerprint captured immediately before this file's backup) must be what detects
        # the mismatch and aborts; nothing in the test raises the error directly.
        $hook = {
            param($relative)
            if ($relative -eq 'src\LeanLaunch.psm1') {
                Set-Content -LiteralPath $psm1Path -Value 'CONCURRENTLY-REPLACED-DURING-UPGRADE' -Encoding UTF8 -NoNewline
            }
        }.GetNewClosure()

        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreFileCommitWriteHook $hook } | Should Throw

        # The concurrently replaced file must survive completely untouched by the swap that was refused.
        (Get-Content -LiteralPath $psm1Path -Raw) | Should Be 'CONCURRENTLY-REPLACED-DURING-UPGRADE'
        (Get-FileHash -LiteralPath $psm1Path).Hash | Should Not Be $realNewPsm1Hash

        # bin\leanlaunch.cmd, already committed earlier in this same aborted upgrade attempt, must be
        # rolled back to its exact prior content - the previously valid install is not left corrupted
        # or partially upgraded.
        (Get-Content -LiteralPath $cmdPath -Raw) | Should Be $oldCmdContent

        # No leftover temp/backup artifacts anywhere under the install root.
        @(Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Filter '*.tmp' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Filter '*.bak' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        $parent = Split-Path -Parent $root
        @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-backup-*' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'aborts an upgrade instead of silently accepting a file a concurrent process just created at a path this upgrade expected to still be new' {
        $root = Join-Path $FixtureRoot 'upgrade-forward-write-concurrent-newfile-root'
        # A schema-1 marker predates the manifest, so every real product file - including
        # src\LeanLaunch.psm1 - is genuinely new to this install root, giving a destination whose
        # "expected fingerprint immediately before backup" is $null (absent), not a real hash.
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [ordered]@{ schemaVersion = 1; product = 'LeanLaunch'; installRoot = $root } |
            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Encoding UTF8
        $psm1Path = Join-Path $root 'src\LeanLaunch.psm1'

        $hook = {
            param($relative)
            if ($relative -eq 'src\LeanLaunch.psm1') {
                # Simulate a concurrent process creating this exact "new" file in the gap between this
                # upgrade capturing "absent" as the expected destination state and its own atomic swap.
                New-Item -ItemType Directory -Path (Split-Path -Parent $psm1Path) -Force | Out-Null
                Set-Content -LiteralPath $psm1Path -Value 'CONCURRENTLY-CREATED-BEFORE-UPGRADE-SWAP' -Encoding UTF8 -NoNewline
            }
        }.GetNewClosure()

        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreFileCommitWriteHook $hook } | Should Throw

        (Get-Content -LiteralPath $psm1Path -Raw) | Should Be 'CONCURRENTLY-CREATED-BEFORE-UPGRADE-SWAP'
    }

    It 'aborts instead of clobbering when install-record.json changes concurrently (without throwing itself) between backup and final write' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'concurrent-record-nonthrow-change-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $dataRecordPath = Join-Path $dataRoot 'install-record.json'
        Set-Content -LiteralPath $dataRecordPath -Value '{"original":"content"}' -Encoding UTF8
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'concurrent-record-nonthrow-change-root'
            $hook = {
                # Deliberately does NOT throw - install.ps1 itself must detect the mismatch on its own
                # initiative immediately before its own overwrite and abort.
                Set-Content -LiteralPath $dataRecordPath -Value '{"concurrent":"update"}' -Encoding UTF8
            }.GetNewClosure()
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreMarkerWriteHook $hook } | Should Throw
            (Get-Content -LiteralPath $dataRecordPath -Raw) | Should Match 'concurrent'
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'aborts instead of resurrecting when install-record.json is concurrently deleted (without throwing itself) between backup and final write' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'concurrent-record-nonthrow-delete-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $dataRecordPath = Join-Path $dataRoot 'install-record.json'
        Set-Content -LiteralPath $dataRecordPath -Value '{"original":"content"}' -Encoding UTF8
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'concurrent-record-nonthrow-delete-root'
            $hook = {
                Remove-Item -LiteralPath $dataRecordPath -Force
            }.GetNewClosure()
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreMarkerWriteHook $hook } | Should Throw
            Test-Path -LiteralPath $dataRecordPath | Should Be $false
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'refuses to write install-record.json when the atomic write itself is interrupted, leaving no truncation or stale resurrection' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'record-atomic-write-failure-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $dataRecordPath = Join-Path $dataRoot 'install-record.json'
        Set-Content -LiteralPath $dataRecordPath -Value '{"original":"content"}' -Encoding UTF8 -NoNewline
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'record-atomic-write-failure-root'
            # This hook fires as the atomic write's own TestHookBeforeCommit - after the new content is
            # fully written to a throwaway temp file, but before the atomic swap into install-record.json
            # itself. Throwing here proves the swap never happens: the original content survives
            # completely untouched (not truncated, not partially written, not replaced by a stale copy).
            $hook = { throw 'simulated failure immediately before the atomic swap' }
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -DataRecordAtomicWriteTestHook $hook } | Should Throw
            (Get-Content -LiteralPath $dataRecordPath -Raw) | Should Be '{"original":"content"}'
            @(Get-ChildItem -LiteralPath $dataRoot -Filter '*.tmp' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
            @(Get-ChildItem -LiteralPath $dataRoot -Filter '*.bak' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'aborts the atomic swap (via its own internal check, not a throwing hook) when install-record.json changes immediately before the swap' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'preswap-record-change-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $dataRecordPath = Join-Path $dataRoot 'install-record.json'
        Set-Content -LiteralPath $dataRecordPath -Value '{"original":"content"}' -Encoding UTF8 -NoNewline
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'preswap-record-change-root'
            # This hook does NOT throw - it silently changes the live file exactly like a genuine
            # concurrent process would. Set-LeanLaunchFileContentAtomic's OWN internal re-check,
            # immediately before the swap, must be what detects the mismatch and aborts; nothing in
            # the test itself raises the error.
            $hook = {
                Set-Content -LiteralPath $dataRecordPath -Value '{"changed-right-before-swap":"yes"}' -Encoding UTF8 -NoNewline
            }
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -DataRecordAtomicWriteTestHook $hook } | Should Throw
            (Get-Content -LiteralPath $dataRecordPath -Raw) | Should Be '{"changed-right-before-swap":"yes"}'
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'aborts the atomic swap (via its own internal check, not a throwing hook) when the marker changes immediately before the swap' {
        $root = Join-Path $FixtureRoot 'preswap-marker-change-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $installedMarkerPath = Join-Path $root '.leanlaunch-install.json'
        $hook = {
            Set-Content -LiteralPath $installedMarkerPath -Value '{"changed-right-before-swap":"yes"}' -Encoding UTF8 -NoNewline
        }
        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -MarkerAtomicWriteTestHook $hook } | Should Throw
        (Get-Content -LiteralPath $installedMarkerPath -Raw) | Should Be '{"changed-right-before-swap":"yes"}'
    }

    It 'preserves a concurrently written install-record.json instead of deleting it on rollback (fresh install)' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'concurrent-record-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRecordPath = Join-Path (Join-Path $fakeLocalAppData 'LeanLaunch') 'install-record.json'
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'concurrent-record-root'
            $hook = {
                # Simulate a concurrent process creating the data record after this run's own check
                # found nothing there.
                $dir = Split-Path -Parent $dataRecordPath
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Set-Content -LiteralPath $dataRecordPath -Value '{"concurrent":"content"}' -Encoding UTF8
                throw 'simulated failure after a concurrent writer created the record'
            }.GetNewClosure()
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreMarkerWriteHook $hook } | Should Throw
            Test-Path -LiteralPath $dataRecordPath | Should Be $true
            (Get-Content -LiteralPath $dataRecordPath -Raw) | Should Match 'concurrent'
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'preserves a concurrently modified install-record.json instead of restoring a stale backup over it on rollback (upgrade)' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'concurrent-record-modified-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $dataRecordPath = Join-Path $dataRoot 'install-record.json'
        Set-Content -LiteralPath $dataRecordPath -Value '{"original":"content"}' -Encoding UTF8
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        try {
            $root = Join-Path $FixtureRoot 'concurrent-record-modified-root'
            $hook = {
                Set-Content -LiteralPath $dataRecordPath -Value '{"concurrent":"update"}' -Encoding UTF8
                throw 'simulated failure after a concurrent writer changed the record'
            }.GetNewClosure()
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreMarkerWriteHook $hook } | Should Throw
            (Get-Content -LiteralPath $dataRecordPath -Raw) | Should Match 'concurrent'
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'rolls back newly created data directories and install-record.json on a late failure (fresh install)' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'postcommit-late-fresh-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        $originalPath = [Environment]::GetEnvironmentVariable('Path','Process')
        try {
            $root = Join-Path $FixtureRoot 'postcommit-late-fresh-root'
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -PreMarkerWriteHook { throw 'simulated late failure' } } | Should Throw
            Test-Path -LiteralPath $root | Should Be $false
            Test-Path -LiteralPath (Join-Path $fakeLocalAppData 'LeanLaunch') | Should Be $false
            [Environment]::GetEnvironmentVariable('Path','Process') | Should Be $originalPath
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $originalPath, 'Process')
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It 'restores the previous valid installation exactly (file content and marker) when a late failure occurs during an upgrade' {
        $root = Join-Path $FixtureRoot 'upgrade-rollback-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $psm1Path = Join-Path $root 'src\LeanLaunch.psm1'
        $originalPsm1Hash = (Get-FileHash -LiteralPath $psm1Path).Hash
        $originalMarker = Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw

        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreMarkerWriteHook { throw 'simulated failure during upgrade' } } | Should Throw

        (Get-FileHash -LiteralPath $psm1Path).Hash | Should Be $originalPsm1Hash
        (Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw) | Should Be $originalMarker
        Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.Gui.ps1') | Should Be $true
    }

    It 'preserves an unrelated file placed in the install root when an upgrade fails and rolls back' {
        $root = Join-Path $FixtureRoot 'upgrade-rollback-unrelated'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $unrelated = Join-Path $root 'not-mine.txt'
        Set-Content -LiteralPath $unrelated -Value 'user placed this here'

        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostCommitHook { throw 'simulated failure' } } | Should Throw

        Test-Path -LiteralPath $unrelated | Should Be $true
        (Get-Content -LiteralPath $unrelated -Raw) | Should Match 'user placed this here'
    }

    It 'removes a file that did not exist before this attempt when a late failure triggers rollback during an upgrade' {
        $root = Join-Path $FixtureRoot 'upgrade-rollback-newfile'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $guiPath = Join-Path $root 'src\LeanLaunch.Gui.ps1'
        Remove-Item -LiteralPath $guiPath -Force
        Test-Path -LiteralPath $guiPath | Should Be $false

        { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostCommitHook { throw 'simulated failure' } } | Should Throw

        Test-Path -LiteralPath $guiPath | Should Be $false
    }

    It 'detects a reparse point substituted mid-commit during an upgrade instead of relying on a one-time precheck' {
        $root = Join-Path $FixtureRoot 'install-reparse-mid-commit-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
        $srcDir = Join-Path $root 'src'
        $decoyTarget = Join-Path $FixtureRoot 'install-reparse-mid-commit-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        $script:installReparseSrcFilesSeen = 0
        $hook = {
            param($relative)
            if ($relative -like 'src\*') {
                $script:installReparseSrcFilesSeen++
                if ($script:installReparseSrcFilesSeen -eq 2) {
                    Remove-Item -LiteralPath $srcDir -Recurse -Force
                    New-Item -ItemType Junction -Path $srcDir -Target $decoyTarget | Out-Null
                }
            }
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreFileCommitHook $hook } | Should Throw
        }
        finally {
            if (Test-Path -LiteralPath $srcDir) {
                $item = Get-Item -LiteralPath $srcDir -Force
                if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
            }
        }
    }

    It 'refuses to recursively delete its backup scratch directory when a nested reparse point was planted inside it' {
        $root = Join-Path $FixtureRoot 'backup-nested-reparse-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null

        $decoyTarget = Join-Path $FixtureRoot 'backup-nested-reparse-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') -Value 'do not touch'

        $hook = {
            $parent = Split-Path -Parent $root
            $backup = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-backup-*' -Force)[0].FullName
            $nestedDir = Join-Path $backup 'bin'
            Remove-Item -LiteralPath $nestedDir -Recurse -Force
            New-Item -ItemType Junction -Path $nestedDir -Target $decoyTarget | Out-Null
        }.GetNewClosure()

        try {
            & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PostCommitHook $hook | Out-Null
            # The upgrade itself must still succeed - only the now-tainted backup scratch directory's
            # own cleanup is refused, rather than a nested junction being recursively deleted through.
            Test-Path -LiteralPath (Join-Path $root 'bin\leanlaunch.cmd') | Should Be $true
            Test-Path -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') | Should Be $true
            @(Get-ChildItem -LiteralPath $decoyTarget -Force).Count | Should Be 1
        }
        finally {
            $parent = Split-Path -Parent $root
            foreach ($b in @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-backup-*' -Force -ErrorAction SilentlyContinue)) {
                $nestedDir = Join-Path $b.FullName 'bin'
                if (Test-Path -LiteralPath $nestedDir) {
                    $item = Get-Item -LiteralPath $nestedDir -Force
                    if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
                }
                Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'refuses to stage when the staging parent directory is a reparse point substituted before install begins' {
        $parent = Join-Path $FixtureRoot 'staging-parent-reparse'
        $decoyTarget = Join-Path $FixtureRoot 'staging-parent-reparse-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        New-Item -ItemType Junction -Path $parent -Target $decoyTarget | Out-Null
        $root = Join-Path $parent 'actual-install'
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate } | Should Throw
            # Nothing should have been written through the junction into the decoy target.
            @(Get-ChildItem -LiteralPath $decoyTarget -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        }
        finally {
            (Get-Item -LiteralPath $parent -Force).Delete()
        }
    }

    It 'refuses to remove the staging directory during cleanup after it was substituted for a reparse point' {
        $root = Join-Path $FixtureRoot 'staging-root-reparse-root'
        $decoyTarget = Join-Path $FixtureRoot 'staging-root-reparse-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') -Value 'do not touch'
        $hook = {
            $parent = Split-Path -Parent $root
            $staging = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-staging-*' -Force)[0].FullName
            Remove-Item -LiteralPath $staging -Recurse -Force
            New-Item -ItemType Junction -Path $staging -Target $decoyTarget | Out-Null
            throw 'simulated failure to trigger staging cleanup through a substituted reparse point'
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -PreWriteHook $hook } | Should Throw
            # The cleanup in the catch must refuse to recurse-delete through the substituted junction.
            Test-Path -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') | Should Be $true
        }
        finally {
            $parent = Split-Path -Parent $root
            $leftoverStaging = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-staging-*' -Force -ErrorAction SilentlyContinue)
            foreach ($s in $leftoverStaging) {
                $item = Get-Item -LiteralPath $s.FullName -Force
                if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { $item.Delete() }
                else { Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'refuses to write into the data root when it has been substituted for a reparse point, and rolls back cleanly' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'dataroot-reparse-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        $decoyTarget = Join-Path $FixtureRoot 'dataroot-reparse-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') -Value 'do not touch'
        New-Item -ItemType Junction -Path $dataRoot -Target $decoyTarget | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        $originalPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
        try {
            $root = Join-Path $FixtureRoot 'dataroot-reparse-root'
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root } | Should Throw
            Test-Path -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') | Should Be $true
            @(Get-ChildItem -LiteralPath $decoyTarget -Force).Count | Should Be 1
            Test-Path -LiteralPath $root | Should Be $false
            [Environment]::GetEnvironmentVariable('Path', 'Process') | Should Be $originalPath
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $originalPath, 'Process')
            $env:LOCALAPPDATA = $originalLocalAppData
            if (Test-Path -LiteralPath $dataRoot) { (Get-Item -LiteralPath $dataRoot -Force).Delete() }
        }
    }

    It 'refuses to write into a data subdirectory when it has been substituted for a reparse point, and rolls back cleanly' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'datasubdir-reparse-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $profilesDir = Join-Path $dataRoot 'profiles'
        $decoyTarget = Join-Path $FixtureRoot 'datasubdir-reparse-decoy'
        New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') -Value 'do not touch'
        New-Item -ItemType Junction -Path $profilesDir -Target $decoyTarget | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        $originalPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
        try {
            $root = Join-Path $FixtureRoot 'datasubdir-reparse-root'
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root } | Should Throw
            Test-Path -LiteralPath (Join-Path $decoyTarget 'sentinel.txt') | Should Be $true
            Test-Path -LiteralPath $root | Should Be $false
            [Environment]::GetEnvironmentVariable('Path', 'Process') | Should Be $originalPath
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $originalPath, 'Process')
            $env:LOCALAPPDATA = $originalLocalAppData
            if (Test-Path -LiteralPath $profilesDir) { (Get-Item -LiteralPath $profilesDir -Force).Delete() }
        }
    }

    It 'refuses -RemoveData against a reparse-point data root during a normal uninstall' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'removedata-normal-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        try {
            $root = Join-Path $FixtureRoot 'removedata-normal-installroot'
            & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate | Out-Null
            Remove-Item -LiteralPath $dataRoot -Recurse -Force
            $decoyTarget = Join-Path $FixtureRoot 'removedata-normal-decoy'
            New-Item -ItemType Directory -Path $decoyTarget -Force | Out-Null
            New-Item -ItemType Junction -Path $dataRoot -Target $decoyTarget | Out-Null
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -SkipPathUpdate -RemoveData -Confirm:$false } | Should Throw
            Test-Path -LiteralPath $dataRoot | Should Be $true
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
            if (Test-Path -LiteralPath $dataRoot) { (Get-Item -LiteralPath $dataRoot -Force).Delete() }
        }
    }

    It 'reports (rather than silently discards) a failure removing a newly-created data directory during rollback' {
        $fakeLocalAppData = Join-Path $FixtureRoot 'rollback-report-data-dir-appdata'
        New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
        $originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $fakeLocalAppData
        $dataRoot = Join-Path $fakeLocalAppData 'LeanLaunch'
        $lockedDir = Join-Path $dataRoot 'apps'
        $root = Join-Path $FixtureRoot 'rollback-report-data-dir-install'
        # A shared reference-type holder - GetNewClosure() captures $handleBox itself (the hashtable
        # object), not a snapshot of its contents, so writes the hook makes to $handleBox.Handle while
        # running inside install.ps1's scope are visible here in the test's own finally block. This
        # avoids relying on Set-Variable -Scope arithmetic across a closured scriptblock boundary, which
        # does not reliably target this test's scope.
        $handleBox = @{ Handle = $null }
        try {
            # Fires after install.ps1 has already created the (empty) data-root subdirectories, but
            # before the data-record write it wraps commits - lock one of those directories open, then
            # force the install to fail, so rollback must try (and fail) to remove it. The native call
            # is inlined (rather than calling the Lock-LeanLaunchDirectoryHandle helper function) because
            # this scriptblock executes inside install.ps1's own separate script scope, where a plain
            # function defined in this test file is not resolvable - only the already-loaded .NET type
            # (global regardless of script scope) and GetNewClosure()-captured variables are.
            $hook = {
                $GENERIC_READ = [Convert]::ToUInt32('80000000', 16)
                $FILE_SHARE_READ = [uint32]0x1
                $OPEN_EXISTING = [uint32]3
                $FILE_FLAG_BACKUP_SEMANTICS = [uint32]0x02000000
                $handleBox.Handle = [LeanLaunchTestNative.NativeMethods]::CreateFile($lockedDir, $GENERIC_READ, $FILE_SHARE_READ, [IntPtr]::Zero, $OPEN_EXISTING, $FILE_FLAG_BACKUP_SEMANTICS, [IntPtr]::Zero)
                if ($handleBox.Handle.IsInvalid) { throw "Failed to open a locking handle on '$lockedDir'." }
                throw 'simulated data-record persistence failure'
            }.GetNewClosure()

            $errorRecord = $null
            try {
                & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -SkipPathUpdate -DataRecordAtomicWriteTestHook $hook | Out-Null
            } catch { $errorRecord = $_ }

            $errorRecord | Should Not Be $null
            $errorRecord.Exception.Message | Should Match 'rollback could not fully restore'
            $errorRecord.Exception.Message | Should Match ([regex]::Escape($lockedDir))
        }
        finally {
            if ($null -ne $handleBox.Handle) { $handleBox.Handle.Close() }
            $env:LOCALAPPDATA = $originalLocalAppData
            if (Test-Path -LiteralPath $fakeLocalAppData) { Remove-Item -LiteralPath $fakeLocalAppData -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'LeanLaunch installer PATH ownership' {
    # These tests mutate the real per-user PATH environment variable (install.ps1/uninstall.ps1
    # hardcode the 'User' scope) and the real %LOCALAPPDATA%\LeanLaunch\install-record.json, since
    # that is the actual Windows boundary being verified. Both are captured and restored exactly,
    # even on failure, so the host machine is left exactly as found.
    BeforeEach {
        $script:originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
        $script:realDataRecordPath = Join-Path (Join-Path $env:LOCALAPPDATA 'LeanLaunch') 'install-record.json'
        $script:realDataRecordBackup = $null
        if (Test-Path -LiteralPath $script:realDataRecordPath -PathType Leaf) {
            $script:realDataRecordBackup = Get-Content -LiteralPath $script:realDataRecordPath -Raw
        }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('Path', $script:originalUserPath, 'Process')
        if ($null -ne $script:realDataRecordBackup) {
            Set-Content -LiteralPath $script:realDataRecordPath -Value $script:realDataRecordBackup -Encoding UTF8 -NoNewline
        }
        elseif (Test-Path -LiteralPath $script:realDataRecordPath -PathType Leaf) {
            Remove-Item -LiteralPath $script:realDataRecordPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'adds a PATH entry on install and removes only that entry on uninstall' {
        $root = Join-Path $FixtureRoot 'path-owned-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
        $binPath = Join-Path $root 'bin'
        $afterInstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        @($afterInstall -split ';') -contains $binPath | Should Be $true

        & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false | Out-Null
        $afterUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        @($afterUninstall -split ';') -contains $binPath | Should Be $false
        $afterUninstall | Should Be $script:originalUserPath
    }

    It 'removes its recorded PATH entry against a fresh read rather than the value snapshotted before confirmation' {
        # ShouldProcess (ConfirmImpact 'High') can genuinely pause for user confirmation between
        # reading PATH to decide whether a prompt is warranted and actually writing it. -Confirm:$false
        # skips the real prompt, but -PrePathRemovalConfirmedHook fires at the exact point confirmation
        # would have just been granted, simulating a concurrent PATH edit landing during that window.
        $root = Join-Path $FixtureRoot 'path-confirm-race-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
        $binPath = Join-Path $root 'bin'
        $concurrentEntry = Join-Path $FixtureRoot 'concurrently-added-during-prompt'

        & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false -PrePathRemovalConfirmedHook {
            $duringPrompt = [Environment]::GetEnvironmentVariable('Path', 'Process')
            [Environment]::SetEnvironmentVariable('Path', ($duringPrompt + ';' + $concurrentEntry), 'Process')
        } | Out-Null

        $afterUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        @($afterUninstall -split ';') -contains $binPath | Should Be $false
        @($afterUninstall -split ';') -contains $concurrentEntry | Should Be $true
    }

    It 'never removes a pre-existing PATH entry it did not add itself' {
        $root = Join-Path $FixtureRoot 'path-preexisting-install'
        $binPath = Join-Path $root 'bin'
        $seeded = @(@($script:originalUserPath -split ';' | Where-Object { $_ }) + $binPath) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $seeded, 'Process')

        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
        $marker = Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw | ConvertFrom-Json
        $marker.pathEntryAdded | Should Be $false

        & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false | Out-Null
        $afterUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        @($afterUninstall -split ';') -contains $binPath | Should Be $true
    }

    It 'still removes its recorded PATH entry after the install directory was deleted some other way' {
        $root = Join-Path $FixtureRoot 'path-orphaned-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
        $binPath = Join-Path $root 'bin'
        Remove-Item -LiteralPath $root -Recurse -Force

        & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false | Out-Null
        $afterUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        @($afterUninstall -split ';') -contains $binPath | Should Be $false
    }

    It 'refuses a forged install record that claims an unrelated PATH entry' {
        $root = Join-Path $FixtureRoot 'path-forged-record-install'
        $unrelated = Join-Path $FixtureRoot 'unrelated-existing-bin'
        New-Item -ItemType Directory -Path $unrelated -Force | Out-Null
        $seeded = @(@($script:originalUserPath -split ';' | Where-Object { $_ }) + $unrelated) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $seeded, 'Process')
        $recordDirectory = Split-Path -Parent $script:realDataRecordPath
        New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
        [ordered]@{
            schemaVersion = 2
            product = 'LeanLaunch'
            installRoot = $root
            files = @()
            directories = @()
            pathEntryAdded = $true
            pathEntryValue = $unrelated
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:realDataRecordPath -Encoding UTF8

        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false } | Should Throw
        @([Environment]::GetEnvironmentVariable('Path', 'Process') -split ';') -contains $unrelated | Should Be $true
    }

    It 'does not add a PATH entry when -WhatIf is used' {
        $root = Join-Path $FixtureRoot 'path-whatif-install'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -WhatIf | Out-Null
        [Environment]::GetEnvironmentVariable('Path', 'Process') | Should Be $script:originalUserPath
    }

    It 'rolls back staging and makes no PATH or marker changes when a failure occurs before commit' {
        $root = Join-Path $FixtureRoot 'rollback-install'
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -PreWriteHook { throw 'simulated failure before commit' } } | Should Throw
            Test-Path -LiteralPath $root | Should Be $false
            [Environment]::GetEnvironmentVariable('Path', 'Process') | Should Be $script:originalUserPath
            $parent = Split-Path -Parent $root
            @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-staging-*' -Force -ErrorAction SilentlyContinue).Count | Should Be 0
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $script:originalUserPath, 'Process')
        }
    }

    It 'writes a freshly re-read PATH value instead of the value snapshotted before staging began' {
        $root = Join-Path $FixtureRoot 'fresh-path-install'
        $binPath = Join-Path $root 'bin'
        $concurrentEntry = 'C:\LeanLaunchTestConcurrentEntry'
        try {
            & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -PreWriteHook {
                $current = [Environment]::GetEnvironmentVariable('Path', 'Process')
                [Environment]::SetEnvironmentVariable('Path', ($current + ';C:\LeanLaunchTestConcurrentEntry'), 'Process')
            } | Out-Null
            $afterInstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
            @($afterInstall -split ';') -contains $binPath | Should Be $true
            @($afterInstall -split ';') -contains $concurrentEntry | Should Be $true
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $script:originalUserPath, 'Process')
        }
    }

    It 'removes only its recorded entry even when another PATH entry was added after install but before uninstall' {
        $root = Join-Path $FixtureRoot 'path-concurrent-uninstall'
        try {
            & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
            $binPath = Join-Path $root 'bin'
            $concurrentEntry = 'C:\LeanLaunchTestConcurrentUninstallEntry'
            $current = [Environment]::GetEnvironmentVariable('Path', 'Process')
            [Environment]::SetEnvironmentVariable('Path', ($current + ';' + $concurrentEntry), 'Process')

            & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false | Out-Null
            $afterUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
            @($afterUninstall -split ';') -contains $binPath | Should Be $false
            @($afterUninstall -split ';') -contains $concurrentEntry | Should Be $true
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $script:originalUserPath, 'Process')
        }
    }

    It 'removes only the PATH entry it added and preserves an unrelated pre-existing entry when a late failure rolls back an install' {
        $root = Join-Path $FixtureRoot 'postcommit-late-path-rollback'
        $unrelated = Join-Path $FixtureRoot 'postcommit-late-path-unrelated'
        New-Item -ItemType Directory -Path $unrelated -Force | Out-Null
        $seeded = @(@($script:originalUserPath -split ';' | Where-Object { $_ }) + $unrelated) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $seeded, 'Process')
        try {
            { & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root -PreMarkerWriteHook { throw 'simulated late failure' } } | Should Throw
            $afterRollback = [Environment]::GetEnvironmentVariable('Path', 'Process')
            $binPath = Join-Path $root 'bin'
            @($afterRollback -split ';') -contains $binPath | Should Be $false
            @($afterRollback -split ';') -contains $unrelated | Should Be $true
            Test-Path -LiteralPath $root | Should Be $false
        }
        finally {
            [Environment]::SetEnvironmentVariable('Path', $script:originalUserPath, 'Process')
        }
    }

    It 'revalidates the marker before the FIRST mutation (PATH removal included), not merely before file deletion' {
        $root = Join-Path $FixtureRoot 'uninstall-marker-before-path-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
        $binPath = Join-Path $root 'bin'
        $pathBeforeUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        @($pathBeforeUninstall -split ';') -contains $binPath | Should Be $true
        $installedMarkerPath = Join-Path $root '.leanlaunch-install.json'
        $hook = {
            [ordered]@{
                schemaVersion = 2; product = 'LeanLaunch'; installRoot = $root
                files = @('leanlaunch.ps1'); directories = @('bin','src','profiles')
                pathEntryAdded = $false; pathEntryValue = $null
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $installedMarkerPath -Encoding UTF8
        }.GetNewClosure()
        try {
            { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false -PreDeletionPhaseHook $hook } | Should Throw
            # PATH must remain untouched - the concurrent-change check runs before ANY mutation,
            # including the PATH removal, not merely before file deletion.
            $pathAfterAttempt = [Environment]::GetEnvironmentVariable('Path', 'Process')
            @($pathAfterAttempt -split ';') -contains $binPath | Should Be $true
            Test-Path -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1') | Should Be $true
        }
        finally {
            $current = [Environment]::GetEnvironmentVariable('Path', 'Process')
            $parts = @($current -split ';' | Where-Object { $_ -and $_ -ne $binPath })
            [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Process')
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'restores every prior LeanLaunch file, the marker, and the PATH entry byte-identically when an unexpected failure occurs mid-uninstall' {
        $root = Join-Path $FixtureRoot 'uninstall-transaction-rollback-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
        $binPath = Join-Path $root 'bin'
        $pathBeforeUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        @($pathBeforeUninstall -split ';') -contains $binPath | Should Be $true

        $originalMarker = Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw
        $originalHashes = @{}
        foreach ($relative in @('bin\leanlaunch.cmd','src\LeanLaunch.psm1','src\LeanLaunch.Gui.ps1','leanlaunch.ps1','LeanLaunch.psd1')) {
            $originalHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash
        }

        # Throw on a file partway through the manifest (not the first), so at least one earlier file is
        # genuinely quarantined (moved out of the install root) before the failure, proving rollback
        # restores already-quarantined content, not merely content that was never touched.
        $hook = {
            param($relative)
            if ($relative -eq 'src\LeanLaunch.Gui.ps1') { throw 'simulated unexpected mid-uninstall failure' }
        }
        # $FixtureRoot is shared across every test in this file, so other adversarial tests can
        # legitimately leave their OWN unrelated quarantine directories sitting there (for example one
        # that could not safely restore through a substituted reparse point). The cleanup assertion
        # below therefore diffs against a before-snapshot rather than asserting a bare zero count, so it
        # only ever catches a leak from THIS test's own quarantine directory, not cross-test leftovers.
        $parent = Split-Path -Parent $root
        $quarantineDirsBefore = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

        { & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false -PreDeleteHook $hook } | Should Throw

        Test-Path -LiteralPath $root | Should Be $true
        foreach ($relative in $originalHashes.Keys) {
            $path = Join-Path $root $relative
            Test-Path -LiteralPath $path | Should Be $true
            (Get-FileHash -LiteralPath $path).Hash | Should Be $originalHashes[$relative]
        }
        (Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw) | Should Be $originalMarker

        $pathAfterRollback = [Environment]::GetEnvironmentVariable('Path', 'Process')
        $pathAfterRollback | Should Be $pathBeforeUninstall

        $quarantineDirsAfter = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        @($quarantineDirsAfter | Where-Object { $quarantineDirsBefore -notcontains $_ }).Count | Should Be 0
    }

    It 'has truthful recoverable behavior when finalization itself fails after every reversible step already succeeded: rolls back files, marker, and PATH exactly as any other mid-transaction failure would' {
        $root = Join-Path $FixtureRoot 'uninstall-finalization-failure-root'
        & (Join-Path $ProjectRoot 'install.ps1') -InstallRoot $root | Out-Null
        $pathBeforeUninstall = [Environment]::GetEnvironmentVariable('Path', 'Process')
        $originalMarker = Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw
        $originalPsm1Hash = (Get-FileHash -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1')).Hash
        # See the comment on the previous test: diff against a before-snapshot on both the install-side
        # AND the real-data-root-side scratch locations, since $FixtureRoot (and the real %LOCALAPPDATA%)
        # are shared with other tests/sessions that may legitimately leave their own leftovers.
        $parent = Split-Path -Parent $root
        $quarantineDirsBefore = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $realDataParent = $env:LOCALAPPDATA
        $realQuarantineDirsBefore = @(Get-ChildItem -LiteralPath $realDataParent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

        {
            & (Join-Path $ProjectRoot 'uninstall.ps1') -InstallRoot $root -Confirm:$false `
                -PreFinalizationHook { throw 'simulated failure at the finalization boundary, after every reversible step succeeded' }
        } | Should Throw

        # Nothing is irreversibly gone yet at the finalization boundary, so a failure exactly there
        # must still roll back fully, the same as any earlier failure - not leave a half-removed
        # install because "it was almost done".
        Test-Path -LiteralPath $root | Should Be $true
        (Get-FileHash -LiteralPath (Join-Path $root 'src\LeanLaunch.psm1')).Hash | Should Be $originalPsm1Hash
        (Get-Content -LiteralPath (Join-Path $root '.leanlaunch-install.json') -Raw) | Should Be $originalMarker
        [Environment]::GetEnvironmentVariable('Path', 'Process') | Should Be $pathBeforeUninstall

        $quarantineDirsAfter = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        @($quarantineDirsAfter | Where-Object { $quarantineDirsBefore -notcontains $_ }).Count | Should Be 0
        $realQuarantineDirsAfter = @(Get-ChildItem -LiteralPath $realDataParent -Directory -Filter '.leanlaunch-uninstall-quarantine-*' -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        @($realQuarantineDirsAfter | Where-Object { $realQuarantineDirsBefore -notcontains $_ }).Count | Should Be 0
    }
}
