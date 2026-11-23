# LeanLaunch desktop GUI. Presentation layer only: every action below calls the same shared
# module functions the CLI dispatcher (Invoke-LeanLaunchCommand) uses, so lifecycle logic is never
# duplicated between the two surfaces. This script is intentionally kept out of the LeanLaunch
# module itself so importing the module for CLI/test use never pulls in WPF assemblies.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore | Out-Null
Add-Type -AssemblyName WindowsBase | Out-Null
Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null

# PowerShell.Stop/Dispose and Runspace.Close can themselves block when a collector is stuck inside a
# non-interruptible native/.NET call. Perform that teardown on a background CLR thread and join it only
# for a caller-supplied bound; GUI close therefore never synchronously inherits an unbounded method.
if ($null -eq ('LeanLaunch.GuiBoundedCleanup' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'GuiBoundedCleanup.cs') | Out-Null
}

if (-not (Get-Command -Name New-LeanLaunchApplication -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\LeanLaunch.psd1') -Force
}

$script:LeanLaunchGuiScanInProgress = $false
$script:LeanLaunchGuiActiveScanHandle = $null

$script:LeanLaunchGuiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LeanLaunch" Height="700" Width="1050" WindowStartupLocation="CenterScreen">
    <Grid Margin="8">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="260"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="90"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Column="0" Grid.Row="0" Margin="0,0,8,0">
            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,4">
                <Button Name="NewAppButton" Content="New application" Width="120" Margin="0,0,4,0"/>
                <Button Name="RefreshButton" Content="Refresh" Width="80"/>
            </StackPanel>
            <ListBox Name="ApplicationList" DisplayMemberPath="displayLabel"/>
        </DockPanel>

        <TabControl Name="DetailTabs" Grid.Column="1" Grid.Row="0">
            <TabItem Header="Overview">
                <StackPanel Margin="8">
                    <TextBlock Name="AppNameText" FontSize="18" FontWeight="Bold" Text="(select an application)"/>
                    <TextBlock Name="AppExeText" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                        <TextBlock Text="Policy:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <ComboBox Name="PolicyCombo" Width="140">
                            <ComboBoxItem Content="Unmanaged"/>
                            <ComboBoxItem Content="Managed"/>
                        </ComboBox>
                        <Button Name="ApplyPolicyButton" Content="Apply policy" Width="110" Margin="8,0,0,0"/>
                    </StackPanel>
                    <TextBlock Text="Safety warnings" FontWeight="Bold" Margin="0,14,0,2"/>
                    <ListBox Name="WarningsList" Height="90" Foreground="DarkRed"/>
                    <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                        <Button Name="DryRunButton" Content="Dry run / action plan" Width="150" Margin="0,0,4,0"/>
                        <Button Name="LaunchButton" Content="Launch application" Width="150"/>
                    </StackPanel>
                    <TextBlock Text="Plan / result" FontWeight="Bold" Margin="0,14,0,2"/>
                    <TextBox Name="PlanText" Height="180" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas"/>
                </StackPanel>
            </TabItem>
            <TabItem Header="Audit">
                <DockPanel Margin="8">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
                        <Button Name="ScanBeforeButton" Content="Before-install scan" Width="150" Margin="0,0,4,0"/>
                        <Button Name="ScanAfterButton" Content="After-install scan" Width="150" Margin="0,0,4,0"/>
                        <Button Name="BuildProfileButton" Content="Build profile from reviewed" Width="190"/>
                    </StackPanel>
                    <TextBlock DockPanel.Dock="Top" Name="AuditStatusText" Margin="0,0,0,4"/>
                    <TextBlock DockPanel.Dock="Top" Name="BusyIndicatorText" Text="Scanning... please wait" Foreground="DarkOrange" FontWeight="Bold" Visibility="Collapsed" Margin="0,0,0,8"/>
                    <Grid DockPanel.Dock="Bottom" Height="120" Margin="0,8,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="220"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <TextBlock Text="Selected resource" FontWeight="Bold"/>
                            <TextBlock Name="SelectedKeyText" TextWrapping="Wrap"/>
                            <TextBlock Name="SelectedEvidenceText" TextWrapping="Wrap" Foreground="Gray"/>
                            <TextBlock Name="SelectedPathText" TextWrapping="Wrap" Foreground="Gray"/>
                            <TextBox Name="NoteBox" Margin="0,6,0,0" Width="380" HorizontalAlignment="Left"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1">
                            <TextBlock Text="Decision" FontWeight="Bold"/>
                            <ComboBox Name="DecisionCombo" Width="180"/>
                            <Button Name="SaveClassificationButton" Content="Save classification" Width="180" Margin="0,8,0,0"/>
                            <CheckBox Name="ParkWhenIdleCheckBox" Content="Park when idle (services only)" Margin="0,12,0,0"/>
                            <Button Name="SaveParkingButton" Content="Save idle-parking preference" Width="180" Margin="0,4,0,0"/>
                            <TextBlock Name="CurrentlyParkedText" Margin="0,6,0,0" Foreground="Gray" TextWrapping="Wrap" Width="180"/>
                        </StackPanel>
                    </Grid>
                    <DataGrid Name="ClassificationGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Type" Binding="{Binding resourceType}" Width="110"/>
                            <DataGridTextColumn Header="Name" Binding="{Binding name}" Width="180"/>
                            <DataGridTextColumn Header="Decision" Binding="{Binding decision}" Width="100"/>
                            <DataGridCheckBoxColumn Header="Park pref." Binding="{Binding parkWhenIdle}" Width="70"/>
                            <DataGridCheckBoxColumn Header="Parked now" Binding="{Binding currentlyParked}" Width="80"/>
                            <DataGridTextColumn Header="Evidence" Binding="{Binding evidence}" Width="260"/>
                            <DataGridTextColumn Header="Path" Binding="{Binding path}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>
        </TabControl>

        <GroupBox Grid.Column="0" Grid.ColumnSpan="2" Grid.Row="1" Header="Log" Margin="0,8,0,0">
            <TextBox Name="LogText" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11"/>
        </GroupBox>
    </Grid>
</Window>
'@

function Write-LeanLaunchGuiLog {
    param($Window, [string]$Message)
    $logBox = $Window.FindName('LogText')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $logBox.AppendText("[$stamp] $Message`r`n")
    $logBox.ScrollToEnd()
}

function Get-LeanLaunchGuiSelectedApplicationName {
    param($Window)
    $item = $Window.FindName('ApplicationList').SelectedItem
    if ($null -eq $item) { return $null }
    return [string]$item.name
}

function Update-LeanLaunchGuiApplicationList {
    param($Window, [string]$DataRoot, [string]$SelectName)
    $applications = @(Get-LeanLaunchApplications -DataRoot $DataRoot)
    $rows = Get-LeanLaunchApplicationSummaryRows -Applications $applications
    $displayRows = @($rows | ForEach-Object {
        $_ | Add-Member -MemberType NoteProperty -Name displayLabel -Value ("{0}  [{1}]  {2}" -f $_.displayName, $_.policy, $_.auditStatus) -Force -PassThru
    })
    $list = $Window.FindName('ApplicationList')
    $list.ItemsSource = $displayRows
    if (-not [string]::IsNullOrWhiteSpace($SelectName)) {
        $match = @($displayRows | Where-Object { $_.name -eq $SelectName }) | Select-Object -First 1
        if ($null -ne $match) { $list.SelectedItem = $match }
    }
}

function Update-LeanLaunchGuiApplicationDetail {
    param($Window, [string]$DataRoot)
    $name = Get-LeanLaunchGuiSelectedApplicationName $Window
    $Window.FindName('ClassificationGrid').ItemsSource = $null
    if ([string]::IsNullOrWhiteSpace($name)) {
        $Window.FindName('AppNameText').Text = '(select an application)'
        $Window.FindName('AppExeText').Text = ''
        $Window.FindName('WarningsList').ItemsSource = $null
        $Window.FindName('AuditStatusText').Text = ''
        return
    }
    $application = $null
    try {
        $application = Import-LeanLaunchApplication -Name $name -DataRoot $DataRoot
    }
    catch {
        # A record that fails strict validation (corruption, a hand-edit, a partially-written file)
        # must still be visible and explained, not crash the selection-changed/refresh handler that
        # called this - the malformed state itself is exactly what the operator needs to see.
        $Window.FindName('AppNameText').Text = "$name (malformed application record)"
        $Window.FindName('AppExeText').Text = $_.Exception.Message
        $Window.FindName('WarningsList').ItemsSource = @('This application record failed validation and cannot be managed until it is repaired or removed.')
        $Window.FindName('AuditStatusText').Text = 'Audit status: Malformed'
        return
    }
    $Window.FindName('AppNameText').Text = $application.displayName
    $Window.FindName('AppExeText').Text = $application.executable
    $policyCombo = $Window.FindName('PolicyCombo')
    foreach ($comboItem in $policyCombo.Items) {
        if ([string]$comboItem.Content -eq [string]$application.policy) { $policyCombo.SelectedItem = $comboItem }
    }
    $Window.FindName('WarningsList').ItemsSource = @(Get-LeanLaunchApplicationSafetyWarnings -Application $application -DataRoot $DataRoot)
    $status = Get-LeanLaunchApplicationAuditStatus $application
    $Window.FindName('AuditStatusText').Text = "Audit status: $status"
    $Window.FindName('ClassificationGrid').ItemsSource = @(Get-LeanLaunchClassificationRows -Application $application)
}

function Update-LeanLaunchGuiSelectedClassification {
    param($Window, $Row)
    if ($null -eq $Row) { return }
    $Window.FindName('SelectedKeyText').Text = "$($Row.resourceType): $($Row.name)"
    $Window.FindName('SelectedEvidenceText').Text = $Row.evidence
    $Window.FindName('SelectedPathText').Text = $Row.path
    $Window.FindName('NoteBox').Text = $Row.note
    $decisionCombo = $Window.FindName('DecisionCombo')
    $decisionCombo.ItemsSource = @($Row.allowedDecisions)
    $decisionCombo.SelectedItem = $Row.decision
    $isService = ([string]$Row.resourceType -eq 'Service')
    $parkCheckBox = $Window.FindName('ParkWhenIdleCheckBox')
    $parkCheckBox.IsChecked = [bool]$Row.parkWhenIdle
    $parkCheckBox.IsEnabled = $isService
    $Window.FindName('SaveParkingButton').IsEnabled = $isService
    # currentlyParked is LIVE state (is the service actually disabled right now); parkWhenIdle above
    # is only the PREFERENCE - they are shown as two clearly distinct facts, never conflated as one.
    $Window.FindName('CurrentlyParkedText').Text = if (-not $isService) { '' }
        elseif ($Row.currentlyParked) { 'Currently parked: yes (service is disabled by LeanLaunch)' }
        else { 'Currently parked: no' }
}

function ConvertTo-LeanLaunchPowerShellLiteral {
    param([AllowNull()][string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Start-LeanLaunchGuiApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$DataRoot,
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [hashtable]$Adapter,
        [scriptblock]$SupervisorLauncher
    )

    $application = Import-LeanLaunchApplication -Name $Name -DataRoot $DataRoot
    # An unmanaged launch returns immediately, and an injected adapter cannot be serialized into a
    # child process. Both paths therefore stay in-process; only a real managed run needs supervision.
    if ($application.policy -eq 'Unmanaged' -or $null -ne $Adapter) {
        return Invoke-LeanLaunchApplicationRun -Name $Name -DataRoot $DataRoot -RepositoryRoot $RepositoryRoot -Adapter $Adapter
    }

    $dryRun = Invoke-LeanLaunchApplicationRun -Name $Name -DataRoot $DataRoot -RepositoryRoot $RepositoryRoot -DryRun
    $requiresElevation = @($dryRun.plan.servicesToStart).Count -gt 0
    $sessionDirectory = Join-Path $DataRoot 'sessions'
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null
    $sessionId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $logPath = Join-Path $sessionDirectory ($Name + '-' + $sessionId + '.json')

    $modulePath = Join-Path $RepositoryRoot 'LeanLaunch.psd1'
    $moduleLiteral = ConvertTo-LeanLaunchPowerShellLiteral $modulePath
    $nameLiteral = ConvertTo-LeanLaunchPowerShellLiteral $Name
    $dataLiteral = ConvertTo-LeanLaunchPowerShellLiteral $DataRoot
    $repositoryLiteral = ConvertTo-LeanLaunchPowerShellLiteral $RepositoryRoot
    $logLiteral = ConvertTo-LeanLaunchPowerShellLiteral $logPath
    $command = @"
`$ErrorActionPreference = 'Stop'
try {
    Import-Module $moduleLiteral -Force
    `$result = Invoke-LeanLaunchApplicationRun -Name $nameLiteral -DataRoot $dataLiteral -RepositoryRoot $repositoryLiteral
    Write-LeanLaunchJsonAtomic -Path $logLiteral -InputObject `$result -Depth 8
    if (`$result.status -in @('CleanupIncomplete','WaitTimedOut')) { exit 1 }
}
catch {
    Write-LeanLaunchJsonAtomic -Path $logLiteral -InputObject ([ordered]@{ status='Failed'; error=`$_.Exception.Message }) -Depth 4
    exit 1
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)

    if ($null -ne $SupervisorLauncher) {
        $supervisor = & $SupervisorLauncher $powershellPath $arguments $requiresElevation $logPath
    }
    else {
        $start = @{ FilePath=$powershellPath; ArgumentList=$arguments; WindowStyle='Hidden'; PassThru=$true }
        if ($requiresElevation) { $start.Verb = 'RunAs' }
        $supervisor = Start-Process @start
    }

    return [pscustomobject]@{
        status = 'SupervisorStarted'
        processId = [int]$supervisor.Id
        elevated = [bool]$requiresElevation
        logPath = $logPath
    }
}

function Start-LeanLaunchGuiScan {
    <#
    Runs a before/after scan on a background runspace so the WPF dispatcher stays responsive for a
    slow collector, then marshals the result back via a DispatcherTimer poll (ticks fire on the UI
    thread, so no explicit Dispatcher.Invoke is needed once EndInvoke completes). Returns $null and
    starts nothing if a scan is already running, so a second click can never overlap the first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Before', 'After')][string]$ScanType,
        [hashtable]$Collectors,
        [hashtable]$Adapter,
        [scriptblock]$OnComplete
    )
    if ($script:LeanLaunchGuiScanInProgress) { return $null }
    $script:LeanLaunchGuiScanInProgress = $true

    $scanBeforeButton = $Window.FindName('ScanBeforeButton')
    $scanAfterButton = $Window.FindName('ScanAfterButton')
    $busyIndicator = $Window.FindName('BusyIndicatorText')
    $scanBeforeButton.IsEnabled = $false
    $scanAfterButton.IsEnabled = $false
    $busyIndicator.Visibility = [System.Windows.Visibility]::Visible

    $modulePath = Join-Path $RepositoryRoot 'LeanLaunch.psd1'
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.Open()
    $powershell = [PowerShell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript({
        param($ModulePath, $Name, $DataRoot, $Collectors, $ScanType, $Adapter)
        Import-Module $ModulePath -Force
        if ($ScanType -eq 'Before') {
            # A fresh baseline can restore a currently-parked service (profile invalidation) - the
            # adapter injected into the GUI (a test/controller adapter, when one was supplied) must
            # reach that restore too, never silently falling back to the real Windows adapter.
            New-LeanLaunchApplicationBeforeSnapshot -Name $Name -DataRoot $DataRoot -Collectors $Collectors -Adapter $Adapter -Confirm:$false
        }
        else {
            Complete-LeanLaunchApplicationAudit -Name $Name -DataRoot $DataRoot -Collectors $Collectors -Confirm:$false
        }
    })
    [void]$powershell.AddArgument($modulePath)
    [void]$powershell.AddArgument($Name)
    [void]$powershell.AddArgument($DataRoot)
    [void]$powershell.AddArgument($Collectors)
    [void]$powershell.AddArgument($ScanType)
    [void]$powershell.AddArgument($Adapter)

    $asyncResult = $powershell.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $timer.Add_Tick({
        if (-not $asyncResult.IsCompleted) { return }
        $timer.Stop()
        try {
            $result = $powershell.EndInvoke($asyncResult)
            $selected = Get-LeanLaunchGuiSelectedApplicationName $Window
            Update-LeanLaunchGuiApplicationList -Window $Window -DataRoot $DataRoot -SelectName $selected
            Update-LeanLaunchGuiApplicationDetail -Window $Window -DataRoot $DataRoot
            if ($ScanType -eq 'Before') {
                Write-LeanLaunchGuiLog $Window ("Before-install baseline captured: " + $result.snapshotName)
            }
            else {
                $count = @($result.application.currentAudit.classifications).Count
                Write-LeanLaunchGuiLog $Window "After-install diff captured: $count candidate resource(s) to review."
            }
        }
        catch {
            Write-LeanLaunchGuiLog $Window "Error: $($_.Exception.Message)"
        }
        finally {
            $powershell.Dispose()
            $runspace.Close()
            $scanBeforeButton.IsEnabled = $true
            $scanAfterButton.IsEnabled = $true
            $busyIndicator.Visibility = [System.Windows.Visibility]::Collapsed
            $script:LeanLaunchGuiScanInProgress = $false
            $script:LeanLaunchGuiActiveScanHandle = $null
            if ($null -ne $OnComplete) {
                try { & $OnComplete } catch { Write-LeanLaunchGuiLog $Window "Error: $($_.Exception.Message)" }
            }
        }
    }.GetNewClosure())
    $timer.Start()

    $handle = [pscustomobject]@{ AsyncResult = $asyncResult; PowerShell = $powershell; Timer = $timer; Runspace = $runspace }
    $script:LeanLaunchGuiActiveScanHandle = $handle
    return $handle
}

function Stop-LeanLaunchGuiActiveScan {
    <#
    Best-effort cancel/drain/dispose for whatever scan is currently in flight, so closing the GUI
    during a slow or hung collector can never leave its runspace/pipeline/timer alive after the
    window (and, since this is a zero-resident application, the process) closes. Safe to call when no
    scan is active. Bounded: this never waits indefinitely, so a truly stuck collector still lets the
    window finish closing rather than hanging it forever.
    #>
    [CmdletBinding()]
    param([int]$DrainTimeoutMilliseconds = 3000)
    $handle = $script:LeanLaunchGuiActiveScanHandle
    if ($null -eq $handle) { return }
    $script:LeanLaunchGuiActiveScanHandle = $null
    $script:LeanLaunchGuiScanInProgress = $false
    try { $handle.Timer.Stop() } catch { }
    if (-not $handle.AsyncResult.IsCompleted) {
        $handle.AsyncResult.AsyncWaitHandle.WaitOne($DrainTimeoutMilliseconds) | Out-Null
    }
    if ($handle.AsyncResult.IsCompleted) {
        try { $handle.PowerShell.EndInvoke($handle.AsyncResult) } catch { }
        # Even completed pipelines can have a blocking Dispose/Close implementation; keep teardown
        # under the same hard bound as cancellation.
        [void][LeanLaunch.GuiBoundedCleanup]::Run($handle.PowerShell, $handle.Runspace, $DrainTimeoutMilliseconds)
    }
    else {
        # Stop/Dispose/Close all run off the GUI thread. If a native/non-cooperative collector ignores
        # Stop, this returns when the bound expires; the cleanup worker is a background thread and
        # cannot keep the GUI host process resident after its main thread exits.
        [void][LeanLaunch.GuiBoundedCleanup]::Run($handle.PowerShell, $handle.Runspace, $DrainTimeoutMilliseconds)
    }
}

function Invoke-LeanLaunchGuiProfileBuild {
    <#
    Builds a profile for $Name, prompting for confirmation via $Confirmer only when a profile of that
    name already exists - BuildProfileButton must never silently overwrite a hand-edited or
    previously-generated profile. $Confirmer receives the application name and returns $true to
    proceed with the overwrite; kept as an injectable scriptblock (mirroring -SupervisorLauncher) so
    the decision path is testable without a real modal dialog.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DataRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Confirmer
    )
    $profilePath = Join-Path (Get-LeanLaunchPaths -DataRoot $DataRoot).Profiles ($Name + '.json')
    $forceOverwrite = $false
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        if (-not [bool](& $Confirmer $Name)) {
            return [pscustomobject]@{ status = 'Canceled'; path = $null; application = $null; skippedResidualProcesses = @() }
        }
        $forceOverwrite = $true
    }
    $result = New-LeanLaunchApplicationProfile -Name $Name -DataRoot $DataRoot -Force:$forceOverwrite -Confirm:$false
    return ($result | Add-Member -MemberType NoteProperty -Name status -Value 'Written' -Force -PassThru)
}

function Show-LeanLaunchGui {
    [CmdletBinding()]
    param(
        [string]$DataRoot,
        [string]$RepositoryRoot,
        [hashtable]$Adapter,
        [hashtable]$Collectors,
        [switch]$SmokeTest
    )
    $window = [Windows.Markup.XamlReader]::Parse($script:LeanLaunchGuiXaml)
    # $Adapter/$Collectors are left $null unless a caller (e.g. a test) injects them; every function
    # called below defaults them to the real Windows adapter/collectors internally.

    Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $DataRoot
    Write-LeanLaunchGuiLog $window 'LeanLaunch GUI started. No resident component is installed; closing this window ends the process.'

    $window.FindName('ApplicationList').Add_SelectionChanged({
        Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $DataRoot
    }.GetNewClosure())

    $window.FindName('RefreshButton').Add_Click({
        $selected = Get-LeanLaunchGuiSelectedApplicationName $window
        Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $DataRoot -SelectName $selected
        Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $DataRoot
        Write-LeanLaunchGuiLog $window 'Refreshed.'
    }.GetNewClosure())

    $window.FindName('NewAppButton').Add_Click({
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Application name (command-safe, e.g. "office")', 'New application', '')
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $exe = [Microsoft.VisualBasic.Interaction]::InputBox('Full path to the application executable', 'New application', '')
        if ([string]::IsNullOrWhiteSpace($exe)) { return }
        try {
            New-LeanLaunchApplication -Name $name -Executable $exe -DataRoot $DataRoot | Out-Null
            Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $DataRoot -SelectName $name
            Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $DataRoot
            Write-LeanLaunchGuiLog $window "Created application '$name'."
        }
        catch { Write-LeanLaunchGuiLog $window "Error: $($_.Exception.Message)" }
    }.GetNewClosure())

    $window.FindName('ApplyPolicyButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $policyItem = $window.FindName('PolicyCombo').SelectedItem
        if ($null -eq $policyItem) { return }
        try {
            Set-LeanLaunchApplicationPolicy -Name $name -Policy ([string]$policyItem.Content) -DataRoot $DataRoot -Adapter $Adapter -Confirm:$false | Out-Null
            Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $DataRoot -SelectName $name
            Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $DataRoot
            Write-LeanLaunchGuiLog $window "Policy for '$name' set to $($policyItem.Content)."
        }
        catch { Write-LeanLaunchGuiLog $window "Error: $($_.Exception.Message)" }
    }.GetNewClosure())

    $window.FindName('ScanBeforeButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        Start-LeanLaunchGuiScan -Window $window -DataRoot $DataRoot -RepositoryRoot $RepositoryRoot -Name $name -ScanType 'Before' -Collectors $Collectors -Adapter $Adapter | Out-Null
    }.GetNewClosure())

    $window.FindName('ScanAfterButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        Start-LeanLaunchGuiScan -Window $window -DataRoot $DataRoot -RepositoryRoot $RepositoryRoot -Name $name -ScanType 'After' -Collectors $Collectors -Adapter $Adapter | Out-Null
    }.GetNewClosure())

    $window.FindName('ClassificationGrid').Add_SelectionChanged({
        Update-LeanLaunchGuiSelectedClassification -Window $window -Row $window.FindName('ClassificationGrid').SelectedItem
    }.GetNewClosure())

    $window.FindName('SaveClassificationButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        $row = $window.FindName('ClassificationGrid').SelectedItem
        $decision = $window.FindName('DecisionCombo').SelectedItem
        if ([string]::IsNullOrWhiteSpace($name) -or $null -eq $row -or [string]::IsNullOrWhiteSpace([string]$decision)) { return }
        try {
            Set-LeanLaunchResourceClassification -Name $name -Key $row.key -Decision ([string]$decision) -Note $window.FindName('NoteBox').Text -DataRoot $DataRoot -Adapter $Adapter -Confirm:$false | Out-Null
            Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $DataRoot -SelectName $name
            Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $DataRoot
            Write-LeanLaunchGuiLog $window "Classification saved for $($row.resourceType) '$($row.name)': $decision"
        }
        catch { Write-LeanLaunchGuiLog $window "Error: $($_.Exception.Message)" }
    }.GetNewClosure())

    $window.FindName('SaveParkingButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        $row = $window.FindName('ClassificationGrid').SelectedItem
        if ([string]::IsNullOrWhiteSpace($name) -or $null -eq $row) { return }
        $parkWhenIdle = [bool]$window.FindName('ParkWhenIdleCheckBox').IsChecked
        try {
            Set-LeanLaunchServiceParkingPreference -Name $name -Key $row.key -ParkWhenIdle $parkWhenIdle -DataRoot $DataRoot -Adapter $Adapter -Confirm:$false | Out-Null
            Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $DataRoot -SelectName $name
            Update-LeanLaunchGuiApplicationDetail -Window $window -DataRoot $DataRoot
            Write-LeanLaunchGuiLog $window "Idle parking for $($row.resourceType) '$($row.name)' set to: $parkWhenIdle"
        }
        catch { Write-LeanLaunchGuiLog $window "Error: $($_.Exception.Message)" }
    }.GetNewClosure())

    $window.FindName('BuildProfileButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        try {
            $confirmer = {
                param($applicationName)
                $choice = [System.Windows.MessageBox]::Show(
                    "A profile named '$applicationName' already exists. Overwrite it with a profile built from the currently reviewed resources?",
                    'Overwrite existing profile', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
                return ($choice -eq [System.Windows.MessageBoxResult]::Yes)
            }
            $result = Invoke-LeanLaunchGuiProfileBuild -Name $name -DataRoot $DataRoot -Confirmer $confirmer
            if ($result.status -eq 'Canceled') {
                Write-LeanLaunchGuiLog $window "Profile build for '$name' canceled: the existing profile was not overwritten."
                return
            }
            Update-LeanLaunchGuiApplicationList -Window $window -DataRoot $DataRoot -SelectName $name
            Write-LeanLaunchGuiLog $window "Profile written: $($result.path.FullName)"
            if (@($result.skippedResidualProcesses).Count) {
                Write-LeanLaunchGuiLog $window ("Skipped (no executable path on record): " + ($result.skippedResidualProcesses -join ', '))
            }
        }
        catch { Write-LeanLaunchGuiLog $window "Error: $($_.Exception.Message)" }
    }.GetNewClosure())

    $window.FindName('DryRunButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        try {
            $application = Import-LeanLaunchApplication -Name $name -DataRoot $DataRoot
            $run = Invoke-LeanLaunchApplicationRun -Name $name -DataRoot $DataRoot -RepositoryRoot $RepositoryRoot -Adapter $Adapter -DryRun
            if ($application.policy -eq 'Unmanaged') {
                $window.FindName('PlanText').Text = [string]$run.plan
            }
            else {
                $lines = Get-LeanLaunchRunPlanSummaryLines -Plan $run.plan -Policy 'Managed'
                $window.FindName('PlanText').Text = ($lines -join "`r`n")
            }
            Write-LeanLaunchGuiLog $window 'Dry run computed. No process was started and no service was changed.'
        }
        catch { Write-LeanLaunchGuiLog $window "Error: $($_.Exception.Message)" }
    }.GetNewClosure())

    $window.FindName('LaunchButton').Add_Click({
        $name = Get-LeanLaunchGuiSelectedApplicationName $window
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        try {
            $run = Start-LeanLaunchGuiApplication -Name $name -DataRoot $DataRoot -RepositoryRoot $RepositoryRoot -Adapter $Adapter
            $window.FindName('PlanText').Text = ($run | ConvertTo-Json -Depth 6)
            if ($run.status -eq 'SupervisorStarted') {
                Write-LeanLaunchGuiLog $window "Managed supervisor started (PID $($run.processId)). This window remains responsive; completion is recorded at $($run.logPath)"
            }
            else {
                Write-LeanLaunchGuiLog $window "Run finished with status: $($run.status)"
            }
        }
        catch { Write-LeanLaunchGuiLog $window "Error: $($_.Exception.Message)" }
    }.GetNewClosure())

    $window.Add_Closing({
        # Closing this window ends the process (no resident component is ever installed) - an active
        # scan's runspace/pipeline/timer must never survive that close, hung collector or not.
        Stop-LeanLaunchGuiActiveScan
    }.GetNewClosure())

    if ($SmokeTest) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(400)
        $timer.Add_Tick({
            $timer.Stop()
            $window.Close()
        }.GetNewClosure())
        $window.Add_Loaded({ $timer.Start() }.GetNewClosure())
    }

    [void]$window.ShowDialog()
}
