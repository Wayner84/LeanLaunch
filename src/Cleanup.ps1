Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-LeanLaunchServiceStartTypeCode {
    <#
    Maps Win32_Service.StartMode string values to the native SERVICE_*_START DWORD codes
    ChangeServiceConfig expects. The CIM string vocabulary ('Boot','System','Auto','Manual',
    'Disabled') already matches the native enum order exactly.
    #>
    param([Parameter(Mandatory = $true)][string]$StartMode)
    switch ($StartMode) {
        'Boot' { return 0 }
        'System' { return 1 }
        'Auto' { return 2 }
        'Manual' { return 3 }
        'Disabled' { return 4 }
        default { throw "Unknown service start mode: $StartMode" }
    }
}

function New-LeanLaunchDefaultAdapter {
    $adapter = @{
        IsAdministrator = {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        GetService = { param($name) Get-CimInstance Win32_Service -Filter ("Name='" + $name.Replace("'", "''") + "'") -ErrorAction Stop }
        StartService = {
            param($name)
            $controller = Get-Service -Name $name -ErrorAction Stop
            if ([string]$controller.Status -eq 'Running') { return $false }
            try {
                $controller.Start()
                $controller.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                return $true
            }
            catch {
                $current = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($null -ne $current -and [string]$current.Status -eq 'Running') { return $false }
                throw
            }
        }
        StopService = {
            param($name, $expectedProcessId, $expectedProcessCreationFileTimeUtc)
            # Query and stop through one native service handle, and additionally bind to the native
            # creation time of the process backing that PID. Holding the handle prevents a
            # delete/recreate replacement from being substituted between identity validation and stop,
            # and the creation-time check additionally closes a stop/restart-with-PID-reuse race that
            # a service-name+PID check alone cannot: a service can be stopped and a new, unrelated
            # instance can start under the same PID before this call runs.
            [LeanLaunch.NativeControl]::StopServiceIfProcessMatches([string]$name, [int]$expectedProcessId, [long]$expectedProcessCreationFileTimeUtc)
        }
        GetProcessCreationTime = {
            param($processId)
            [LeanLaunch.NativeControl]::GetProcessCreationFileTimeUtcOrZero([int]$processId)
        }
        GetServiceStartMode = {
            param($name)
            $service = Get-CimInstance Win32_Service -Filter ("Name='" + $name.Replace("'", "''") + "'") -ErrorAction Stop
            return [string]$service.StartMode
        }
        SetServiceStartMode = {
            param($name, $expectedStartMode, $newStartMode)
            # Query and change through one native service handle so an out-of-band start-mode change
            # cannot slip in between validating the recorded mode and applying the new one.
            [LeanLaunch.NativeControl]::SetServiceStartModeIfCurrentModeMatches(
                [string]$name,
                (ConvertTo-LeanLaunchServiceStartTypeCode ([string]$expectedStartMode)),
                (ConvertTo-LeanLaunchServiceStartTypeCode ([string]$newStartMode)))
        }
        GetProcesses = {
            Get-CimInstance Win32_Process | Select-Object @{N='Id';E={[int]$_.ProcessId}}, @{N='Name';E={([IO.Path]::GetFileNameWithoutExtension([string]$_.Name))}}, @{N='Path';E={[string]$_.ExecutablePath}}, @{N='ParentId';E={[int]$_.ParentProcessId}}, @{N='CreationDate';E={[string]$_.CreationDate}}, @{N='CreationFileTimeUtc';E={[LeanLaunch.NativeControl]::GetProcessCreationFileTimeUtcOrZero([int]$_.ProcessId)}}
        }
        StartProcess = {
            param($executable, $arguments, $workingDirectory)
            $parameters = @{ FilePath=$executable; PassThru=$true; ErrorAction='Stop' }
            if (@($arguments).Count -gt 0) { $parameters.ArgumentList = ConvertTo-LeanLaunchArgumentString @($arguments) }
            if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { $parameters.WorkingDirectory = $workingDirectory }
            $started = Start-Process @parameters
            # Start-Process returns a .NET Process object with no CreationDate; re-resolve through CIM so the
            # launched process carries the same WMI creation-identity shape used everywhere else for attribution.
            $identity = $null
            for ($attempt = 0; $attempt -lt 50 -and $null -eq $identity; $attempt++) {
                $identity = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$started.Id) -ErrorAction SilentlyContinue
                if ($null -eq $identity) { Start-Sleep -Milliseconds 20 }
            }
            if ($null -eq $identity) {
                $fallbackStart = $null
                try { $fallbackStart = $started.StartTime.ToUniversalTime() } catch { }
                if ($null -eq $fallbackStart) { throw "Unable to establish creation identity for launched process $([int]$started.Id)." }
                $identity = [pscustomobject]@{
                    ProcessId = [int]$started.Id
                    Name = [IO.Path]::GetFileName([string]$executable)
                    ExecutablePath = [string]$executable
                    ParentProcessId = [int]$PID
                    CreationDate = $fallbackStart.ToString('o')
                }
            }
            $nativeCreation = [LeanLaunch.NativeControl]::GetProcessCreationFileTimeUtcOrZero([int]$started.Id)
            [pscustomobject]@{
                Id = [int]$started.Id
                Name = [IO.Path]::GetFileNameWithoutExtension([string]$identity.Name)
                Path = [string]$identity.ExecutablePath
                ParentId = [int]$identity.ParentProcessId
                CreationDate = [string]$identity.CreationDate
                CreationFileTimeUtc = [long]$nativeCreation
            }
        }
        WaitProcess = {
            param($process)
            if (-not (Test-LeanLaunchHasProperty $process 'CreationFileTimeUtc') -or [long]$process.CreationFileTimeUtc -le 0) {
                Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
                return
            }
            # Bind the wait to the same native creation identity used for termination, so a PID reused
            # by an unrelated process after ours exits is never mistaken for our process still running.
            [LeanLaunch.NativeControl]::WaitForSingleObjectIfCreationMatches([int]$process.Id, [long]$process.CreationFileTimeUtc)
        }
        SleepMilliseconds = { param($milliseconds) Start-Sleep -Milliseconds $milliseconds }
        WaitProcessBounded = {
            param($process, $timeoutSeconds)
            $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
            do {
                $current = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$process.Id) -ErrorAction SilentlyContinue
                if ($null -eq $current -or [string]$current.CreationDate -ne [string]$process.CreationDate) { return $true }
                Start-Sleep -Milliseconds 200
            } while ([DateTime]::UtcNow -lt $deadline)
            return $false
        }
        StopProcess = {
            param($process)
            if (-not (Test-LeanLaunchHasProperty $process 'CreationFileTimeUtc') -or [long]$process.CreationFileTimeUtc -le 0) {
                throw "Refusing to stop process $([int]$process.Id): native creation identity is unavailable."
            }
            # Open, validate, and terminate through the same kernel handle. PID reuse between a CIM
            # check and termination therefore cannot redirect the action to a replacement process.
            [LeanLaunch.NativeControl]::TerminateProcessIfCreationMatches([int]$process.Id, [long]$process.CreationFileTimeUtc)
        }
    }
    return $adapter
}

function ConvertTo-LeanLaunchArgumentString {
    [CmdletBinding()]
    param([Parameter(Position=0)][AllowEmptyCollection()][string[]]$Arguments)
    $quoted = @()
    foreach ($argument in @($Arguments)) {
        if ($argument.Length -eq 0) { $quoted += '""'; continue }
        if ($argument -notmatch '[\s"]') { $quoted += $argument; continue }
        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') { $slashes++; continue }
            if ($character -eq '"') {
                [void]$builder.Append((@('\') * (2 * $slashes + 1)) -join '')
                [void]$builder.Append('"')
            }
            else {
                [void]$builder.Append((@('\') * $slashes) -join '')
                [void]$builder.Append($character)
            }
            $slashes = 0
        }
        [void]$builder.Append((@('\') * (2 * $slashes)) -join '')
        [void]$builder.Append('"')
        $quoted += $builder.ToString()
    }
    return ($quoted -join ' ')
}

function Get-LeanLaunchServiceStatus {
    param($Service)
    if ($null -eq $Service) { return $null }
    if (Test-LeanLaunchHasProperty $Service 'State') { return [string]$Service.State }
    if (Test-LeanLaunchHasProperty $Service 'Status') { return [string]$Service.Status }
    return $null
}

function Get-LeanLaunchServiceProcessId {
    param($Service)
    if ($null -eq $Service -or -not (Test-LeanLaunchHasProperty $Service 'ProcessId')) { return 0 }
    return [int]$Service.ProcessId
}

function Get-LeanLaunchAdapterProcessCreationTime {
    <#
    Defensive lookup used to bind service-cleanup ownership to native process creation identity
    (not service name+PID alone). Returns 0 - "unavailable" - for an adapter that does not implement
    GetProcessCreationTime at all, which the identity-bound stop call below always then refuses
    (fails closed) rather than falling back to a PID-only comparison.
    #>
    param([hashtable]$Adapter, [int]$ProcessId)
    if ($null -eq $Adapter -or -not $Adapter.ContainsKey('GetProcessCreationTime') -or $null -eq $Adapter.GetProcessCreationTime) { return 0 }
    $value = & $Adapter.GetProcessCreationTime $ProcessId
    if ($null -eq $value) { return 0 }
    return [long]$value
}

function New-LeanLaunchRunPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Profile, [hashtable]$Adapter)
    if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
    $servicesToStart = @()
    $servicesAlreadyRunning = @()
    foreach ($name in @($Profile.services)) {
        $service = & $Adapter.GetService $name
        if ((Get-LeanLaunchServiceStatus $service) -eq 'Running') { $servicesAlreadyRunning += $name }
        else { $servicesToStart += $name }
    }
    [pscustomobject]@{
        profile = $Profile.name
        executable = $Profile.executable
        arguments = @($Profile.arguments)
        workingDirectory = $Profile.workingDirectory
        servicesToStart = $servicesToStart
        servicesAlreadyRunning = $servicesAlreadyRunning
        residualProcessRules = @($Profile.residualProcesses)
    }
}

function Test-LeanLaunchProcessRule {
    param($Process, $Rule)
    $actualName = [IO.Path]::GetFileNameWithoutExtension([string]$Process.Name)
    $expectedName = [IO.Path]::GetFileNameWithoutExtension([string]$Rule.name)
    if (-not $actualName.Equals($expectedName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Rule.executablePath) -or [string]::IsNullOrWhiteSpace([string]$Process.Path)) { return $false }
    return ([IO.Path]::GetFullPath([string]$Process.Path)).TrimEnd('\').Equals(
        ([IO.Path]::GetFullPath([string]$Rule.executablePath)).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Update-LeanLaunchProcessObservations {
    <#
    Accumulates a persistent Id -> {Id;ParentId;CreationDate} map across every poll taken during a run.
    Unlike a single point-in-time snapshot, this lets ancestry be proven even after an ancestor
    (typically the launcher itself) has already exited. A PID whose CreationDate changes between
    observations has been reused by an unrelated process; it is marked $null (permanently distrusted)
    rather than overwritten, so any chain relying on it fails closed.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Observations, $Processes)
    foreach ($item in @($Processes)) {
        $id = [int]$item.Id
        $creationDate = if (Test-LeanLaunchHasProperty $item 'CreationDate') { [string]$item.CreationDate } else { '' }
        if ([string]::IsNullOrWhiteSpace($creationDate)) { continue }
        $parentId = if (Test-LeanLaunchHasProperty $item 'ParentId') { [int]$item.ParentId } else { 0 }
        if (-not $Observations.ContainsKey($id)) {
            $Observations[$id] = [pscustomobject]@{ Id = $id; ParentId = $parentId; CreationDate = $creationDate }
        }
        elseif ($null -ne $Observations[$id] -and -not ([string]$Observations[$id].CreationDate).Equals($creationDate, [StringComparison]::Ordinal)) {
            $Observations[$id] = $null
        }
    }
}

function Test-LeanLaunchDescendantProcess {
    <#
    Proves $CandidateId descends from $Root using only observations whose creation identity has
    never conflicted. Root must itself be present in $Observations with a matching CreationDate -
    if the root instance was never actually observed (or its slot was reused), attribution is refused.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Observations,
        [Parameter(Mandatory = $true)][int]$CandidateId,
        [Parameter(Mandatory = $true)]$Root
    )
    if ($null -eq $Root -or [string]::IsNullOrWhiteSpace([string]$Root.CreationDate)) { return $false }
    $rootId = [int]$Root.Id
    if ($CandidateId -eq $rootId) { return $false }
    if (-not $Observations.ContainsKey($rootId)) { return $false }
    $rootRecord = $Observations[$rootId]
    if ($null -eq $rootRecord -or -not ([string]$rootRecord.CreationDate).Equals([string]$Root.CreationDate, [StringComparison]::Ordinal)) { return $false }

    $seen = @{}
    $currentId = $CandidateId
    while ($Observations.ContainsKey($currentId) -and -not $seen.ContainsKey($currentId)) {
        $seen[$currentId] = $true
        $record = $Observations[$currentId]
        if ($null -eq $record) { return $false }
        if ($record.ParentId -eq $rootId) { return $true }
        if ($record.ParentId -le 0) { return $false }
        $currentId = [int]$record.ParentId
    }
    return $false
}

function Test-LeanLaunchSameProcessIdentity {
    param($Expected, $Actual)
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Expected.CreationDate) -or [string]::IsNullOrWhiteSpace([string]$Actual.CreationDate)) { return $false }
    return ([int]$Expected.Id -eq [int]$Actual.Id) -and
        ([string]$Expected.CreationDate).Equals([string]$Actual.CreationDate, [StringComparison]::Ordinal)
}

function Invoke-LeanLaunchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Profile,
        [hashtable]$Adapter,
        [switch]$DryRun,
        [switch]$KeepServices,
        [switch]$NoCleanup
    )
    if ($null -eq $Adapter) { $Adapter = New-LeanLaunchDefaultAdapter }
    $plan = New-LeanLaunchRunPlan -Profile $Profile -Adapter $Adapter
    if ($DryRun) {
        return [pscustomobject]@{ status='DryRun'; plan=$plan; startedServices=@(); stoppedServices=@(); stoppedProcesses=@(); cleanupErrors=@() }
    }
    if (@($plan.servicesToStart).Count -gt 0 -and $Adapter.ContainsKey('IsAdministrator') -and -not (& $Adapter.IsAdministrator)) {
        throw 'Service control requires administrator rights. Run PowerShell as Administrator, or remove services from the profile.'
    }

    $beforeProcesses = @(& $Adapter.GetProcesses)
    $beforeIds = @{}
    foreach ($process in $beforeProcesses) { $beforeIds[[int]$process.Id] = $true }
    $startedServices = New-Object System.Collections.ArrayList
    $ownedServiceInstances = New-Object System.Collections.ArrayList
    $stoppedServices = New-Object System.Collections.ArrayList
    $stoppedProcesses = New-Object System.Collections.ArrayList
    $cleanupErrors = New-Object System.Collections.ArrayList
    $launchedProcess = $null
    $status = 'Completed'
    $preserveResources = $false
    # Accumulates every process observed across the whole run so ancestry can still be proven once the
    # launched process (or an intermediate ancestor) has exited and its PID has potentially been reused.
    $observations = @{}
    $root = $null

    try {
        foreach ($service in @($plan.servicesToStart)) {
            $immediate = & $Adapter.GetService $service
            if ((Get-LeanLaunchServiceStatus $immediate) -eq 'Running') { continue }
            $startOwned = & $Adapter.StartService $service
            $started = & $Adapter.GetService $service
            $startedStatus = Get-LeanLaunchServiceStatus $started
            $startedProcessId = Get-LeanLaunchServiceProcessId $started
            if ($startedStatus -ne 'Running') {
                throw "Required service '$service' did not reach the Running state; aborting launch."
            }
            if ($startOwned -eq $true -and $startedProcessId -gt 0) {
                [void]$startedServices.Add($service)
                $ownedCreationTime = Get-LeanLaunchAdapterProcessCreationTime -Adapter $Adapter -ProcessId $startedProcessId
                [void]$ownedServiceInstances.Add([pscustomobject]@{ name=$service; processId=$startedProcessId; processCreationFileTimeUtc=$ownedCreationTime })
            }
        }
        $launchedProcess = & $Adapter.StartProcess $Profile.executable @($Profile.arguments) $Profile.workingDirectory
        if ($null -eq $launchedProcess) { throw 'The process adapter did not return a launched process.' }
        Update-LeanLaunchProcessObservations -Observations $observations -Processes @($launchedProcess)
        $launchedCreationDate = if (Test-LeanLaunchHasProperty $launchedProcess 'CreationDate') { [string]$launchedProcess.CreationDate } else { '' }
        $root = [pscustomobject]@{ Id = [int]$launchedProcess.Id; CreationDate = $launchedCreationDate }
        & $Adapter.WaitProcess $launchedProcess

        if (@($Profile.waitForProcessNames).Count -gt 0) {
            # One global deadline is shared by discovery and by every attributable descendant waited on below,
            # so N matching children cannot multiply the effective timeout to N times the bound.
            $globalDeadlineUtc = [DateTime]::UtcNow.AddSeconds(86400)
            $discoveryDeadlineUtc = [DateTime]::UtcNow.AddSeconds(30)
            if ($discoveryDeadlineUtc -gt $globalDeadlineUtc) { $discoveryDeadlineUtc = $globalDeadlineUtc }
            $matchNames = @($Profile.waitForProcessNames | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension([string]$_).ToLowerInvariant() })
            $discovered = @{}
            $quietPollsAfterDiscovery = 0
            do {
                $pollSnapshot = @(& $Adapter.GetProcesses)
                Update-LeanLaunchProcessObservations -Observations $observations -Processes $pollSnapshot
                $foundNew = $false
                foreach ($candidate in $pollSnapshot) {
                    $candidateId = [int]$candidate.Id
                    if ($discovered.ContainsKey($candidateId) -or $beforeIds.ContainsKey($candidateId)) { continue }
                    if ([string]::IsNullOrWhiteSpace([string]$candidate.CreationDate)) { continue }
                    $shortName = [IO.Path]::GetFileNameWithoutExtension([string]$candidate.Name).ToLowerInvariant()
                    if ($matchNames -notcontains $shortName) { continue }
                    if (Test-LeanLaunchDescendantProcess -Observations $observations -CandidateId $candidateId -Root $root) {
                        $discovered[$candidateId] = $candidate
                        $foundNew = $true
                    }
                }
                if ($discovered.Count -gt 0) {
                    if ($foundNew) { $quietPollsAfterDiscovery = 0 } else { $quietPollsAfterDiscovery++ }
                }
                $continueDiscovery = ([DateTime]::UtcNow -lt $discoveryDeadlineUtc) -and
                    (($discovered.Count -eq 0) -or ($quietPollsAfterDiscovery -lt 10))
                if ($continueDiscovery) {
                    if ($Adapter.ContainsKey('SleepMilliseconds')) { & $Adapter.SleepMilliseconds 500 }
                    else { Start-Sleep -Milliseconds 500 }
                }
            } while ($continueDiscovery)

            foreach ($waitProcess in $discovered.Values) {
                if ($Adapter.ContainsKey('WaitProcessBounded')) {
                    $remainingSeconds = [Math]::Max(0, [Math]::Ceiling(([TimeSpan]($globalDeadlineUtc - [DateTime]::UtcNow)).TotalSeconds))
                    $waitCompleted = & $Adapter.WaitProcessBounded $waitProcess $remainingSeconds
                    if ($waitCompleted -eq $false) {
                        $status = 'WaitTimedOut'
                        $preserveResources = $true
                    }
                }
            }
        }
    }
    catch {
        $status = 'Failed'
        throw
    }
    finally {
        if (-not $NoCleanup -and -not $preserveResources) {
            if ($Profile.cleanup.stopResidualProcesses -and $null -ne $root) {
                try {
                    $cleanupSnapshot = @(& $Adapter.GetProcesses)
                    Update-LeanLaunchProcessObservations -Observations $observations -Processes $cleanupSnapshot
                    foreach ($process in $cleanupSnapshot) {
                        if ($beforeIds.ContainsKey([int]$process.Id)) { continue }
                        foreach ($rule in @($Profile.residualProcesses)) {
                            if ((Test-LeanLaunchProcessRule $process $rule) -and
                                (-not [string]::IsNullOrWhiteSpace([string]$process.CreationDate)) -and
                                (Test-LeanLaunchDescendantProcess -Observations $observations -CandidateId ([int]$process.Id) -Root $root)) {
                                try {
                                    $revalidationSnapshot = @(& $Adapter.GetProcesses)
                                    Update-LeanLaunchProcessObservations -Observations $observations -Processes $revalidationSnapshot
                                    $current = @($revalidationSnapshot | Where-Object { [int]$_.Id -eq [int]$process.Id }) | Select-Object -First 1
                                    if ((Test-LeanLaunchSameProcessIdentity $process $current) -and
                                        (Test-LeanLaunchProcessRule $current $rule) -and
                                        (Test-LeanLaunchDescendantProcess -Observations $observations -CandidateId ([int]$current.Id) -Root $root)) {
                                        & $Adapter.StopProcess $current
                                        [void]$stoppedProcesses.Add([int]$current.Id)
                                    }
                                }
                                catch {
                                    [void]$cleanupErrors.Add([pscustomobject]@{ resourceType='Process'; resource=[string]$process.Id; message=$_.Exception.Message })
                                }
                                break
                            }
                        }
                    }
                }
                catch {
                    [void]$cleanupErrors.Add([pscustomobject]@{ resourceType='ProcessEnumeration'; resource='*'; message=$_.Exception.Message })
                }
            }
            if (-not $KeepServices -and $Profile.cleanup.stopStartedServices) {
                for ($i = $ownedServiceInstances.Count - 1; $i -ge 0; $i--) {
                    $owned = $ownedServiceInstances[$i]
                    $service = [string]$owned.name
                    try {
                        $currentService = & $Adapter.GetService $service
                        $currentStatus = Get-LeanLaunchServiceStatus $currentService
                        $currentProcessId = Get-LeanLaunchServiceProcessId $currentService
                        if ($currentStatus -eq 'Running' -and $currentProcessId -eq [int]$owned.processId) {
                            & $Adapter.StopService $service ([int]$owned.processId) ([long]$owned.processCreationFileTimeUtc)
                            [void]$stoppedServices.Add($service)
                        }
                    }
                    catch {
                        [void]$cleanupErrors.Add([pscustomobject]@{ resourceType='Service'; resource=$service; message=$_.Exception.Message })
                    }
                }
            }
            if ($cleanupErrors.Count -gt 0 -and $status -eq 'Completed') { $status = 'CleanupIncomplete' }
        }
    }

    [pscustomobject]@{
        status=$status; plan=$plan; processId=[int]$launchedProcess.Id
        startedServices=@($startedServices); stoppedServices=@($stoppedServices); stoppedProcesses=@($stoppedProcesses)
        cleanupErrors=@($cleanupErrors)
    }
}
