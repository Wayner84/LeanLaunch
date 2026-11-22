. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'LeanLaunch managed run lifecycle' {
    It 'dry-run plans actions without invoking adapters' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'
            services=@('StoppedSvc','RunningSvc'); residualProcesses=@(); waitForProcessNames=@()
            cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $adapter = @{
            GetService = { param($name) [void]$calls.Add("get:$name"); [pscustomobject]@{Name=$name;State=if($name -eq 'RunningSvc'){'Running'}else{'Stopped'}} }
            StartService = { param($name) [void]$calls.Add("start:$name") }
            StopService = { param($name) [void]$calls.Add("stop:$name") }
            GetProcesses = { @() }
            StartProcess = { [void]$calls.Add('process') }
            WaitProcess = { }
            StopProcess = { }
        }
        $result = Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter -DryRun
        $result.plan.servicesToStart | Should Be @('StoppedSvc')
        $calls.Count | Should Be 2
    }

    It 'stops only services that this run started' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'
            services=@('StoppedSvc','RunningSvc'); residualProcesses=@(); waitForProcessNames=@()
            cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:stoppedSvcReads = 0
        $adapter = @{
            GetService = {
                param($name)
                if($name -eq 'RunningSvc'){ return [pscustomobject]@{Name=$name;Status='Running';ProcessId=600} }
                $script:stoppedSvcReads++
                if($script:stoppedSvcReads -le 2){[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}
                else{[pscustomobject]@{Name=$name;Status='Running';ProcessId=700}}
            }
            StartService = { param($name) [void]$calls.Add("start:$name"); return $true }
            StopService = { param($name) [void]$calls.Add("stop:$name") }
            GetProcesses = { @() }
            StartProcess = { [void]$calls.Add('launch'); [pscustomobject]@{Id=99;Name='demo'} }
            WaitProcess = { param($process) [void]$calls.Add("wait:$($process.Id)") }
            StopProcess = { }
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'start:StoppedSvc' | Should Be $true
        $calls -contains 'stop:StoppedSvc' | Should Be $true
        $calls -contains 'stop:RunningSvc' | Should Be $false
    }

    It 'does not own a service started externally after planning' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('RaceSvc')
            residualProcesses=@(); waitForProcessNames=@(); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:serviceReads = 0
        $adapter = @{
            GetService={param($name) $script:serviceReads++; [pscustomobject]@{Name=$name;Status=if($script:serviceReads -eq 1){'Stopped'}else{'Running'};ProcessId=700}}
            StartService={param($name)[void]$calls.Add("start:$name")}; StopService={param($name)[void]$calls.Add("stop:$name")}
            GetProcesses={@()}; StartProcess={[pscustomobject]@{Id=99;Name='demo'}}; WaitProcess={}; StopProcess={}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'start:RaceSvc' | Should Be $false
        $calls -contains 'stop:RaceSvc' | Should Be $false
    }

    It 'does not stop a service when the start adapter did not prove ownership' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('RaceSvc')
            residualProcesses=@(); waitForProcessNames=@(); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:serviceReads = 0
        $adapter = @{
            GetService={param($name) $script:serviceReads++; if($script:serviceReads -le 2){[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}else{[pscustomobject]@{Name=$name;Status='Running';ProcessId=700}}}
            StartService={param($name)[void]$calls.Add("start:$name"); return $false}
            StopService={param($name)[void]$calls.Add("stop:$name")}
            GetProcesses={@()}; StartProcess={[pscustomobject]@{Id=99;Name='demo'}}; WaitProcess={}; StopProcess={}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'start:RaceSvc' | Should Be $true
        $calls -contains 'stop:RaceSvc' | Should Be $false
    }

    It 'does not stop a service whose started instance was replaced' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('RaceSvc')
            residualProcesses=@(); waitForProcessNames=@(); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:serviceReads = 0
        $adapter = @{
            GetService={
                param($name) $script:serviceReads++
                if($script:serviceReads -le 2){[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}
                elseif($script:serviceReads -eq 3){[pscustomobject]@{Name=$name;Status='Running';ProcessId=700}}
                else{[pscustomobject]@{Name=$name;Status='Running';ProcessId=701}}
            }
            StartService={param($name)[void]$calls.Add("start:$name"); return $true}; StopService={param($name)[void]$calls.Add("stop:$name")}
            GetProcesses={@()}; StartProcess={[pscustomobject]@{Id=99;Name='demo'}}; WaitProcess={}; StopProcess={}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'start:RaceSvc' | Should Be $true
        $calls -contains 'stop:RaceSvc' | Should Be $false
    }

    It 'binds service cleanup to the native process creation identity recorded when this run started the service' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('OwnedSvc')
            residualProcesses=@(); waitForProcessNames=@(); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:ownedSvcReads = 0
        $adapter = @{
            GetService={
                param($name) $script:ownedSvcReads++
                if($script:ownedSvcReads -le 2){[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}
                else{[pscustomobject]@{Name=$name;Status='Running';ProcessId=555}}
            }
            GetProcessCreationTime={ param($processId) [void]$calls.Add("creation:$processId"); 987654321 }
            StartService={param($name)[void]$calls.Add("start:$name"); return $true}
            StopService={param($name,$expectedProcessId,$expectedCreationTime)[void]$calls.Add("stop:${name}:${expectedProcessId}:${expectedCreationTime}")}
            GetProcesses={@()}; StartProcess={[pscustomobject]@{Id=99;Name='demo'}}; WaitProcess={}; StopProcess={}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'creation:555' | Should Be $true
        $calls -contains 'stop:OwnedSvc:555:987654321' | Should Be $true
    }

    It 'refuses to stop a service when the adapter cannot supply a process creation identity' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('NoIdentitySvc')
            residualProcesses=@(); waitForProcessNames=@(); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $script:noIdentitySvcReads = 0
        $adapter = @{
            GetService={
                param($name) $script:noIdentitySvcReads++
                if($script:noIdentitySvcReads -le 2){[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}
                else{[pscustomobject]@{Name=$name;Status='Running';ProcessId=556}}
            }
            # No GetProcessCreationTime key at all - Get-LeanLaunchAdapterProcessCreationTime must
            # degrade to 0 rather than throw, and the real native stop call fails closed on that.
            StartService={param($name) return $true}
            StopService={param($name,$expectedProcessId,$expectedCreationTime) if ($expectedCreationTime -le 0) { throw 'A native process creation identity is required.' } }
            GetProcesses={@()}; StartProcess={[pscustomobject]@{Id=99;Name='demo'}}; WaitProcess={}; StopProcess={}
        }
        $result = Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter
        $result.status | Should Be 'CleanupIncomplete'
        $result.cleanupErrors[0].message | Should Match 'creation identity'
    }

    It 'aborts the launch without starting the process when a required service never reaches Running' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('StuckSvc')
            residualProcesses=@(); waitForProcessNames=@(); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:stuckSvcReads = 0
        $adapter = @{
            # Call 1: New-LeanLaunchRunPlan sees it stopped, so it is queued to start.
            # Call 2: the immediate re-check in the start loop, still stopped.
            # Call 3: the post-StartService re-check - stays Stopped, so the started service never
            # actually reaches Running even though the adapter claims it started successfully.
            GetService = { param($name) $script:stuckSvcReads++; [pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0} }
            StartService = { param($name) [void]$calls.Add("start:$name"); return $true }
            StopService = { param($name) [void]$calls.Add("stop:$name") }
            GetProcesses = { @() }
            StartProcess = { [void]$calls.Add('process'); [pscustomobject]@{Id=99;Name='demo'} }
            WaitProcess = { }
            StopProcess = { }
        }
        $message = ''
        try { Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null }
        catch { $message = $_.Exception.Message }
        $message | Should Match "Required service 'StuckSvc' did not reach the Running state"
        $calls -contains 'start:StuckSvc' | Should Be $true
        $calls -contains 'process' | Should Be $false
        $calls -contains 'stop:StuckSvc' | Should Be $false
    }

    It 'fails with actionable guidance when service control is not elevated' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('AdminSvc')
            residualProcesses=@(); waitForProcessNames=@(); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $adapter = @{
            IsAdministrator={ $false }; GetService={param($name)[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}
            StartService={}; StopService={}; GetProcesses={@()}; StartProcess={[pscustomobject]@{Id=99}}; WaitProcess={}; StopProcess={}
        }
        $message = ''
        try { Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'administrator rights'
        $message | Should Match 'Run PowerShell as Administrator'
    }

    It 'passes a flat argument array to the process adapter' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@('--first','two words'); workingDirectory='C:\'
            services=@(); residualProcesses=@(); waitForProcessNames=@()
            cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $script:capturedArguments = $null
        $adapter = @{
            GetService={}; StartService={}; StopService={}; GetProcesses={@()}
            StartProcess={param($exe,$arguments,$workingDirectory) $script:capturedArguments=$arguments; [pscustomobject]@{Id=99;Name='demo'}}
            WaitProcess={}; StopProcess={}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $script:capturedArguments.Count | Should Be 2
        $script:capturedArguments[1] | Should Be 'two words'
    }

    It 'quotes Windows PowerShell 5.1 process arguments without losing quotes or trailing backslashes' {
        ConvertTo-LeanLaunchArgumentString @('plain','two words','say"hello','C:\path with space\','') |
            Should Be 'plain "two words" "say\"hello" "C:\path with space\\" ""'
    }

    It 'continues service cleanup when residual process cleanup fails' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'
            services=@('StoppedSvc'); waitForProcessNames=@()
            residualProcesses=@([pscustomobject]@{name='helper';executablePath='C:\Vendor\helper.exe'})
            cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:processReads = 0
        $script:cleanupSvcReads = 0
        $adapter = @{
            GetService={param($name) $script:cleanupSvcReads++; if($script:cleanupSvcReads -le 2){[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}else{[pscustomobject]@{Name=$name;Status='Running';ProcessId=700}}}
            StartService={param($name)[void]$calls.Add("start:$name"); return $true}
            StopService={param($name)[void]$calls.Add("stop:$name")}
            GetProcesses={ $script:processReads++; if($script:processReads -eq 1){@()}else{@([pscustomobject]@{Id=2;Name='helper';Path='C:\Vendor\helper.exe';ParentId=99;CreationDate='child'})} }
            StartProcess={ [pscustomobject]@{Id=99;Name='demo';CreationDate='main'} }; WaitProcess={}
            StopProcess={param($process) throw 'simulated access denied'}
        }
        $script:processReads = 0
        $result = Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter
        $calls -contains 'stop:StoppedSvc' | Should Be $true
        $result.status | Should Be 'CleanupIncomplete'
        $result.cleanupErrors.Count | Should Be 1
    }

    It 'cleans only new residual processes matching configured name and path' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'
            services=@(); waitForProcessNames=@()
            residualProcesses=@([pscustomobject]@{name='helper';executablePath='C:\Vendor\helper.exe'})
            cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $processReads = 0
        $adapter = @{
            GetService = { }; StartService = { }; StopService = { }
            GetProcesses = {
                $script:processReads++
                if ($script:processReads -eq 1) { return @([pscustomobject]@{Id=1;Name='helper';Path='C:\Vendor\helper.exe'}) }
                return @(
                    [pscustomobject]@{Id=1;Name='helper';Path='C:\Vendor\helper.exe'},
                    [pscustomobject]@{Id=2;Name='helper';Path='C:\Vendor\helper.exe';ParentId=99;CreationDate='run-child'},
                    [pscustomobject]@{Id=3;Name='helper';Path='C:\Other\helper.exe'}
                )
            }
            StartProcess = { [pscustomobject]@{Id=99;Name='demo';CreationDate='main'} }
            WaitProcess = { }
            StopProcess = { param($process) [void]$calls.Add("kill:$($process.Id)") }
        }
        $script:processReads = 0
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'kill:2' | Should Be $true
        $calls -contains 'kill:1' | Should Be $false
        $calls -contains 'kill:3' | Should Be $false
    }

    It 'does not stop an unrelated post-baseline same-name process' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@(); waitForProcessNames=@()
            residualProcesses=@([pscustomobject]@{name='helper';executablePath='C:\Vendor\helper.exe'})
            cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:processReads = 0
        $adapter = @{
            GetService={}; StartService={}; StopService={}
            GetProcesses={
                $script:processReads++
                if($script:processReads -eq 1){ @() }
                else { @([pscustomobject]@{Id=40;Name='helper';Path='C:\Vendor\helper.exe';ParentId=777;CreationDate='unrelated'}) }
            }
            StartProcess={ [pscustomobject]@{Id=99;Name='demo';Path='C:\demo.exe';CreationDate='launch'} }
            WaitProcess={}; StopProcess={param($process)[void]$calls.Add("kill:$($process.Id)")}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'kill:40' | Should Be $false
    }

    It 'revalidates process creation identity immediately before stopping' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@(); waitForProcessNames=@()
            residualProcesses=@([pscustomobject]@{name='helper';executablePath='C:\Vendor\helper.exe'})
            cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:processReads = 0
        $adapter = @{
            GetService={}; StartService={}; StopService={}
            GetProcesses={
                $script:processReads++
                if($script:processReads -eq 1){ @() }
                elseif($script:processReads -eq 2){ @([pscustomobject]@{Id=40;Name='helper';Path='C:\Vendor\helper.exe';ParentId=99;CreationDate='original'}) }
                else { @([pscustomobject]@{Id=40;Name='helper';Path='C:\Vendor\helper.exe';ParentId=99;CreationDate='replacement'}) }
            }
            StartProcess={ [pscustomobject]@{Id=99;Name='demo';Path='C:\demo.exe';CreationDate='launch'} }
            WaitProcess={}; StopProcess={param($process)[void]$calls.Add("kill:$($process.Id)")}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'kill:40' | Should Be $false
    }

    It 'preserves services when an attributable child exceeds the wait timeout' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@('LongSvc'); residualProcesses=@()
            waitForProcessNames=@('worker'); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:longSvcReads = 0
        $script:longProcessReads = 0
        $adapter = @{
            GetService={param($name) $script:longSvcReads++; if($script:longSvcReads -le 2){[pscustomobject]@{Name=$name;Status='Stopped';ProcessId=0}}else{[pscustomobject]@{Name=$name;Status='Running';ProcessId=700}}}
            StartService={param($name)[void]$calls.Add("start:$name"); return $true}; StopService={param($name)[void]$calls.Add("stop:$name")}
            GetProcesses={ $script:longProcessReads++; if($script:longProcessReads -eq 1){@()}else{@([pscustomobject]@{Id=41;Name='worker';Path='C:\worker.exe';ParentId=99;CreationDate='child'})} }
            StartProcess={[pscustomobject]@{Id=99;Name='demo';CreationDate='main'}}; WaitProcess={}
            SleepMilliseconds={}
            WaitProcessBounded={param($process,$seconds)[void]$calls.Add("timeout:$($process.Id)"); return $false}; StopProcess={}
        }
        $result = Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter
        $result.status | Should Be 'WaitTimedOut'
        $calls -contains 'stop:LongSvc' | Should Be $false
    }

    It 'continues discovery long enough to include a second delayed attributable child' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@(); residualProcesses=@()
            waitForProcessNames=@('worker'); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:processReads = 0
        $adapter = @{
            GetService={}; StartService={}; StopService={}
            GetProcesses={
                $script:processReads++
                if($script:processReads -eq 1){ @() }
                elseif($script:processReads -eq 2){ @([pscustomobject]@{Id=41;Name='worker';Path='C:\Vendor\worker.exe';ParentId=99;CreationDate='child-one'}) }
                else { @(
                    [pscustomobject]@{Id=41;Name='worker';Path='C:\Vendor\worker.exe';ParentId=99;CreationDate='child-one'},
                    [pscustomobject]@{Id=42;Name='worker';Path='C:\Vendor\worker.exe';ParentId=99;CreationDate='child-two'}
                ) }
            }
            StartProcess={ [pscustomobject]@{Id=99;Name='demo';Path='C:\demo.exe';CreationDate='launch'} }
            WaitProcess={}
            SleepMilliseconds={}
            WaitProcessBounded={param($process,$seconds)[void]$calls.Add("bounded:$($process.Id)"); return $true}
            StopProcess={}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'bounded:41' | Should Be $true
        $calls -contains 'bounded:42' | Should Be $true
    }

    It 'waits only for attributable descendants with a bounded wait' {
        $profile = [pscustomobject]@{
            name='demo'; executable='C:\demo.exe'; arguments=@(); workingDirectory='C:\'; services=@(); residualProcesses=@()
            waitForProcessNames=@('worker'); cleanup=[pscustomobject]@{stopStartedServices=$true;stopResidualProcesses=$true}
        }
        $calls = New-Object System.Collections.ArrayList
        $script:processReads = 0
        $adapter = @{
            GetService={}; StartService={}; StopService={}
            GetProcesses={
                $script:processReads++
                if($script:processReads -eq 1){ @() }
                else { @(
                    [pscustomobject]@{Id=40;Name='worker';Path='C:\Vendor\worker.exe';ParentId=777;CreationDate='unrelated'},
                    [pscustomobject]@{Id=41;Name='worker';Path='C:\Vendor\worker.exe';ParentId=99;CreationDate='child'}
                ) }
            }
            StartProcess={ [pscustomobject]@{Id=99;Name='demo';Path='C:\demo.exe';CreationDate='launch'} }
            WaitProcess={param($process)[void]$calls.Add("main:$($process.Id)")}
            SleepMilliseconds={}
            WaitProcessBounded={param($process,$seconds)[void]$calls.Add("bounded:$($process.Id):$seconds")}
            StopProcess={}
        }
        Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter | Out-Null
        $calls -contains 'bounded:41:86400' | Should Be $true
        $calls -contains 'bounded:40:86400' | Should Be $false
    }
}

Describe 'LeanLaunch native process identity boundary' {
    It 'binds termination to the process handle and native creation time' {
        $module = Get-Module LeanLaunch
        $adapter = & $module { New-LeanLaunchDefaultAdapter }
        $executable = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child = & $adapter.StartProcess $executable @('-NoProfile','-Command','Start-Sleep -Seconds 30') $FixtureRoot
        try {
            $child.PSObject.Properties['CreationFileTimeUtc'] | Should Not Be $null
            [long]$child.CreationFileTimeUtc | Should BeGreaterThan 0
            $forged = [pscustomobject]@{
                Id = $child.Id
                CreationDate = $child.CreationDate
                CreationFileTimeUtc = ([long]$child.CreationFileTimeUtc + 1)
            }
            { & $adapter.StopProcess $forged } | Should Throw
            (Get-Process -Id $child.Id -ErrorAction SilentlyContinue) | Should Not Be $null

            & $adapter.StopProcess $child
            Start-Sleep -Milliseconds 100
            (Get-Process -Id $child.Id -ErrorAction SilentlyContinue) | Should Be $null
        }
        finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not treat a PID-reused process as the still-running main process' {
        $module = Get-Module LeanLaunch
        $adapter = & $module { New-LeanLaunchDefaultAdapter }
        $executable = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child = & $adapter.StartProcess $executable @('-NoProfile','-Command','Start-Sleep -Seconds 30') $FixtureRoot
        try {
            $forged = [pscustomobject]@{ Id = $child.Id; CreationFileTimeUtc = ([long]$child.CreationFileTimeUtc + 1) }
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            & $adapter.WaitProcess $forged
            $stopwatch.Stop()
            $stopwatch.Elapsed.TotalSeconds | Should BeLessThan 10
            (Get-Process -Id $child.Id -ErrorAction SilentlyContinue) | Should Not Be $null
        }
        finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'waits on the process handle bound to the native creation time until it exits' {
        $module = Get-Module LeanLaunch
        $adapter = & $module { New-LeanLaunchDefaultAdapter }
        $executable = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child = & $adapter.StartProcess $executable @('-NoProfile','-Command','Start-Sleep -Seconds 2') $FixtureRoot
        try {
            & $adapter.WaitProcess $child
            (Get-Process -Id $child.Id -ErrorAction SilentlyContinue) | Should Be $null
        }
        finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
