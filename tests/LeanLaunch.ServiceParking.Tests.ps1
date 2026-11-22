. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

function New-LeanLaunchParkingTestApp {
    param([string]$Name = 'parkapp', [string]$Root = $FixtureRoot)
    $exe = Join-Path $Root ($Name + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) { Set-Content -LiteralPath $exe -Value 'fixture' }
    New-LeanLaunchApplication -Name $Name -Executable $exe -DataRoot $Root | Out-Null
    return $exe
}

function New-LeanLaunchParkingFixtureAdapter {
    <#
    A fully fake, in-memory service-mode adapter. No real service name or Windows service control is
    ever touched: state lives entirely in the returned hashtable's Modes/Running/Calls collections.
    Every service defaults to NOT running unless explicitly listed in -Running (or later started via
    the fixture's own StartService), so tests that only care about start-mode transitions see exactly
    the same behavior as before running-state awareness existed - the new stop-before-disable branch
    activation now takes for a running service is simply never reached for them.
    #>
    param([hashtable]$Modes = @{}, [bool]$IsAdministrator = $true, [hashtable]$Running = @{}, [string[]]$RefuseStopFor = @())
    $state = @{
        Modes = $Modes; Calls = New-Object System.Collections.ArrayList; IsAdministrator = $IsAdministrator
        Running = $Running; ProcessIds = @{}; NextProcessId = 4200; RefuseStopFor = @($RefuseStopFor)
    }
    $adapter = @{
        IsAdministrator = { $state.IsAdministrator }.GetNewClosure()
        GetServiceStartMode = {
            param($name)
            [void]$state.Calls.Add("Get:$name")
            if (-not $state.Modes.ContainsKey($name)) { throw "Fixture has no recorded mode for '$name'." }
            return $state.Modes[$name]
        }.GetNewClosure()
        SetServiceStartMode = {
            param($name, $expectedMode, $newMode)
            [void]$state.Calls.Add("Set:${name}:${expectedMode}->${newMode}")
            if (-not $state.Modes.ContainsKey($name)) { throw "Fixture has no recorded mode for '$name'." }
            if ([string]$state.Modes[$name] -ne [string]$expectedMode) {
                throw "Service start type no longer matches the recorded value; refusing to change it."
            }
            $state.Modes[$name] = $newMode
        }.GetNewClosure()
        GetService = {
            param($name)
            [void]$state.Calls.Add("GetService:$name")
            $isRunning = [bool]$state.Running[$name]
            if ($isRunning -and -not $state.ProcessIds.ContainsKey($name)) {
                $state.ProcessIds[$name] = $state.NextProcessId
                $state.NextProcessId++
            }
            $processId = if ($state.ProcessIds.ContainsKey($name)) { [int]$state.ProcessIds[$name] } else { 0 }
            [pscustomobject]@{ Name = $name; Status = if ($isRunning) { 'Running' } else { 'Stopped' }; ProcessId = if ($isRunning) { $processId } else { 0 } }
        }.GetNewClosure()
        GetProcessCreationTime = {
            param($processId)
            [void]$state.Calls.Add("GetProcessCreationTime:$processId")
            return [long](10000 + [int]$processId)
        }.GetNewClosure()
        StartService = {
            param($name)
            [void]$state.Calls.Add("StartService:$name")
            if (-not $state.ProcessIds.ContainsKey($name)) {
                $state.ProcessIds[$name] = $state.NextProcessId
                $state.NextProcessId++
            }
            $state.Running[$name] = $true
            $true
        }.GetNewClosure()
        StopService = {
            param($name, $expectedProcessId, $expectedCreationTime)
            [void]$state.Calls.Add("StopService:${name}:${expectedProcessId}:${expectedCreationTime}")
            if ($state.RefuseStopFor -contains $name) { throw "Simulated stop failure for '$name'." }
            $state.Running[$name] = $false
        }.GetNewClosure()
    }
    return [pscustomobject]@{ Adapter = $adapter; State = $state }
}

function New-LeanLaunchParkingRunAdapter {
    <#
    Extends the parking fixture with the full adapter surface Invoke-LeanLaunchRun needs, so a
    complete managed run (service park/restore, process start/wait) can be exercised without ever
    touching a real process or service.
    #>
    param([hashtable]$Modes = @{}, [bool]$FailStartProcess = $false, [string[]]$FailStopServiceFor = @())
    $fixture = New-LeanLaunchParkingFixtureAdapter -Modes $Modes
    $adapter = $fixture.Adapter
    # A parked service's temporarily-restored start mode does not imply it is already Running - it
    # still needs the normal profile-driven StartService call, exactly like a real Automatic-start
    # service that was reconfigured while the machine was already up.
    $fixture.State.Running = @{}
    $fixture.State.FailStopServiceFor = @($FailStopServiceFor)
    $adapter.GetService = {
        param($name)
        $isRunning = [bool]$fixture.State.Running[$name]
        [pscustomobject]@{ Name = $name; Status = if ($isRunning) { 'Running' } else { 'Stopped' }; ProcessId = if ($isRunning) { 123 } else { 0 } }
    }.GetNewClosure()
    $adapter.StartService = { param($name) $fixture.State.Running[$name] = $true; $true }.GetNewClosure()
    $adapter.StopService = {
        param($name, $expectedProcessId, $expectedCreationTime)
        if ($fixture.State.FailStopServiceFor -contains $name) { throw "Simulated stop failure for '$name'." }
        $fixture.State.Running[$name] = $false
    }.GetNewClosure()
    $adapter.GetProcesses = { @() }
    $adapter.StartProcess = {
        param($executable, $arguments, $workingDirectory)
        [void]$fixture.State.Calls.Add('StartProcess')
        if ($FailStartProcess) { throw 'Simulated process launch failure.' }
        [pscustomobject]@{ Id = 4242; Name = 'parkapp'; CreationDate = 'main' }
    }.GetNewClosure()
    $adapter.WaitProcess = { param($process) }
    $adapter.StopProcess = { param($process) }
    return $fixture
}

function New-LeanLaunchParkedFixture {
    <#
    Builds an application with one Service classification, marked Managed and opted in to idle
    parking, ready for New-LeanLaunchApplicationProfile / Set-LeanLaunchApplicationPolicy. The
    service name is a fixture-only label ('FixtureSvcA'), never a real Windows service.
    #>
    param([string]$Root, [string]$AppName = 'parkapp', [string]$ServiceName = 'FixtureSvcA', [string]$OriginalMode = 'Auto')
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    New-LeanLaunchParkingTestApp -Name $AppName -Root $Root | Out-Null
    $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
    New-LeanLaunchApplicationBeforeSnapshot -Name $AppName -DataRoot $Root -Collectors $emptyCollectors -Confirm:$false | Out-Null
    $afterCollectors = @{
        Processes = { @() }
        Services = { @([pscustomobject]@{Name=$ServiceName;DisplayName=$ServiceName;State='Running';StartMode='Automatic';ProcessId=10}) }
        Startup = { @() }; ScheduledTasks = { @() }
    }
    Complete-LeanLaunchApplicationAudit -Name $AppName -DataRoot $Root -Collectors $afterCollectors -Confirm:$false | Out-Null
    $key = 'Service|' + $ServiceName.ToLowerInvariant()
    Set-LeanLaunchResourceClassification -Name $AppName -Key $key -Decision 'Managed' -DataRoot $Root -Confirm:$false | Out-Null
    Set-LeanLaunchServiceParkingPreference -Name $AppName -Key $key -ParkWhenIdle $true -DataRoot $Root | Out-Null
    New-LeanLaunchApplicationProfile -Name $AppName -DataRoot $Root -Confirm:$false | Out-Null
    return $key
}

Describe 'LeanLaunch service idle-parking preference' {
    It 'can only be enabled for a Service resource already classified Managed' {
        $root = Join-Path $FixtureRoot 'park-pref-gate'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='FixtureSvc';DisplayName='Fixture';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @([pscustomobject]@{Location='HKCU';Name='FixtureTask';Command='C:\fixture\task.exe';User='me'}) }
            ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null

        # Not yet Managed - rejected.
        { Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvc' -ParkWhenIdle $true -DataRoot $root } | Should Throw

        # A StartupEntry can never become Managed, so it can never acquire parkWhenIdle either.
        { Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'StartupEntry|hkcu|fixturetask' -ParkWhenIdle $true -DataRoot $root } | Should Throw

        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvc' -ParkWhenIdle $true -DataRoot $root | Out-Null
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        ($application.currentAudit.classifications | Where-Object { $_.key -eq 'Service|fixturesvc' }).parkWhenIdle | Should Be $true
    }

    It 'defaults every newly discovered service candidate to parkWhenIdle false' {
        $root = Join-Path $FixtureRoot 'park-pref-default'
        $key = $null
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='FixtureSvc';DisplayName='Fixture';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $result = Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false
        ($result.application.currentAudit.classifications | Where-Object { $_.key -eq 'Service|fixturesvc' }).parkWhenIdle | Should Be $false
    }

    It 'immediately restores a currently-parked service when its preference is turned off while the application remains Managed' {
        $root = Join-Path $FixtureRoot 'park-pref-immediate-off'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'

        Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key $key -ParkWhenIdle $false -DataRoot $root -Adapter $fixture.Adapter | Out-Null

        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Managed'
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
        ($application.currentAudit.classifications | Where-Object { $_.key -eq $key }).parkWhenIdle | Should Be $false
    }

    It 'does not touch the service or the persisted preference when turning parkWhenIdle off is not yet parked' {
        $root = Join-Path $FixtureRoot 'park-pref-off-not-parked'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='FixtureSvc';DisplayName='Fixture';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null

        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvc = 'Auto' } -IsAdministrator $false
        # Never parked in the first place, so turning the preference off must not require elevation
        # or touch any service - there is nothing to restore.
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvc' -ParkWhenIdle $false -DataRoot $root -Adapter $fixture.Adapter | Out-Null
        $fixture.State.Calls.Count | Should Be 0
    }

    It 'fails closed without elevation when turning off parkWhenIdle for a currently-parked service, leaving it parked and the preference unchanged' {
        $root = Join-Path $FixtureRoot 'park-pref-immediate-off-not-elevated'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $nonAdminFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Disabled' } -IsAdministrator $false
        { Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key $key -ParkWhenIdle $false -DataRoot $root -Adapter $nonAdminFixture.Adapter } | Should Throw

        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $true
        ($application.currentAudit.classifications | Where-Object { $_.key -eq $key }).parkWhenIdle | Should Be $true
    }

    It 'rolls back the service restore when persisting a turned-off preference fails, leaving the service and the record consistent' {
        $root = Join-Path $FixtureRoot 'park-pref-off-persist-fails'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'

        # Inject the concurrent external write via -TestHookBeforeCommit, which fires inside
        # Set-LeanLaunchServiceParkingPreference at the exact instant between its own internal read
        # (Import-LeanLaunchApplicationForUpdate, already completed before this hook runs) and its
        # internal commit - a genuine race, not a change made before the operation ever read the
        # record (which the compare-and-swap guard cannot and should not detect).
        $appPath = Join-Path (Join-Path $root 'apps') 'parkapp.json'
        $raceHook = {
            $externallyChanged = Get-Content -LiteralPath $appPath -Raw | ConvertFrom-Json
            $externallyChanged.displayName = 'changed-out-from-under-us'
            $externallyChanged | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $appPath -Encoding UTF8
        }.GetNewClosure()

        {
            Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key $key -ParkWhenIdle $false -DataRoot $root `
                -Adapter $fixture.Adapter -TestHookBeforeCommit $raceHook
        } | Should Throw

        # The service must be restored to the parked (Disabled) state, matching the persisted
        # record's own (externally changed, but still parked=true) claim - never a torn "service
        # running, record says parked" state left behind by a failed persist.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $true
        ($application.currentAudit.classifications | Where-Object { $_.key -eq $key }).parkWhenIdle | Should Be $true
        # The refused write must never have clobbered the concurrent writer's own change either.
        $application.displayName | Should Be 'changed-out-from-under-us'
    }

    It 'restarts a service that was running when parked, not merely re-enables its start mode, when its preference is turned off' {
        $root = Join-Path $FixtureRoot 'park-pref-off-restarts-running'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
        $fixture.State.Running['FixtureSvcA'] | Should Be $false

        Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key $key -ParkWhenIdle $false -DataRoot $root -Adapter $fixture.Adapter | Out-Null

        # Full-state restoration: start mode back to original AND the service actually running again -
        # not merely no-longer-Disabled-but-still-stopped.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $fixture.State.Running['FixtureSvcA'] | Should Be $true
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'stops the service again (identity-bound) before re-disabling it when persistence fails after restarting it' {
        $root = Join-Path $FixtureRoot 'park-pref-off-restart-then-persist-fails'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $hook = { throw 'simulated persistence failure immediately before commit' }
        {
            Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key $key -ParkWhenIdle $false -DataRoot $root `
                -Adapter $fixture.Adapter -TestHookBeforeCommit $hook
        } | Should Throw

        # The service was restarted, then the persist failed - it must be stopped and re-disabled
        # again (fully re-parked), never left running-but-supposedly-still-parked-on-disk.
        $fixture.State.Running['FixtureSvcA'] | Should Be $false
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $true
    }

    It 'surfaces (rather than swallows) a failed physical rollback after a preference-persist failure' {
        $root = Join-Path $FixtureRoot 'park-pref-off-persist-fails-rollback-also-fails'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        # The forward restore (Disabled->Auto) succeeds; the persist then fails via the test hook; the
        # physical rollback re-park (Auto->Disabled) is made to fail too, so nothing can silently claim
        # the service and record are back in agreement.
        $originalSetMode = $fixture.Adapter.SetServiceStartMode
        $fixture.Adapter.SetServiceStartMode = {
            param($name, $expected, $desired)
            if ($expected -eq 'Auto' -and $desired -eq 'Disabled') {
                throw 'Simulated rollback failure: cannot re-disable service.'
            }
            & $originalSetMode $name $expected $desired
        }.GetNewClosure()

        $hook = { throw 'simulated persistence failure immediately before commit' }
        $errorRecord = $null
        try {
            Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key $key -ParkWhenIdle $false -DataRoot $root `
                -Adapter $fixture.Adapter -TestHookBeforeCommit $hook
        } catch { $errorRecord = $_ }

        $errorRecord | Should Not Be $null
        $errorRecord.Exception.Message | Should Match 'FixtureSvcA'
        $errorRecord.Exception.Message | Should Match 'rollback'

        # The service is now physically un-parked (start mode restored to Auto) but the rollback to
        # re-disable it failed - the persisted record on disk (never touched by this failed attempt)
        # must still be visible for what it is, not silently reported as consistent by the error alone.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
    }
}

Describe 'LeanLaunch service idle-parking activation' {
    It 'parks only the services explicitly opted in, recording the original start mode' {
        $root = Join-Path $FixtureRoot 'park-activate-basic'
        $optedInKey = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        # A second Managed service in the same audit that never opted in must never be touched.
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }

        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $fixture.State.Calls -contains 'Get:FixtureSvcA' | Should Be $true
        $fixture.State.Calls -contains 'Set:FixtureSvcA:Auto->Disabled' | Should Be $true
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'

        $saved = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $entry = @($saved.parkedServices) | Where-Object { $_.name -eq 'FixtureSvcA' } | Select-Object -First 1
        $entry | Should Not Be $null
        $entry.originalStartMode | Should Be 'Auto'
        $entry.currentlyParked | Should Be $true
    }

    It 'never touches a Managed service that did not opt in to parking' {
        $root = Join-Path $FixtureRoot 'park-activate-optout'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='NoParkSvc';DisplayName='NoPark';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|noparksvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ NoParkSvc = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $fixture.State.Calls.Count | Should Be 0
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).parkedServices.Count | Should Be 0
    }

    It 'is idempotent: re-activating an already-parked service does not park it twice' {
        $root = Join-Path $FixtureRoot 'park-activate-idempotent'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        $setCallsAfterFirst = @($fixture.State.Calls | Where-Object { $_ -like 'Set:*' }).Count

        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Unmanaged' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        # Re-park after going Unmanaged and back to Managed - the service was fully restored in
        # between, so this is a fresh park, not a double-park of an already-disabled service.
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        @($fixture.State.Calls | Where-Object { $_ -like 'Set:*Disabled' }).Count | Should Be 2
    }

    It 'fails closed without elevation and leaves no parked-service record behind' {
        $root = Join-Path $FixtureRoot 'park-activate-not-elevated'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -IsAdministrator $false

        { Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false } | Should Throw

        $fixture.State.Calls.Count | Should Be 0
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        @($application.parkedServices).Count | Should Be 0
    }

    It 'rolls back every service parked earlier in a failed activation batch' {
        $root = Join-Path $FixtureRoot 'park-activate-rollback'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @(
                [pscustomobject]@{Name='FixtureSvcA';DisplayName='A';State='Running';StartMode='Automatic';ProcessId=10},
                [pscustomobject]@{Name='FixtureSvcB';DisplayName='B';State='Running';StartMode='Automatic';ProcessId=11}
            ) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvca' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvcb' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvca' -ParkWhenIdle $true -DataRoot $root | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvcb' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        # FixtureSvcA can be parked; FixtureSvcB has no recorded mode, so its GetServiceStartMode
        # (and therefore the whole activation batch) fails partway through.
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false } | Should Throw

        # FixtureSvcA must have been restored (parked, then rolled back) rather than left disabled
        # with no persisted record - an Unmanaged-looking application must never have a disabled
        # service silently left behind by a failed attempt to go Managed.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        @($application.parkedServices | Where-Object { $_.currentlyParked }).Count | Should Be 0
    }

    It 'aggregates and surfaces (rather than swallows) failed rollbacks across a multi-service failed activation batch' {
        $root = Join-Path $FixtureRoot 'park-activate-rollback-also-fails'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @(
                [pscustomobject]@{Name='FixtureSvcA';DisplayName='A';State='Running';StartMode='Automatic';ProcessId=10},
                [pscustomobject]@{Name='FixtureSvcB';DisplayName='B';State='Running';StartMode='Automatic';ProcessId=11},
                [pscustomobject]@{Name='FixtureSvcC';DisplayName='C';State='Running';StartMode='Automatic';ProcessId=12}
            ) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvca' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvcb' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvcc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvca' -ParkWhenIdle $true -DataRoot $root | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvcb' -ParkWhenIdle $true -DataRoot $root | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvcc' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        # FixtureSvcA and FixtureSvcB can both be parked; FixtureSvcC has no recorded mode, so its
        # GetServiceStartMode fails and the whole activation batch rolls back A and B.
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto'; FixtureSvcB = 'Auto' }
        $originalSetMode = $fixture.Adapter.SetServiceStartMode
        $fixture.Adapter.SetServiceStartMode = {
            param($name, $expected, $desired)
            if ($name -eq 'FixtureSvcA' -and $expected -eq 'Disabled' -and $desired -eq 'Auto') {
                throw 'Simulated rollback failure: cannot restore FixtureSvcA.'
            }
            & $originalSetMode $name $expected $desired
        }.GetNewClosure()

        $errorRecord = $null
        try {
            Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        } catch { $errorRecord = $_ }

        $errorRecord | Should Not Be $null
        $errorRecord.Exception.Message | Should Match 'FixtureSvcA'

        # FixtureSvcA's rollback failed - it must still be left Disabled (physically still parked),
        # never falsely reported as safely restored.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
        # FixtureSvcB's rollback must still have been attempted (the loop continues past A's failure)
        # and must have succeeded normally.
        $fixture.State.Modes['FixtureSvcB'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
    }

    It 'stops a running service through the identity-bound stop before disabling it' {
        $root = Join-Path $FixtureRoot 'park-activate-stops-running'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true }

        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $calls = @($fixture.State.Calls)
        $stopCall = $calls | Where-Object { $_ -like 'StopService:FixtureSvcA:*' } | Select-Object -First 1
        $stopCall | Should Not Be $null
        $stopIndex = [array]::IndexOf($calls, $stopCall)
        $disableIndex = [array]::IndexOf($calls, 'Set:FixtureSvcA:Auto->Disabled')
        $disableIndex | Should BeGreaterThan $stopIndex
        $fixture.State.Running['FixtureSvcA'] | Should Be $false
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'

        $saved = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $entry = @($saved.parkedServices) | Where-Object { $_.name -eq 'FixtureSvcA' } | Select-Object -First 1
        $entry.originalWasRunning | Should Be $true
    }

    It 'refuses to park (and changes nothing) when the identity-bound stop of a running service fails' {
        $root = Join-Path $FixtureRoot 'park-activate-stop-refused'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true } -RefuseStopFor @('FixtureSvcA')

        { Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false } | Should Throw

        # The stop was refused, so the service must never have been disabled - it is still running
        # with its original start mode, exactly as it was before this failed attempt.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $fixture.State.Running['FixtureSvcA'] | Should Be $true
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
    }

    It 'restarts a running service it already stopped when a later service in the same activation batch fails' {
        $root = Join-Path $FixtureRoot 'park-activate-rollback-restart'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @(
                [pscustomobject]@{Name='FixtureSvcA';DisplayName='A';State='Running';StartMode='Automatic';ProcessId=10},
                [pscustomobject]@{Name='FixtureSvcB';DisplayName='B';State='Running';StartMode='Automatic';ProcessId=11}
            ) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvca' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvcb' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvca' -ParkWhenIdle $true -DataRoot $root | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvcb' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        # FixtureSvcA is running and gets stopped+disabled; FixtureSvcB has no recorded mode, so its
        # GetServiceStartMode fails and the whole activation batch rolls back.
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true }
        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false } | Should Throw

        # Rollback must restore FixtureSvcA's FULL original state - running, not merely re-enabled -
        # since parking had already stopped it before FixtureSvcB's failure was discovered.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $fixture.State.Running['FixtureSvcA'] | Should Be $true
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        @($application.parkedServices | Where-Object { $_.currentlyParked }).Count | Should Be 0
    }

    It 'physically unparks every newly-parked service when persistence fails after activation itself succeeded (no disk/physical disagreement)' {
        $root = Join-Path $FixtureRoot 'park-activate-persist-fails'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true }

        $hook = { throw 'simulated persistence failure immediately before commit' }
        { Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false -TestHookBeforeCommit $hook } | Should Throw

        # Activation itself fully succeeded (service stopped and disabled) before the save failed - the
        # disk record still says Unmanaged (the save never landed), so the service must be fully
        # restored (running again, start mode back to original) rather than left disabled/stopped with
        # no persisted record of why.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $fixture.State.Running['FixtureSvcA'] | Should Be $true
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        @($application.parkedServices | Where-Object { $_.currentlyParked }).Count | Should Be 0
    }

    It 'surfaces (rather than swallows) a failed rollback when the Managed-activation save fails after services were physically parked' {
        $root = Join-Path $FixtureRoot 'park-activate-persist-fails-rollback-also-fails'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true }
        # The forward park (Auto->Disabled) succeeds; the persist then fails via the test hook; the
        # rollback's attempt to restore FixtureSvcA (Disabled->Auto) is made to fail too, so a stopped
        # and disabled service can never be silently left behind with only a generic error message.
        $originalSetMode = $fixture.Adapter.SetServiceStartMode
        $fixture.Adapter.SetServiceStartMode = {
            param($name, $expected, $desired)
            if ($expected -eq 'Disabled' -and $desired -eq 'Auto') {
                throw 'Simulated rollback failure: cannot restore service.'
            }
            & $originalSetMode $name $expected $desired
        }.GetNewClosure()

        $hook = { throw 'simulated persistence failure immediately before commit' }
        $errorRecord = $null
        try {
            Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false -TestHookBeforeCommit $hook | Out-Null
        } catch { $errorRecord = $_ }

        $errorRecord | Should Not Be $null
        $errorRecord.Exception.Message | Should Match 'FixtureSvcA'
        $errorRecord.Exception.Message | Should Match 'simulated persistence failure'

        # Rollback could not actually restore the service - it is still disabled/stopped even though
        # the disk record says Unmanaged. This divergence must be surfaced, not silently discarded
        # behind only the original persistence-failure message.
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
    }

    It 'refuses the Managed activation save via expected-content CAS when the record was changed concurrently, and physically unparks again' {
        $root = Join-Path $FixtureRoot 'park-activate-cas-concurrent'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        $appPath = Join-Path (Join-Path $root 'apps') 'parkapp.json'

        # A genuinely concurrent external writer (not a throwing hook) replaces the record after this
        # call's own read but before its commit - Save-LeanLaunchApplication's own CAS check (not the
        # test) must be what detects and refuses this.
        $hook = {
            $externallyChanged = Get-Content -LiteralPath $appPath -Raw | ConvertFrom-Json
            $externallyChanged.displayName = 'changed-out-from-under-activation'
            $externallyChanged | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $appPath -Encoding UTF8
        }.GetNewClosure()

        { Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false -TestHookBeforeCommit $hook } | Should Throw

        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        $application.displayName | Should Be 'changed-out-from-under-activation'
        @($application.parkedServices | Where-Object { $_.currentlyParked }).Count | Should Be 0
    }
}

Describe 'LeanLaunch service idle-parking deactivation and invalidation' {
    It 'rejects a concurrent application-record update against the original deactivation baseline and re-parks the service' {
        $root = Join-Path $FixtureRoot 'park-deactivate-cas-original-baseline'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        $appPath = Join-Path (Join-Path $root 'apps') 'parkapp.json'
        $originalSetMode = $fixture.Adapter.SetServiceStartMode
        $injection = @{ Done = $false }
        $fixture.Adapter.SetServiceStartMode = {
            param($name, $expected, $desired)
            if (-not $injection.Done -and $expected -eq 'Disabled' -and $desired -eq 'Auto') {
                $injection.Done = $true
                $external = Get-Content -LiteralPath $appPath -Raw | ConvertFrom-Json
                $external.displayName = 'concurrent-deactivation-writer'
                $external | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $appPath -Encoding UTF8
            }
            & $originalSetMode $name $expected $desired
        }.GetNewClosure()

        { Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Unmanaged' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false } | Should Throw

        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.displayName | Should Be 'concurrent-deactivation-writer'
        $application.policy | Should Be 'Managed'
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $true
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
    }

    It 'fully restores a parked service on an explicit switch to Unmanaged' {
        $root = Join-Path $FixtureRoot 'park-deactivate-explicit'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Unmanaged' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $fixture.State.Calls -contains 'Set:FixtureSvcA:Disabled->Auto' | Should Be $true
        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'restarts a service that was running before parking stopped it, when the application returns to Unmanaged' {
        $root = Join-Path $FixtureRoot 'park-deactivate-restarts-running'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' } -Running @{ FixtureSvcA = $true }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null
        $fixture.State.Running['FixtureSvcA'] | Should Be $false

        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Unmanaged' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $fixture.State.Running['FixtureSvcA'] | Should Be $true
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'restores a parked service when a new before-install baseline invalidates the profile' {
        $root = Join-Path $FixtureRoot 'park-deactivate-rebaseline'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'parkapp' -DataRoot $root -Collectors $emptyCollectors -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'restores a parked service when reclassifying a decision invalidates the bound profile' {
        $root = Join-Path $FixtureRoot 'park-deactivate-reclassify'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        Set-LeanLaunchResourceClassification -Name 'parkapp' -Key $key -Decision 'Unmanaged' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $fixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'persists each successful restore immediately so a later drifted service cannot roll back an already-restored one' {
        $root = Join-Path $FixtureRoot 'park-deactivate-partial'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @(
                [pscustomobject]@{Name='FixtureSvcA';DisplayName='A';State='Running';StartMode='Automatic';ProcessId=10},
                [pscustomobject]@{Name='FixtureSvcB';DisplayName='B';State='Running';StartMode='Automatic';ProcessId=11}
            ) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvca' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvcb' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvca' -ParkWhenIdle $true -DataRoot $root | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvcb' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto'; FixtureSvcB = 'Manual' }
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        # Drift FixtureSvcB's mode out from under LeanLaunch's persisted record (simulating an
        # external change) so its restore during deactivation fails partway through the batch.
        $fixture.State.Modes['FixtureSvcB'] = 'Boot'

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Unmanaged' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false } | Should Throw

        # FixtureSvcA's restore succeeded and must be persisted to disk even though the batch as a
        # whole threw on FixtureSvcB.
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcB' }).currentlyParked | Should Be $true
    }
}

Describe 'LeanLaunch service idle-parking per-run temporary restore' {
    It 'temporarily restores a parked service for the run and re-parks it after the run completes' {
        $root = Join-Path $FixtureRoot 'park-run-restore'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null
        $activationFixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled' }
        $run = Invoke-LeanLaunchApplicationRun -Name 'parkapp' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter
        $run.status | Should Be 'Completed'

        $calls = @($runFixture.State.Calls)
        $restoreIndex = [array]::IndexOf($calls, 'Set:FixtureSvcA:Disabled->Auto')
        $startIndex = [array]::IndexOf($calls, 'StartProcess')
        $reparkIndex = [array]::IndexOf($calls, 'Set:FixtureSvcA:Auto->Disabled')
        $restoreIndex | Should BeGreaterThan -1
        $startIndex | Should BeGreaterThan $restoreIndex
        $reparkIndex | Should BeGreaterThan $startIndex

        # The run-scoped loan never changes the persisted parked-state - the service is still
        # recorded as parked (Managed's normal resting state), just temporarily on loan mid-run.
        $runFixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $true
    }

    It 'still re-parks the service even when the managed run itself fails' {
        $root = Join-Path $FixtureRoot 'park-run-restore-failure'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled' } -FailStartProcess $true
        { Invoke-LeanLaunchApplicationRun -Name 'parkapp' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter } | Should Throw

        $runFixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
        $calls = @($runFixture.State.Calls)
        $calls -contains 'Set:FixtureSvcA:Auto->Disabled' | Should Be $true
    }

    It 'never leaves a temporarily-restored parked service running-but-Disabled when the run uses -KeepServices' {
        $root = Join-Path $FixtureRoot 'park-run-restore-keepservices'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled' }
        $run = Invoke-LeanLaunchApplicationRun -Name 'parkapp' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter -KeepServices
        $run.status | Should Be 'Completed'

        # -KeepServices means the profile's own cleanup never stops FixtureSvcA, so it is still
        # running when the run-scoped loan would otherwise be returned. Re-parking (disabling) it now
        # would strand a live service in a start mode that can never restart it, so it must be left at
        # the temporarily-restored (original, running-capable) start mode instead.
        $runFixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $runFixture.State.Running['FixtureSvcA'] | Should Be $true
        $run.unparkedAfterRunServices -contains 'FixtureSvcA' | Should Be $true

        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'never leaves a temporarily-restored parked service running-but-Disabled when the run uses -NoCleanup' {
        $root = Join-Path $FixtureRoot 'park-run-restore-nocleanup'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled' }
        $run = Invoke-LeanLaunchApplicationRun -Name 'parkapp' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter -NoCleanup
        $run.status | Should Be 'Completed'

        $runFixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $runFixture.State.Running['FixtureSvcA'] | Should Be $true
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'never leaves a temporarily-restored parked service running-but-Disabled when its own stop fails during cleanup' {
        $root = Join-Path $FixtureRoot 'park-run-restore-stopfails'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled' } -FailStopServiceFor @('FixtureSvcA')
        $run = Invoke-LeanLaunchApplicationRun -Name 'parkapp' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter
        $run.status | Should Be 'CleanupIncomplete'

        $runFixture.State.Modes['FixtureSvcA'] | Should Be 'Auto'
        $runFixture.State.Running['FixtureSvcA'] | Should Be $true
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'does not launch the application and re-parks whatever it already restored when a second parked service has drifted' {
        $root = Join-Path $FixtureRoot 'park-run-restore-partial'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @(
                [pscustomobject]@{Name='FixtureSvcA';DisplayName='A';State='Running';StartMode='Automatic';ProcessId=10},
                [pscustomobject]@{Name='FixtureSvcB';DisplayName='B';State='Running';StartMode='Automatic';ProcessId=11}
            ) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvca' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvcb' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvca' -ParkWhenIdle $true -DataRoot $root | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvcb' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto'; FixtureSvcB = 'Manual' }
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled'; FixtureSvcB = 'Disabled' }
        # Drift FixtureSvcB's mode after activation but before the run, so the run-scoped temporary
        # restore for FixtureSvcB fails partway through the two-service restore batch.
        $runFixture.State.Modes['FixtureSvcB'] = 'Boot'

        { Invoke-LeanLaunchApplicationRun -Name 'demo' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter } | Should Throw

        $calls = @($runFixture.State.Calls)
        $calls -contains 'StartProcess' | Should Be $false
        # FixtureSvcA was successfully restored before the batch hit FixtureSvcB's drift - it must
        # have been re-parked rather than left temporarily un-parked with no process ever launched.
        $calls -contains 'Set:FixtureSvcA:Auto->Disabled' | Should Be $true
        $runFixture.State.Modes['FixtureSvcA'] | Should Be 'Disabled'
    }

    It 'never overwrites a concurrent application-record change made during the run when persisting the finalizer unpark' {
        $root = Join-Path $FixtureRoot 'park-run-finalize-concurrent-overwrite'
        New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA' | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled' }
        $appPath = Join-Path (Join-Path $root 'apps') 'parkapp.json'
        # Fires mid-run (StartProcess happens well before the finalizer's own read/save), simulating a
        # concurrent classification/display-name edit landing while the finalizer's pre-run read of
        # the application record is still stale in memory.
        $runFixture.Adapter.StartProcess = {
            param($executable, $arguments, $workingDirectory)
            $concurrent = Get-Content -LiteralPath $appPath -Raw | ConvertFrom-Json
            $concurrent.displayName = 'changed-concurrently-during-run'
            $concurrent | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $appPath -Encoding UTF8
            [pscustomobject]@{ Id = 4242; Name = 'parkapp'; CreationDate = 'main' }
        }.GetNewClosure()

        # -KeepServices forces the finalizer to actually persist an unparked-state change (FixtureSvcA
        # stays running), which is exactly the save that must never resurrect the stale displayName.
        $run = Invoke-LeanLaunchApplicationRun -Name 'parkapp' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter -KeepServices
        $run.status | Should Be 'Completed'

        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.displayName | Should Be 'changed-concurrently-during-run'
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcA' }).currentlyParked | Should Be $false
    }

    It 'continues re-parking remaining services and still persists their unparked state when one service fails to re-park' {
        $root = Join-Path $FixtureRoot 'park-run-finalize-partial-failure'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchParkingTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @(
                [pscustomobject]@{Name='FixtureSvcA';DisplayName='A';State='Running';StartMode='Automatic';ProcessId=10},
                [pscustomobject]@{Name='FixtureSvcB';DisplayName='B';State='Running';StartMode='Automatic';ProcessId=11}
            ) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvca' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|fixturesvcb' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvca' -ParkWhenIdle $true -DataRoot $root | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'demo' -Key 'Service|fixturesvcb' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        $activationFixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto'; FixtureSvcB = 'Manual' }
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Adapter $activationFixture.Adapter -Confirm:$false | Out-Null

        $runFixture = New-LeanLaunchParkingRunAdapter -Modes @{ FixtureSvcA = 'Disabled'; FixtureSvcB = 'Disabled' } -FailStopServiceFor @('FixtureSvcB')
        # Drift FixtureSvcA's live start mode mid-run (after its own run-scoped restore already
        # succeeded) so its re-park at the end of the run fails, while FixtureSvcB is separately left
        # running (its own cleanup stop fails) and must still have its unparked state persisted despite
        # FixtureSvcA's failure.
        $runFixture.Adapter.StartProcess = {
            param($executable, $arguments, $workingDirectory)
            $runFixture.State.Modes['FixtureSvcA'] = 'Manual'
            [pscustomobject]@{ Id = 4242; Name = 'demo'; CreationDate = 'main' }
        }.GetNewClosure()

        $errorRecord = $null
        try {
            Invoke-LeanLaunchApplicationRun -Name 'demo' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $runFixture.Adapter | Out-Null
        } catch { $errorRecord = $_ }

        $errorRecord | Should Not Be $null
        $errorRecord.Exception.Message | Should Match 'FixtureSvcA'

        # FixtureSvcB's unparked state must still be persisted even though FixtureSvcA's re-park failed
        # and the loop must not have aborted before ever reaching it.
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        ($application.parkedServices | Where-Object { $_.name -eq 'FixtureSvcB' }).currentlyParked | Should Be $false
    }
}

Describe 'LeanLaunch classification rows report live parked state distinct from preference' {
    It 'reports currentlyParked as false while parkWhenIdle is true before activation ever runs' {
        $root = Join-Path $FixtureRoot 'park-rows-live-vs-preference-before'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $row = (Get-LeanLaunchClassificationRows -Application $application) | Where-Object { $_.key -eq $key }
        $row.parkWhenIdle | Should Be $true
        $row.currentlyParked | Should Be $false
    }

    It 'reports currentlyParked as true only after policy activation actually parks the service' {
        $root = Join-Path $FixtureRoot 'park-rows-live-vs-preference-after'
        $key = New-LeanLaunchParkedFixture -Root $root -ServiceName 'FixtureSvcA'
        $fixture = New-LeanLaunchParkingFixtureAdapter -Modes @{ FixtureSvcA = 'Auto' }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixture.Adapter -Confirm:$false | Out-Null

        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $row = (Get-LeanLaunchClassificationRows -Application $application) | Where-Object { $_.key -eq $key }
        $row.parkWhenIdle | Should Be $true
        $row.currentlyParked | Should Be $true
    }

    It 'reports currentlyParked as false for a non-Service resource type regardless of any name collision' {
        $rows = Get-LeanLaunchClassificationRows -Application ([pscustomobject]@{
            currentAudit = [pscustomobject]@{ classifications = @(
                [pscustomobject]@{ key='StartupEntry|hkcu|x'; resourceType='StartupEntry'; name='FixtureSvcA'; path='x.exe'; evidence='e'; decision='Reviewed'; note='' }
            ) }
            parkedServices = @([pscustomobject]@{ name='FixtureSvcA'; originalStartMode='Auto'; parkedAtUtc='x'; currentlyParked=$true })
        })
        $rows[0].currentlyParked | Should Be $false
    }
}
