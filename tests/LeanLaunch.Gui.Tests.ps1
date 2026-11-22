. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $ProjectRoot 'src\LeanLaunch.Gui.ps1')

Describe 'LeanLaunch GUI data binding' {
    It 'parses the window XAML and exposes every control the event wiring depends on' {
        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        foreach ($name in @(
            'ApplicationList','NewAppButton','RefreshButton','AppNameText','AppExeText','PolicyCombo',
            'ApplyPolicyButton','WarningsList','DryRunButton','LaunchButton','PlanText',
            'ScanBeforeButton','ScanAfterButton','BuildProfileButton','AuditStatusText',
            'SelectedKeyText','SelectedEvidenceText','SelectedPathText','NoteBox','DecisionCombo',
            'SaveClassificationButton','ClassificationGrid','LogText','BusyIndicatorText',
            'ParkWhenIdleCheckBox','SaveParkingButton','CurrentlyParkedText'
        )) {
            $window.FindName($name) | Should Not Be $null
        }
    }

    It 'populates an empty application list without throwing' {
        $root = Join-Path $FixtureRoot 'gui-empty'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        { Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root } | Should Not Throw
        $window.FindName('ApplicationList').Items.Count | Should Be 0
        { Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $root } | Should Not Throw
        $window.FindName('AppNameText').Text | Should Be '(select an application)'
    }

    It 'binds a reviewed application, its warnings, and its classification grid' {
        $root = Join-Path $FixtureRoot 'gui-populated'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'office.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'office' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'office' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='ClickToRunSvc';DisplayName='Office';State='Running';StartMode='Automatic';ProcessId=999}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'office' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null

        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root -SelectName 'office'
        Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $root

        $window.FindName('ApplicationList').Items.Count | Should Be 1
        $window.FindName('AppNameText').Text | Should Be 'office'
        $window.FindName('AuditStatusText').Text | Should Match 'AwaitingReview'
        @($window.FindName('WarningsList').ItemsSource).Count | Should BeGreaterThan 0
        @($window.FindName('ClassificationGrid').ItemsSource).Count | Should Be 1
    }

    It 'exposes a path-bound classification grid column and shows the selected resource full path' {
        $root = Join-Path $FixtureRoot 'gui-path-column'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'pathapp.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'pathapp' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'pathapp' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $processPath = 'C:\Program Files\PathApp\pathapp.exe'
        $afterCollectors = @{
            Processes = { @([pscustomobject]@{Id=555;Name='pathapp';Path=$processPath;WorkingSet64=1000}) }
            Services = { @() }; Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'pathapp' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null

        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        $grid = $window.FindName('ClassificationGrid')
        @($grid.Columns | Where-Object { $_.Binding.Path.Path -eq 'path' }).Count | Should Be 1

        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root -SelectName 'pathapp'
        Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $root
        $rows = @($grid.ItemsSource)
        $rows.Count | Should Be 1
        $rows[0].path | Should Be $processPath

        Update-LeanLaunchGuiSelectedClassification -Window $window -Row $rows[0]
        $window.FindName('SelectedPathText').Text | Should Be $processPath
    }

    It 'exposes a read-only parked-status column reflecting the parkWhenIdle preference' {
        $root = Join-Path $FixtureRoot 'gui-parked-column'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'parkapp.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'parkapp' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'parkapp' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='ParkGuiSvc';DisplayName='ParkGuiSvc';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'parkapp' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'parkapp' -Key 'Service|parkguisvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key 'Service|parkguisvc' -ParkWhenIdle $true -DataRoot $root | Out-Null

        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        $grid = $window.FindName('ClassificationGrid')
        $parkedColumns = @($grid.Columns | Where-Object { $_.Binding.Path.Path -eq 'parkWhenIdle' })
        $parkedColumns.Count | Should Be 1
        $parkedColumns[0].GetType().Name | Should Be 'DataGridCheckBoxColumn'
        $liveColumns = @($grid.Columns | Where-Object { $_.Binding.Path.Path -eq 'currentlyParked' })
        $liveColumns.Count | Should Be 1
        $liveColumns[0].GetType().Name | Should Be 'DataGridCheckBoxColumn'

        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root -SelectName 'parkapp'
        Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $root
        $rows = @($grid.ItemsSource)
        $rows.Count | Should Be 1
        # The preference is on, but activation (Set-LeanLaunchApplicationPolicy -Policy Managed) has
        # never run, so the service is NOT actually parked yet - the live column must say so even
        # though the preference column says "on". A preference is never live state.
        $rows[0].parkWhenIdle | Should Be $true
        $rows[0].currentlyParked | Should Be $false

        Update-LeanLaunchGuiSelectedClassification -Window $window -Row $rows[0]
        $window.FindName('CurrentlyParkedText').Text | Should Match 'no'
        $window.FindName('ParkWhenIdleCheckBox').IsChecked | Should Be $true
        $window.FindName('ParkWhenIdleCheckBox').IsEnabled | Should Be $true
        $window.FindName('SaveParkingButton').IsEnabled | Should Be $true
    }

    It 'shows the classification grid''s live-parked column as true only after policy activation actually parks the service' {
        $root = Join-Path $FixtureRoot 'gui-parked-column-live'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'parkapp.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'parkapp' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'parkapp' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='ParkGuiSvc';DisplayName='ParkGuiSvc';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'parkapp' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'parkapp' -Key 'Service|parkguisvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key 'Service|parkguisvc' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'parkapp' -DataRoot $root -Confirm:$false | Out-Null

        $calls = New-Object System.Collections.ArrayList
        $modes = @{ ParkGuiSvc = 'Auto' }
        $fixtureAdapter = @{
            IsAdministrator = { $true }
            GetServiceStartMode = { param($n) [void]$calls.Add("Get:$n"); $modes[$n] }
            SetServiceStartMode = { param($n,$e,$new) [void]$calls.Add("Set:$n"); $modes[$n] = $new }
            GetService = { param($n) [pscustomobject]@{ Name=$n; Status='Stopped'; ProcessId=0 } }
        }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $fixtureAdapter -Confirm:$false | Out-Null

        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root -SelectName 'parkapp'
        Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $root
        $grid = $window.FindName('ClassificationGrid')
        $rows = @($grid.ItemsSource)
        $rows[0].parkWhenIdle | Should Be $true
        $rows[0].currentlyParked | Should Be $true

        Update-LeanLaunchGuiSelectedClassification -Window $window -Row $rows[0]
        $window.FindName('CurrentlyParkedText').Text | Should Match 'yes'
    }

    It 'launches a managed application through a separate supervisor instead of blocking the GUI thread' {
        $root = Join-Path $FixtureRoot 'gui-supervisor'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $env:WINDIR 'System32\whoami.exe'
        New-LeanLaunchApplication -Name 'managed-gui' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'managed-gui' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'managed-gui' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'managed-gui' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'managed-gui' -Policy Managed -DataRoot $root -Confirm:$false | Out-Null
        $script:launchCapture = $null
        $launcher = {
            param($filePath, $argumentList, $elevated, $logPath)
            $script:launchCapture = [pscustomobject]@{ FilePath=$filePath; Arguments=$argumentList; Elevated=$elevated; LogPath=$logPath }
            [pscustomobject]@{ Id = 4321 }
        }

        $result = Start-LeanLaunchGuiApplication -Name 'managed-gui' -DataRoot $root -RepositoryRoot $ProjectRoot -SupervisorLauncher $launcher
        $result.status | Should Be 'SupervisorStarted'
        $result.processId | Should Be 4321
        $script:launchCapture.FilePath | Should Match 'powershell\.exe$'
        $script:launchCapture.Arguments -contains '-EncodedCommand' | Should Be $true
        $script:launchCapture.LogPath | Should Match 'managed-gui'
    }

    It 'runs a scan without blocking, shows a busy indicator, and ignores a second concurrent scan attempt' {
        $root = Join-Path $FixtureRoot 'gui-slow-scan-immediate'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'slowapp.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'slowapp' -Executable $exe -DataRoot $root | Out-Null
        $slowCollectors = @{
            Processes = { Start-Sleep -Milliseconds 600; @() }
            Services = { @() }; Startup = { @() }; ScheduledTasks = { @() }
        }

        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root -SelectName 'slowapp'

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $handle = Start-LeanLaunchGuiScan -Window $window -DataRoot $root -RepositoryRoot $ProjectRoot -Name 'slowapp' -ScanType 'Before' -Collectors $slowCollectors
        $stopwatch.Stop()

        # The call must return well before the 600ms collector sleep completes - proof the scan runs
        # on a background runspace rather than blocking the click handler synchronously. This check
        # never waits for the background op to finish, so no dispatcher pump is needed here.
        $stopwatch.ElapsedMilliseconds | Should BeLessThan 400
        $handle | Should Not Be $null
        $window.FindName('ScanBeforeButton').IsEnabled | Should Be $false
        $window.FindName('ScanAfterButton').IsEnabled | Should Be $false
        $window.FindName('BusyIndicatorText').Visibility | Should Be ([System.Windows.Visibility]::Visible)

        # A second scan attempted while the first is still running must be a no-op: it starts no
        # second background operation and returns nothing.
        $secondHandle = Start-LeanLaunchGuiScan -Window $window -DataRoot $root -RepositoryRoot $ProjectRoot -Name 'slowapp' -ScanType 'Before' -Collectors $slowCollectors
        $secondHandle | Should Be $null

        # Stop the polling timer directly so it never fires again on this thread's shared dispatcher
        # (see the next test for why a live in-process dispatcher pump is avoided), but do not dispose
        # the pipeline yet. Disposing/stopping a PowerShell pipeline while its background thread is
        # still mid-flight (e.g. still inside Import-Module) can corrupt process-wide command/type
        # resolution for the rest of the process - a real hazard confirmed by direct investigation,
        # not a Pester artifact. All of this test's assertions already ran above this point, so
        # draining the async op to a real finish before releasing it changes nothing being proven.
        $handle.Timer.Stop()
        if (-not $handle.AsyncResult.IsCompleted) {
            $handle.AsyncResult.AsyncWaitHandle.WaitOne(5000) | Out-Null
        }
        try { $handle.PowerShell.EndInvoke($handle.AsyncResult) } catch { }
        $handle.PowerShell.Dispose()
        $script:LeanLaunchGuiScanInProgress = $false
    }

    It 'reflects the completed scan and re-enables scan controls once the background op finishes' {
        # Manually pumping the dispatcher (DispatcherFrame/Dispatcher.Invoke) from a script that is
        # itself mid-pipeline corrupts PowerShell command resolution for the rest of the process, even
        # in a separate process (confirmed by direct investigation) - a real hazard of reentering the
        # engine that way, not a Pester artifact. Production code never does this: ShowDialog() runs
        # one real, continuous native message loop with nothing else on the call stack. So this test
        # drives that exact real loop instead: -OnComplete writes the result and closes the window,
        # the same proven-stable idiom the existing -SmokeTest auto-close already uses below.
        $root = Join-Path $FixtureRoot 'gui-slow-scan-completion'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $scriptPath = Join-Path $root 'run-gui-scan-smoke.ps1'
        $resultPath = Join-Path $root 'result.json'
        @"
Import-Module '$(Join-Path $ProjectRoot 'LeanLaunch.psd1')' -Force
. '$(Join-Path $ProjectRoot 'src\LeanLaunch.Gui.ps1')'
`$exe = Join-Path '$root' 'slowapp.exe'
Set-Content -LiteralPath `$exe -Value 'fixture'
New-LeanLaunchApplication -Name 'slowapp' -Executable `$exe -DataRoot '$root' | Out-Null
`$slowCollectors = @{ Processes = { Start-Sleep -Milliseconds 300; @() }; Services = { @() }; Startup = { @() }; ScheduledTasks = { @() } }
`$window = [Windows.Markup.XamlReader]::Parse(`$script:LeanLaunchGuiXaml)
Update-LeanLaunchGuiApplicationList -Window `$window -DataRoot '$root' -SelectName 'slowapp'

`$window.Add_Loaded({
    Start-LeanLaunchGuiScan -Window `$window -DataRoot '$root' -RepositoryRoot '$ProjectRoot' -Name 'slowapp' -ScanType 'Before' -Collectors `$slowCollectors -OnComplete {
        `$final = [ordered]@{
            scanBeforeReenabled = `$window.FindName('ScanBeforeButton').IsEnabled
            scanAfterReenabled = `$window.FindName('ScanAfterButton').IsEnabled
            busyIndicatorHiddenAfter = (`$window.FindName('BusyIndicatorText').Visibility -eq [System.Windows.Visibility]::Collapsed)
            auditStatusAfterScan = `$window.FindName('AuditStatusText').Text
        }
        (`$final | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath '$resultPath' -Encoding UTF8
        `$window.Close()
    }.GetNewClosure() | Out-Null
}.GetNewClosure())

[void]`$window.ShowDialog()
Write-Output 'GUI_SCAN_SMOKE_TEST_COMPLETE'
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outFile = Join-Path $root 'out.txt'
        $errFile = Join-Path $root 'err.txt'
        $proc = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) `
            -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $completed = $proc.WaitForExit(20000)
        $completed | Should Be $true
        $errContent = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }
        [string]::IsNullOrWhiteSpace($errContent) | Should Be $true
        (Get-Content -LiteralPath $outFile -Raw) | Should Match 'GUI_SCAN_SMOKE_TEST_COMPLETE'

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $result.scanBeforeReenabled | Should Be $true
        $result.scanAfterReenabled | Should Be $true
        $result.busyIndicatorHiddenAfter | Should Be $true
        $result.auditStatusAfterScan | Should Match 'Audit status:'
    }

    It 'opens and closes cleanly in smoke-test mode without staying resident' {
        $root = Join-Path $FixtureRoot 'gui-smoke'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $scriptPath = Join-Path $root 'run-gui-smoke.ps1'
        @"
Import-Module '$(Join-Path $ProjectRoot 'LeanLaunch.psd1')' -Force
. '$(Join-Path $ProjectRoot 'src\LeanLaunch.Gui.ps1')'
Show-LeanLaunchGui -DataRoot '$root' -RepositoryRoot '$ProjectRoot' -SmokeTest
Write-Output 'GUI_SMOKE_TEST_COMPLETE'
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outFile = Join-Path $root 'out.txt'
        $errFile = Join-Path $root 'err.txt'
        $proc = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) `
            -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $completed = $proc.WaitForExit(20000)
        $completed | Should Be $true
        (Get-Content -LiteralPath $outFile -Raw) | Should Match 'GUI_SMOKE_TEST_COMPLETE'
        $errContent = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }
        [string]::IsNullOrWhiteSpace($errContent) | Should Be $true
    }

    It 'threads the injected adapter into the background before-scan so it reaches parked-service restoration' {
        $root = Join-Path $FixtureRoot 'gui-scan-adapter-threading'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'parkapp.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'parkapp' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'parkapp' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='ParkGuiSvc';DisplayName='ParkGuiSvc';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'parkapp' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'parkapp' -Key 'Service|parkguisvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchServiceParkingPreference -Name 'parkapp' -Key 'Service|parkguisvc' -ParkWhenIdle $true -DataRoot $root | Out-Null
        New-LeanLaunchApplicationProfile -Name 'parkapp' -DataRoot $root -Confirm:$false | Out-Null

        # A hashtable is a reference type, shared correctly across runspaces in the same process;
        # GetNewClosure() on every adapter member detaches each scriptblock from this test's own
        # lexical scope so it resolves $state correctly when invoked from the scan's background
        # runspace, not just from this test's own runspace.
        $state = @{ Modes = @{ ParkGuiSvc = 'Auto' } }
        $activationAdapter = @{
            IsAdministrator = { $true }.GetNewClosure()
            GetServiceStartMode = { param($n) $state.Modes[$n] }.GetNewClosure()
            SetServiceStartMode = { param($n,$e,$new) $state.Modes[$n] = $new }.GetNewClosure()
            GetService = { param($n) [pscustomobject]@{ Name=$n; Status='Stopped'; ProcessId=0 } }.GetNewClosure()
        }
        Set-LeanLaunchApplicationPolicy -Name 'parkapp' -Policy 'Managed' -DataRoot $root -Adapter $activationAdapter -Confirm:$false | Out-Null
        $state.Modes['ParkGuiSvc'] | Should Be 'Disabled'

        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root -SelectName 'parkapp'

        $scanAdapter = @{
            IsAdministrator = { $true }.GetNewClosure()
            GetServiceStartMode = { param($n) $state.Modes[$n] }.GetNewClosure()
            SetServiceStartMode = { param($n,$e,$new) $state.Modes[$n] = $new }.GetNewClosure()
        }
        $handle = Start-LeanLaunchGuiScan -Window $window -DataRoot $root -RepositoryRoot $ProjectRoot -Name 'parkapp' -ScanType 'Before' -Collectors $emptyCollectors -Adapter $scanAdapter
        $handle.AsyncResult.AsyncWaitHandle.WaitOne(15000) | Out-Null
        $handle.Timer.Stop()
        try { $handle.PowerShell.EndInvoke($handle.AsyncResult) } catch { }
        $handle.PowerShell.Dispose()
        $handle.Runspace.Close()
        $script:LeanLaunchGuiScanInProgress = $false
        $script:LeanLaunchGuiActiveScanHandle = $null

        # A real (non-injected) adapter would try to touch a nonexistent Windows service named
        # 'ParkGuiSvc' and fail. Success (mode restored to Auto, policy dropped to Unmanaged) proves
        # the background scan's own New-LeanLaunchApplicationBeforeSnapshot call received the SAME
        # adapter Start-LeanLaunchGuiScan was given, not a silent fallback to the real adapter.
        $state.Modes['ParkGuiSvc'] | Should Be 'Auto'
        $application = Import-LeanLaunchApplication -Name 'parkapp' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
    }
}

Describe 'LeanLaunch GUI active-scan cancellation on close' {
    It 'is a safe no-op when no scan is active' {
        { Stop-LeanLaunchGuiActiveScan } | Should Not Throw
    }

    It 'drains a still-running scan to completion, disposes the runspace, and clears in-progress state' {
        $root = Join-Path $FixtureRoot 'gui-stop-active-scan-drain'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'drainapp.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'drainapp' -Executable $exe -DataRoot $root | Out-Null
        $slowCollectors = @{ Processes = { Start-Sleep -Milliseconds 400; @() }; Services = { @() }; Startup = { @() }; ScheduledTasks = { @() } }

        $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $root -SelectName 'drainapp'
        $handle = Start-LeanLaunchGuiScan -Window $window -DataRoot $root -RepositoryRoot $ProjectRoot -Name 'drainapp' -ScanType 'Before' -Collectors $slowCollectors
        $handle | Should Not Be $null
        $script:LeanLaunchGuiActiveScanHandle | Should Not Be $null

        # The collector's 400ms sleep comfortably fits inside this 5s drain bound, so this exercises
        # the "wait for natural completion" path without ever needing PowerShell.Stop() mid-flight.
        { Stop-LeanLaunchGuiActiveScan -DrainTimeoutMilliseconds 5000 } | Should Not Throw

        $script:LeanLaunchGuiScanInProgress | Should Be $false
        $script:LeanLaunchGuiActiveScanHandle | Should Be $null
        $handle.Runspace.RunspaceStateInfo.State | Should Be 'Closed'
    }

    It 'closing the GUI window during a slow scan does not leave the host process resident' {
        $root = Join-Path $FixtureRoot 'gui-close-during-scan'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $scriptPath = Join-Path $root 'run-gui-close-during-scan.ps1'
        @"
Import-Module '$(Join-Path $ProjectRoot 'LeanLaunch.psd1')' -Force
. '$(Join-Path $ProjectRoot 'src\LeanLaunch.Gui.ps1')'
`$exe = Join-Path '$root' 'slowapp.exe'
Set-Content -LiteralPath `$exe -Value 'fixture'
New-LeanLaunchApplication -Name 'slowapp' -Executable `$exe -DataRoot '$root' | Out-Null
# Deliberately much longer than this test's own WaitForExit bound below, so a process exit within
# that bound can only be explained by the close-triggered cancellation actually cutting it short -
# not by coincidentally finishing on its own first.
`$slowCollectors = @{ Processes = { [Threading.Thread]::Sleep(60000); @() }; Services = { @() }; Startup = { @() }; ScheduledTasks = { @() } }
`$window = [Windows.Markup.XamlReader]::Parse(`$script:LeanLaunchGuiXaml)
Update-LeanLaunchGuiApplicationList -Window `$window -DataRoot '$root' -SelectName 'slowapp'

`$closeTimer = New-Object System.Windows.Threading.DispatcherTimer
`$closeTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
`$closeTimer.Add_Tick({
    `$closeTimer.Stop()
    `$window.Close()
}.GetNewClosure())

`$window.Add_Loaded({
    Start-LeanLaunchGuiScan -Window `$window -DataRoot '$root' -RepositoryRoot '$ProjectRoot' -Name 'slowapp' -ScanType 'Before' -Collectors `$slowCollectors | Out-Null
    `$closeTimer.Start()
}.GetNewClosure())

[void]`$window.ShowDialog()
Write-Output 'GUI_CLOSE_DURING_SCAN_COMPLETE'
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outFile = Join-Path $root 'out.txt'
        $errFile = Join-Path $root 'err.txt'
        $proc = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) `
            -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # 20s is comfortably longer than close (1s) + the bounded drain/stop attempts, but far short
        # of the 60s collector sleep - only early cancellation on close explains exiting in time.
        $completed = $proc.WaitForExit(20000)
        $completed | Should Be $true
        (Get-Content -LiteralPath $outFile -Raw) | Should Match 'GUI_CLOSE_DURING_SCAN_COMPLETE'
    }
}

Describe 'LeanLaunch GUI profile-build overwrite confirmation' {
    It 'writes a profile directly without prompting when none exists yet' {
        $root = Join-Path $FixtureRoot 'gui-profile-build-fresh'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'demo' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null

        $script:guiProfileBuildConfirmerCalled = $false
        $confirmer = { param($n) $script:guiProfileBuildConfirmerCalled = $true; $true }
        $result = Invoke-LeanLaunchGuiProfileBuild -Name 'demo' -DataRoot $root -Confirmer $confirmer
        $result.status | Should Be 'Written'
        $script:guiProfileBuildConfirmerCalled | Should Be $false
    }

    It 'prompts for confirmation and does not overwrite an existing profile when declined' {
        $root = Join-Path $FixtureRoot 'gui-profile-build-declined'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'demo' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        $profileFile = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $originalContent = Get-Content -LiteralPath $profileFile -Raw

        $result = Invoke-LeanLaunchGuiProfileBuild -Name 'demo' -DataRoot $root -Confirmer { param($n) $false }
        $result.status | Should Be 'Canceled'
        (Get-Content -LiteralPath $profileFile -Raw) | Should Be $originalContent
    }

    It 'prompts for confirmation and overwrites an existing profile when accepted' {
        $root = Join-Path $FixtureRoot 'gui-profile-build-accepted'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'demo' -Executable $exe -DataRoot $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $result = Invoke-LeanLaunchGuiProfileBuild -Name 'demo' -DataRoot $root -Confirmer { param($n) $true }
        $result.status | Should Be 'Written'
    }
}
