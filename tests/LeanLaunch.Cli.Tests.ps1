. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'LeanLaunch command dispatcher' {
    It 'returns command help' {
        $result = Invoke-LeanLaunchCommand -CommandArguments @('help') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $result.exitCode | Should Be 0
        $result.message | Should Match 'leanlaunch snapshot'
    }

    It 'captures and stores a named snapshot' {
        $collectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        $result = Invoke-LeanLaunchCommand -CommandArguments @('snapshot','before') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $collectors
        $result.exitCode | Should Be 0
        Test-Path (Join-Path $FixtureRoot 'snapshots\before.json') | Should Be $true
    }

    It 'creates and lists a user profile' {
        $exe = Join-Path $FixtureRoot 'demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        (Invoke-LeanLaunchCommand -CommandArguments @('profile','init','demo','--exe',$exe) -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 0
        $result = Invoke-LeanLaunchCommand -CommandArguments @('list') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        @($result.data).name -contains 'demo' | Should Be $true
    }

    It 'lists a user profile once when it overrides a repository template' {
        $exe = Join-Path $FixtureRoot 'override.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchProfile -Name 'example' -Executable $exe -DataRoot $FixtureRoot | Out-Null
        $result = Invoke-LeanLaunchCommand -CommandArguments @('list') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        @($result.data | Where-Object name -eq 'example').Count | Should Be 1
        ($result.data | Where-Object name -eq 'example').path.StartsWith((Join-Path $FixtureRoot 'profiles')) | Should Be $true
    }

    It 'returns a useful error for unknown commands' {
        $result = Invoke-LeanLaunchCommand -CommandArguments @('nonsense') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $result.exitCode | Should Be 2
        $result.message | Should Match 'Unknown command'
    }

    It 'fails closed on extra or unknown command options' {
        (Invoke-LeanLaunchCommand -CommandArguments @('doctor','extra') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 2
        (Invoke-LeanLaunchCommand -CommandArguments @('run','example','--mystery') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 2
        (Invoke-LeanLaunchCommand -CommandArguments @('profile','init','demo','--exe','C:\demo.exe','--extra') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 2
    }

    It 'returns a nonzero exit code when cleanup is incomplete' {
        $exe = Join-Path $FixtureRoot 'cleanup-fail.exe'
        $helper = Join-Path $FixtureRoot 'cleanup-helper.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        Set-Content -LiteralPath $helper -Value 'fixture'
        $profilePath = Join-Path (Join-Path $FixtureRoot 'profiles') 'cleanup-fail.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        @{schemaVersion=1;name='cleanup-fail';executable=$exe;residualProcesses=@(@{name='cleanup-helper';executablePath=$helper})} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $profilePath
        $script:cliProcessReads = 0
        $adapter = @{
            GetService={}; StartService={}; StopService={}
            GetProcesses={
                $script:cliProcessReads++
                if($script:cliProcessReads -eq 1){@()}
                else{@([pscustomobject]@{Id=40;Name='cleanup-helper';Path=$helper;ParentId=99;CreationDate='child'})}
            }
            StartProcess={[pscustomobject]@{Id=99;Name='cleanup-fail';CreationDate='main'}}; WaitProcess={}; StopProcess={throw 'blocked'}
        }
        $result = Invoke-LeanLaunchCommand -CommandArguments @('run','cleanup-fail') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Adapter $adapter
        $result.exitCode | Should Be 3
        $result.data.status | Should Be 'CleanupIncomplete'
    }

    It 'returns a nonzero exit code when waiting times out' {
        $exe = Join-Path $FixtureRoot 'wait-timeout.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        $profilePath = Join-Path (Join-Path $FixtureRoot 'profiles') 'wait-timeout.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
        @{schemaVersion=1;name='wait-timeout';executable=$exe;waitForProcessNames=@('worker')} |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $profilePath
        $script:cliWaitReads = 0
        $adapter = @{
            GetService={}; StartService={}; StopService={}
            GetProcesses={ $script:cliWaitReads++; if($script:cliWaitReads -eq 1){@()}else{@([pscustomobject]@{Id=41;Name='worker';Path='C:\worker.exe';ParentId=99;CreationDate='child'})} }
            StartProcess={[pscustomobject]@{Id=99;Name='wait-timeout';CreationDate='main'}}; WaitProcess={}; WaitProcessBounded={return $false}; StopProcess={}
        }
        $result = Invoke-LeanLaunchCommand -CommandArguments @('run','wait-timeout') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Adapter $adapter
        $result.exitCode | Should Be 4
        $result.data.status | Should Be 'WaitTimedOut'
    }

    It 'counts removed startup entries and scheduled tasks in diff output' {
        $before = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@([pscustomobject]@{location='HKCU';name='Old';command='old.exe';user='me'});scheduledTasks=@([pscustomobject]@{taskPath='\';taskName='Old';state='Ready'});collectionErrors=@()}
        $after = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@()}
        Save-LeanLaunchSnapshot -Snapshot $before -Name 'cli-before' -DataRoot $FixtureRoot | Out-Null
        Save-LeanLaunchSnapshot -Snapshot $after -Name 'cli-after' -DataRoot $FixtureRoot | Out-Null
        $result = Invoke-LeanLaunchCommand -CommandArguments @('diff','cli-before','cli-after') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $result.message | Should Match '1 startup entries, 1 scheduled tasks'
    }

    It 'returns a LaunchGui intent for the gui command without opening a window' {
        $result = Invoke-LeanLaunchCommand -CommandArguments @('gui') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $result.exitCode | Should Be 0
        $result.data.action | Should Be 'LaunchGui'
    }

    It 'fails closed on an unknown app subcommand' {
        (Invoke-LeanLaunchCommand -CommandArguments @('app','frobnicate','demo') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 2
    }

    It 'creates, lists, and shows an application through the app subcommands' {
        $exe = Join-Path $FixtureRoot 'cli-app.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        $created = Invoke-LeanLaunchCommand -CommandArguments @('app','new','cliapp','--exe',$exe,'--display-name','CLI App') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $created.exitCode | Should Be 0
        $created.data.displayName | Should Be 'CLI App'

        $listed = Invoke-LeanLaunchCommand -CommandArguments @('app','list') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        @($listed.data | Where-Object name -eq 'cliapp').Count | Should Be 1

        $shown = Invoke-LeanLaunchCommand -CommandArguments @('app','show','cliapp') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $shown.data.policy | Should Be 'Unmanaged'
    }

    It 'runs the full app audit-to-launch pipeline through the CLI dispatcher' {
        $exe = Join-Path $FixtureRoot 'cli-pipeline.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        Invoke-LeanLaunchCommand -CommandArguments @('app','new','pipeline','--exe',$exe) -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        $collectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }

        $before = Invoke-LeanLaunchCommand -CommandArguments @('app','scan-before','pipeline') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $collectors
        $before.exitCode | Should Be 0

        $after = Invoke-LeanLaunchCommand -CommandArguments @('app','scan-after','pipeline') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $collectors
        $after.exitCode | Should Be 0

        $profileResult = Invoke-LeanLaunchCommand -CommandArguments @('app','profile','pipeline') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $profileResult.exitCode | Should Be 0

        $policyResult = Invoke-LeanLaunchCommand -CommandArguments @('app','policy','pipeline','Managed') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $policyResult.exitCode | Should Be 0
        $policyResult.data.policy | Should Be 'Managed'

        $adapter = @{
            GetService={}; StartService={}; StopService={}; GetProcesses={@()}
            StartProcess={ [pscustomobject]@{Id=88;Name='pipeline';CreationDate='main'} }
            WaitProcess={}; StopProcess={}
        }
        $runResult = Invoke-LeanLaunchCommand -CommandArguments @('app','run','pipeline','--dry-run') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Adapter $adapter
        $runResult.exitCode | Should Be 0
        $runResult.data.status | Should Be 'DryRun'
    }

    It 'sets and clears the idle-parking preference through the app park subcommand' {
        $exe = Join-Path $FixtureRoot 'cli-park.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        Invoke-LeanLaunchCommand -CommandArguments @('app','new','parkcli','--exe',$exe) -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        Invoke-LeanLaunchCommand -CommandArguments @('app','scan-before','parkcli') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $emptyCollectors | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='ParkCliSvc';DisplayName='ParkCliSvc';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Invoke-LeanLaunchCommand -CommandArguments @('app','scan-after','parkcli') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $afterCollectors | Out-Null
        Invoke-LeanLaunchCommand -CommandArguments @('app','classify','parkcli','Service|parkclisvc','Managed') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null

        $badState = Invoke-LeanLaunchCommand -CommandArguments @('app','park','parkcli','Service|parkclisvc','Maybe') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $badState.exitCode | Should Be 2

        $on = Invoke-LeanLaunchCommand -CommandArguments @('app','park','parkcli','Service|parkclisvc','On') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $on.exitCode | Should Be 0
        ($on.data.currentAudit.classifications | Where-Object { $_.key -eq 'Service|parkclisvc' }).parkWhenIdle | Should Be $true

        $off = Invoke-LeanLaunchCommand -CommandArguments @('app','park','parkcli','Service|parkclisvc','Off') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $off.exitCode | Should Be 0
        ($off.data.currentAudit.classifications | Where-Object { $_.key -eq 'Service|parkclisvc' }).parkWhenIdle | Should Be $false
    }

    It 'threads a custom adapter from the dispatcher into policy activation for idle parking' {
        $exe = Join-Path $FixtureRoot 'cli-policy-adapter.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        Invoke-LeanLaunchCommand -CommandArguments @('app','new','policyadapter','--exe',$exe) -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        Invoke-LeanLaunchCommand -CommandArguments @('app','scan-before','policyadapter') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $emptyCollectors | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='PolicyAdapterSvc';DisplayName='PolicyAdapterSvc';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Invoke-LeanLaunchCommand -CommandArguments @('app','scan-after','policyadapter') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $afterCollectors | Out-Null
        Invoke-LeanLaunchCommand -CommandArguments @('app','classify','policyadapter','Service|policyadaptersvc','Managed') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        Invoke-LeanLaunchCommand -CommandArguments @('app','park','policyadapter','Service|policyadaptersvc','On') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        Invoke-LeanLaunchCommand -CommandArguments @('app','profile','policyadapter') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null

        # A real (non-injected) adapter would try to query/change an actual Windows service named
        # 'PolicyAdapterSvc', which does not exist, and the policy change would fail. Success here
        # proves the dispatcher's own -Adapter parameter reaches Set-LeanLaunchApplicationPolicy's
        # idle-parking activation instead of silently falling back to the real adapter.
        $calls = New-Object System.Collections.ArrayList
        $fixtureAdapter = @{
            IsAdministrator = { $true }
            GetServiceStartMode = { param($name) [void]$calls.Add("Get:$name"); 'Auto' }
            SetServiceStartMode = { param($name, $expectedMode, $newMode) [void]$calls.Add("Set:${name}:${expectedMode}->${newMode}") }
            # Parking activation also reads live running state before deciding whether an
            # identity-bound stop is needed first; reporting Stopped keeps this test focused on
            # proving adapter threading (not exercising the stop-before-disable transaction, which
            # LeanLaunch.ServiceParking.Tests.ps1 already covers exhaustively).
            GetService = { param($name) [void]$calls.Add("GetService:$name"); [pscustomobject]@{ Name = $name; Status = 'Stopped'; ProcessId = 0 } }
        }
        $result = Invoke-LeanLaunchCommand -CommandArguments @('app','policy','policyadapter','Managed') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Adapter $fixtureAdapter
        $result.exitCode | Should Be 0
        $calls -contains 'Set:PolicyAdapterSvc:Auto->Disabled' | Should Be $true
    }

    It 'fails closed on wrong argument count for app park' {
        $exe = Join-Path $FixtureRoot 'cli-park-argcount.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        Invoke-LeanLaunchCommand -CommandArguments @('app','new','parkargcount','--exe',$exe) -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        (Invoke-LeanLaunchCommand -CommandArguments @('app','park','parkargcount') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 2
        (Invoke-LeanLaunchCommand -CommandArguments @('app','park','parkargcount','key','On','extra') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 2
    }

    It 'fails closed on extra or unknown app run options' {
        (Invoke-LeanLaunchCommand -CommandArguments @('app','run','pipeline','--mystery') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot).exitCode | Should Be 2
    }

    It 'saves partial evidence but returns a nonzero exit code when a snapshot collector fails' {
        $collectors = @{ Processes={ throw 'process collector failed' }; Services={@([pscustomobject]@{Name='Svc';DisplayName='Svc';State='Running';StartMode='Auto';ProcessId=1})}; Startup={@()}; ScheduledTasks={@()} }
        $result = Invoke-LeanLaunchCommand -CommandArguments @('snapshot','partial') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $collectors
        $result.exitCode | Should Be 5
        @($result.data.collectionErrors).Count | Should Be 1
        @($result.data.services).Count | Should Be 1
        Test-Path (Join-Path $FixtureRoot 'snapshots\partial.json') | Should Be $true
        $saved = Get-Content -LiteralPath (Join-Path $FixtureRoot 'snapshots\partial.json') -Raw | ConvertFrom-Json
        @($saved.services).Count | Should Be 1
        @($saved.collectionErrors).Count | Should Be 1
    }

    It 'saves partial evidence but returns a nonzero exit code when a collector returns values that fail to normalize' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = 'not-a-number'; Path = 'C:\bad.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $result = Invoke-LeanLaunchCommand -CommandArguments @('snapshot','normfail') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $collectors
        $result.exitCode | Should Be 5
        @($result.data.services).Count | Should Be 1
        @($result.data.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        Test-Path (Join-Path $FixtureRoot 'snapshots\normfail.json') | Should Be $true
    }

    It 'returns exit code 0 for a snapshot with no collector errors' {
        $collectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        $result = Invoke-LeanLaunchCommand -CommandArguments @('snapshot','clean') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $collectors
        $result.exitCode | Should Be 0
    }

    It 'returns a nonzero exit code from diff when the before snapshot had collector errors, while preserving evidence' {
        $before = [pscustomobject]@{schemaVersion=1;processes=@([pscustomobject]@{name='kept';id=1;parentId=0;path='C:\kept.exe';commandLine='';workingSetBytes=100});services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@([pscustomobject]@{collector='Services';message='boom'})}
        $after = [pscustomobject]@{schemaVersion=1;processes=@([pscustomobject]@{name='kept';id=1;parentId=0;path='C:\kept.exe';commandLine='';workingSetBytes=100});services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@()}
        Save-LeanLaunchSnapshot -Snapshot $before -Name 'diff-before-error' -DataRoot $FixtureRoot | Out-Null
        Save-LeanLaunchSnapshot -Snapshot $after -Name 'diff-after-clean' -DataRoot $FixtureRoot | Out-Null
        $result = Invoke-LeanLaunchCommand -CommandArguments @('diff','diff-before-error','diff-after-clean') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $result.exitCode | Should Be 5
        @($result.data.collectionErrors).Count | Should Be 1
    }

    It 'returns a nonzero exit code from diff when the after snapshot had collector errors, while preserving evidence' {
        $before = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@()}
        $after = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@([pscustomobject]@{collector='Processes';message='boom'})}
        Save-LeanLaunchSnapshot -Snapshot $before -Name 'diff-before-clean2' -DataRoot $FixtureRoot | Out-Null
        Save-LeanLaunchSnapshot -Snapshot $after -Name 'diff-after-error2' -DataRoot $FixtureRoot | Out-Null
        $result = Invoke-LeanLaunchCommand -CommandArguments @('diff','diff-before-clean2','diff-after-error2') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $result.exitCode | Should Be 5
        @($result.data.collectionErrors).Count | Should Be 1
    }

    It 'returns exit code 0 from diff when neither snapshot had collector errors' {
        $before = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@()}
        $after = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@()}
        Save-LeanLaunchSnapshot -Snapshot $before -Name 'diff-before-ok' -DataRoot $FixtureRoot | Out-Null
        Save-LeanLaunchSnapshot -Snapshot $after -Name 'diff-after-ok' -DataRoot $FixtureRoot | Out-Null
        $result = Invoke-LeanLaunchCommand -CommandArguments @('diff','diff-before-ok','diff-after-ok') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot
        $result.exitCode | Should Be 0
    }

    It 'still fails closed (throws, no partial save) for app scan-before/scan-after when a collector fails' {
        $exe = Join-Path $FixtureRoot 'cli-app-failclosed.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        Invoke-LeanLaunchCommand -CommandArguments @('app','new','failclosed','--exe',$exe) -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        $failingCollectors = @{ Processes={ throw 'process collector failed' }; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        $before = Invoke-LeanLaunchCommand -CommandArguments @('app','scan-before','failclosed') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $failingCollectors
        $before.exitCode | Should Be 1

        $okCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        Invoke-LeanLaunchCommand -CommandArguments @('app','scan-before','failclosed') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $okCollectors | Out-Null
        $after = Invoke-LeanLaunchCommand -CommandArguments @('app','scan-after','failclosed') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $failingCollectors
        $after.exitCode | Should Be 1
        (Import-LeanLaunchApplication -Name 'failclosed' -DataRoot $FixtureRoot).currentAudit.afterSnapshot | Should Be $null
    }

    It 'still fails closed for app scan-before/scan-after when a collector returns values that fail to normalize (not just an outright throw)' {
        $exe = Join-Path $FixtureRoot 'cli-app-normfail.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        Invoke-LeanLaunchCommand -CommandArguments @('app','new','normfail','--exe',$exe) -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot | Out-Null
        $normalizeFailingCollectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = 'not-a-number'; Path = 'C:\bad.exe'; WorkingSet64 = 100 }) }
            Services = { @() }; Startup = { @() }; ScheduledTasks = { @() }
        }
        $before = Invoke-LeanLaunchCommand -CommandArguments @('app','scan-before','normfail') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $normalizeFailingCollectors
        $before.exitCode | Should Be 1
        (Import-LeanLaunchApplication -Name 'normfail' -DataRoot $FixtureRoot).currentAudit | Should Be $null

        $okCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        Invoke-LeanLaunchCommand -CommandArguments @('app','scan-before','normfail') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $okCollectors | Out-Null
        $after = Invoke-LeanLaunchCommand -CommandArguments @('app','scan-after','normfail') -DataRoot $FixtureRoot -RepositoryRoot $ProjectRoot -Collectors $normalizeFailingCollectors
        $after.exitCode | Should Be 1
        (Import-LeanLaunchApplication -Name 'normfail' -DataRoot $FixtureRoot).currentAudit.afterSnapshot | Should Be $null
    }
}
