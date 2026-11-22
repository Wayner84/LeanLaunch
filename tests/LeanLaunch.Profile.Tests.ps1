. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'LeanLaunch profile handling' {
    It 'accepts simple command-friendly profile names' {
        Test-LeanLaunchProfileName 'solidworks-2026' | Should Be $true
    }

    It 'rejects traversal and shell metacharacters' {
        Test-LeanLaunchProfileName '../bad' | Should Be $false
        Test-LeanLaunchProfileName 'bad & whoami' | Should Be $false
    }

    It 'expands Windows environment variables without invoking a shell' {
        $env:LEANLAUNCH_TEST_ROOT = 'C:\Safe Root'
        Expand-LeanLaunchValue '%LEANLAUNCH_TEST_ROOT%\App\app.exe' | Should Be 'C:\Safe Root\App\app.exe'
    }

    It 'imports and normalizes a valid profile' {
        $exe = Join-Path $FixtureRoot 'demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        $profilePath = Join-Path $FixtureRoot 'demo.json'
        @{
            schemaVersion = 1
            name = 'demo'
            executable = $exe
            arguments = @('--safe')
            services = @('DemoService')
            residualProcesses = @(@{ name = 'demo-helper'; executablePath = $exe })
            waitForProcessNames = @('demo')
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $profilePath

        $profile = Import-LeanLaunchProfile -Path $profilePath
        $profile.name | Should Be 'demo'
        $profile.services.Count | Should Be 1
        $profile.cleanup.stopStartedServices | Should Be $true
    }

    It 'defaults optional arrays in a minimal profile' {
        $profilePath = Join-Path $FixtureRoot 'minimal.json'
        @{ schemaVersion = 1; name = 'minimal'; executable = 'C:\missing.exe' } |
            ConvertTo-Json | Set-Content -LiteralPath $profilePath
        $profile = Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck
        $profile.services.Count | Should Be 0
        $profile.arguments.Count | Should Be 0
        $profile.residualProcesses.Count | Should Be 0
    }

    It 'rejects malformed service names' {
        $profilePath = Join-Path $FixtureRoot 'bad.json'
        @{ schemaVersion = 1; name = 'bad'; executable = 'C:\missing.exe'; services = @('bad;Stop-Service x') } |
            ConvertTo-Json | Set-Content -LiteralPath $profilePath
        { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw
    }

    It 'requires an exact executable path for every residual process rule' {
        $profilePath = Join-Path $FixtureRoot 'unsafe-residual.json'
        @{schemaVersion=1;name='unsafe-residual';executable='C:\missing.exe';residualProcesses=@(@{name='helper'})} |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $profilePath
        { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw
    }

    It 'rejects profile filenames that do not match the declared name' {
        $profilePath = Join-Path $FixtureRoot 'different.json'
        @{schemaVersion=1;name='declared';executable='C:\missing.exe'} |
            ConvertTo-Json | Set-Content -LiteralPath $profilePath
        { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw
    }

    It 'rejects malformed property types instead of coercing them' {
        $profilePath = Join-Path $FixtureRoot 'typed.json'
        '{"schemaVersion":1,"name":"typed","executable":"C:\\\\missing.exe","services":[42]}' |
            Set-Content -LiteralPath $profilePath
        { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw

        '{"schemaVersion":1,"name":"typed","executable":"C:\\\\missing.exe","arguments":{"unsafe":"value"}}' |
            Set-Content -LiteralPath $profilePath
        { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw

        '{"schemaVersion":1,"name":"typed","executable":"C:\\\\missing.exe","cleanup":{"stopStartedServices":"false"}}' |
            Set-Content -LiteralPath $profilePath
        { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw
    }

    It 'rejects a string schemaVersion instead of coercing it' {
        $profilePath = Join-Path $FixtureRoot 'string-schema.json'
        '{"schemaVersion":"1","name":"string-schema","executable":"C:\\missing.exe"}' |
            Set-Content -LiteralPath $profilePath
        { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw
    }

    It 'rejects primitive JSON scalars for cleanup instead of silently accepting them' {
        $profilePath = Join-Path $FixtureRoot 'cleanup-scalar.json'
        foreach ($scalar in @('5', 'true', '"text"')) {
            ('{"schemaVersion":1,"name":"cleanup-scalar","executable":"C:\\missing.exe","cleanup":' + $scalar + '}') |
                Set-Content -LiteralPath $profilePath
            { Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck } | Should Throw
        }
    }

    It 'accepts an empty cleanup object and applies defaults' {
        $profilePath = Join-Path $FixtureRoot 'cleanup-empty.json'
        '{"schemaVersion":1,"name":"cleanup-empty","executable":"C:\\missing.exe","cleanup":{}}' |
            Set-Content -LiteralPath $profilePath
        $profile = Import-LeanLaunchProfile -Path $profilePath -SkipExecutableCheck
        $profile.cleanup.stopStartedServices | Should Be $true
        $profile.cleanup.stopResidualProcesses | Should Be $true
    }

    It 'does not create a profile when -WhatIf is used' {
        $exe = Join-Path $FixtureRoot 'whatif-demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        $result = New-LeanLaunchProfile -Name 'whatif-demo' -Executable $exe -DataRoot $FixtureRoot -WhatIf
        $result | Should Be $null
        Test-Path -LiteralPath (Join-Path (Join-Path $FixtureRoot 'profiles') 'whatif-demo.json') | Should Be $false
    }
}
