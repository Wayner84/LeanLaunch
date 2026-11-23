Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-LeanLaunchNormalizedCollectorResults {
    <#
    Wraps BOTH invoking a collector and normalizing its raw results in one failure boundary. A
    collector that throws outright and a collector that returns superficially valid objects whose
    VALUES fail to normalize - a non-numeric ProcessId, for example, which throws only once the
    [int]/[long]/etc. cast in $Normalizer runs - are treated identically: the specific failure is
    recorded as one collectionErrors entry for this resource type, and every OTHER collector's
    evidence is completely unaffected. Without this, a normalization failure would propagate uncaught
    out of New-LeanLaunchSnapshot entirely, losing every other collector's evidence too instead of
    degrading to partial evidence for just the one resource type that failed.
    #>
    param(
        [scriptblock]$Collector,
        [string]$Name,
        [System.Collections.ArrayList]$Errors,
        [scriptblock]$Normalizer
    )
    try {
        $raw = @(& $Collector)
        return @($raw | ForEach-Object -Process $Normalizer)
    }
    catch {
        [void]$Errors.Add([pscustomobject]@{ collector = $Name; message = $_.Exception.Message })
        return @()
    }
}

function New-LeanLaunchSnapshot {
    [CmdletBinding()]
    param([hashtable]$Collectors)

    if ($null -eq $Collectors) {
        $Collectors = @{
            Processes = {
                Get-CimInstance Win32_Process | Select-Object Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine, WorkingSetSize
            }
            Services = {
                Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, ProcessId
            }
            Startup = {
                Get-CimInstance Win32_StartupCommand | Select-Object Location, Name, Command, User
            }
            ScheduledTasks = {
                if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
                    Get-ScheduledTask | Select-Object TaskPath, TaskName, State
                }
            }
        }
    }

    $errors = New-Object System.Collections.ArrayList
    $processes = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.Processes -Name 'Processes' -Errors $errors -Normalizer {
        # Every mandatory field is explicitly checked for presence, a non-null value, AND an accepted
        # runtime type before any cast is attempted - a field that is merely missing or null (as
        # opposed to present but wrong-typed) would otherwise cast silently ($null -> '' or 0), and a
        # numeric-looking STRING (or any other object) would otherwise be silently coerced by [int]/
        # [string]/[long] rather than surfaced as the malformed evidence it actually is.
        # ExecutablePath/Path is the one field exempted from the non-null rule: real Windows processes
        # (System Idle Process, System, Registry, Secure System, Memory Compression) legitimately
        # report a null path, so that field only requires the property to exist at all (a collector
        # that omits BOTH alternates entirely is still malformed) and, when present, to be a string.
        if (-not (Test-LeanLaunchHasProperty $_ 'Name') -or $null -eq $_.Name) { throw 'Process collector entry is missing a name.' }
        if ($_.Name -isnot [string]) { throw 'Process collector entry has a non-string name.' }
        $hasProcessId = (Test-LeanLaunchHasProperty $_ 'ProcessId') -and $null -ne $_.ProcessId
        $hasId = (Test-LeanLaunchHasProperty $_ 'Id') -and $null -ne $_.Id
        if (-not $hasProcessId -and -not $hasId) { throw 'Process collector entry is missing a process ID.' }
        $id = if ($hasProcessId) { $_.ProcessId } else { $_.Id }
        if (-not (Test-LeanLaunchAcceptedNumericValue $id)) { throw 'Process collector entry has a non-numeric process ID.' }
        $hasExecutablePathProperty = Test-LeanLaunchHasProperty $_ 'ExecutablePath'
        $hasPathProperty = Test-LeanLaunchHasProperty $_ 'Path'
        if (-not $hasExecutablePathProperty -and -not $hasPathProperty) { throw 'Process collector entry is missing an executable path.' }
        $path = if ($hasExecutablePathProperty -and $null -ne $_.ExecutablePath) { $_.ExecutablePath } elseif ($hasPathProperty) { $_.Path } else { $null }
        if ($null -ne $path -and $path -isnot [string]) { throw 'Process collector entry has a non-string executable path.' }
        $hasWorkingSetSize = (Test-LeanLaunchHasProperty $_ 'WorkingSetSize') -and $null -ne $_.WorkingSetSize
        $hasWorkingSet64 = (Test-LeanLaunchHasProperty $_ 'WorkingSet64') -and $null -ne $_.WorkingSet64
        if (-not $hasWorkingSetSize -and -not $hasWorkingSet64) { throw 'Process collector entry is missing a working-set size.' }
        $workingSet = if ($hasWorkingSetSize) { $_.WorkingSetSize } else { $_.WorkingSet64 }
        if (-not (Test-LeanLaunchAcceptedNumericValue $workingSet)) { throw 'Process collector entry has a non-numeric working-set size.' }
        [pscustomobject]@{
            name = [string]$_.Name
            id = [int]$id
            parentId = if (Test-LeanLaunchHasProperty $_ 'ParentProcessId') { [int]$_.ParentProcessId } else { 0 }
            path = [string]$path
            commandLine = if (Test-LeanLaunchHasProperty $_ 'CommandLine') { [string]$_.CommandLine } else { '' }
            workingSetBytes = [long]$workingSet
        }
    } | Sort-Object name, id)

    $services = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.Services -Name 'Services' -Errors $errors -Normalizer {
        if (-not (Test-LeanLaunchHasProperty $_ 'Name') -or $null -eq $_.Name) { throw 'Service collector entry is missing a name.' }
        if ($_.Name -isnot [string]) { throw 'Service collector entry has a non-string name.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'DisplayName') -or $null -eq $_.DisplayName) { throw 'Service collector entry is missing a display name.' }
        if ($_.DisplayName -isnot [string]) { throw 'Service collector entry has a non-string display name.' }
        $hasState = (Test-LeanLaunchHasProperty $_ 'State') -and $null -ne $_.State
        $hasStatus = (Test-LeanLaunchHasProperty $_ 'Status') -and $null -ne $_.Status
        if (-not $hasState -and -not $hasStatus) { throw 'Service collector entry is missing a status.' }
        $status = if ($hasState) { $_.State } else { $_.Status }
        if ($status -isnot [string]) { throw 'Service collector entry has a non-string status.' }
        $hasStartMode = (Test-LeanLaunchHasProperty $_ 'StartMode') -and $null -ne $_.StartMode
        $hasStartType = (Test-LeanLaunchHasProperty $_ 'StartType') -and $null -ne $_.StartType
        if (-not $hasStartMode -and -not $hasStartType) { throw 'Service collector entry is missing a start type.' }
        $startType = if ($hasStartMode) { $_.StartMode } else { $_.StartType }
        if ($startType -isnot [string]) { throw 'Service collector entry has a non-string start type.' }
        [pscustomobject]@{
            name = [string]$_.Name
            displayName = [string]$_.DisplayName
            status = [string]$status
            startType = [string]$startType
            processId = if ((Test-LeanLaunchHasProperty $_ 'ProcessId') -and $null -ne $_.ProcessId) {
                if (-not (Test-LeanLaunchAcceptedNumericValue $_.ProcessId)) { throw 'Service collector entry has a non-numeric process ID.' }
                [int]$_.ProcessId
            } else { 0 }
        }
    } | Sort-Object name)

    $startup = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.Startup -Name 'Startup' -Errors $errors -Normalizer {
        if (-not (Test-LeanLaunchHasProperty $_ 'Location') -or $null -eq $_.Location) { throw 'Startup collector entry is missing a location.' }
        if ($_.Location -isnot [string]) { throw 'Startup collector entry has a non-string location.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'Name') -or $null -eq $_.Name) { throw 'Startup collector entry is missing a name.' }
        if ($_.Name -isnot [string]) { throw 'Startup collector entry has a non-string name.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'Command') -or $null -eq $_.Command) { throw 'Startup collector entry is missing a command.' }
        if ($_.Command -isnot [string]) { throw 'Startup collector entry has a non-string command.' }
        $startupUser = ''
        if ((Test-LeanLaunchHasProperty $_ 'User') -and $null -ne $_.User) {
            if ($_.User -isnot [string]) { throw 'Startup collector entry has a non-string user.' }
            $startupUser = [string]$_.User
        }
        [pscustomobject]@{ location = [string]$_.Location; name = [string]$_.Name; command = [string]$_.Command; user = $startupUser }
    } | Sort-Object location, name)

    $tasks = @(Get-LeanLaunchNormalizedCollectorResults -Collector $Collectors.ScheduledTasks -Name 'ScheduledTasks' -Errors $errors -Normalizer {
        if (-not (Test-LeanLaunchHasProperty $_ 'TaskPath') -or $null -eq $_.TaskPath) { throw 'ScheduledTask collector entry is missing a task path.' }
        if ($_.TaskPath -isnot [string]) { throw 'ScheduledTask collector entry has a non-string task path.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'TaskName') -or $null -eq $_.TaskName) { throw 'ScheduledTask collector entry is missing a task name.' }
        if ($_.TaskName -isnot [string]) { throw 'ScheduledTask collector entry has a non-string task name.' }
        if (-not (Test-LeanLaunchHasProperty $_ 'State') -or $null -eq $_.State) { throw 'ScheduledTask collector entry is missing a state.' }
        # Real Get-ScheduledTask returns State as a generated enum type (ScheduledTask.StateEnum), not
        # a plain string - a genuinely well-typed representation of state, not the kind of sneaky
        # coercion (a numeric-looking string standing in for a number) this strict typing guards
        # against. Both a string and an enum are accepted; anything else (a bare int, say) is not.
        if ($_.State -isnot [string] -and $_.State -isnot [System.Enum]) { throw 'ScheduledTask collector entry has a non-string, non-enum state.' }
        [pscustomobject]@{ taskPath = [string]$_.TaskPath; taskName = [string]$_.TaskName; state = [string]$_.State }
    } | Sort-Object taskPath, taskName)

    [pscustomobject]@{
        schemaVersion = 1
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        computerName = $env:COMPUTERNAME
        processes = $processes
        services = $services
        startupEntries = $startup
        scheduledTasks = $tasks
        collectionErrors = @($errors)
    }
}

function Save-LeanLaunchSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DataRoot
    )
    if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Snapshot name is invalid.' }
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    New-Item -ItemType Directory -Path $paths.Snapshots -Force | Out-Null
    $path = Join-Path $paths.Snapshots ($Name + '.json')
    Write-LeanLaunchJsonAtomic -Path $path -InputObject $Snapshot -Depth 8 | Out-Null
    return Get-Item -LiteralPath $path
}

function Import-LeanLaunchSnapshot {
    [CmdletBinding()]
    param([string]$Name, [string]$Path, [string]$DataRoot)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Snapshot name is invalid.' }
        $Path = Join-Path (Get-LeanLaunchPaths -DataRoot $DataRoot).Snapshots ($Name + '.json')
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Snapshot not found: $Path" }
    try {
        $snapshot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Snapshot is not valid JSON: $Path. $($_.Exception.Message)"
    }
    Test-LeanLaunchRequiredProperties $snapshot @('schemaVersion', 'processes', 'services', 'startupEntries', 'scheduledTasks', 'collectionErrors') 'Snapshot'
    Test-LeanLaunchPropertyType $snapshot 'schemaVersion' 'Int' 'Snapshot'
    if ($snapshot.schemaVersion -ne 1) { throw 'Unsupported snapshot schema version.' }
    foreach ($arrayProperty in @('processes', 'services', 'startupEntries', 'scheduledTasks', 'collectionErrors')) {
        Test-LeanLaunchPropertyType $snapshot $arrayProperty 'Array' 'Snapshot'
    }
    foreach ($process in @($snapshot.processes)) {
        Test-LeanLaunchRequiredProperties $process @('name', 'id', 'parentId', 'path', 'commandLine', 'workingSetBytes') 'Snapshot process entry'
        Test-LeanLaunchPropertyType $process 'name' 'String' 'Snapshot process entry'
        Test-LeanLaunchPropertyType $process 'path' 'String' 'Snapshot process entry'
        Test-LeanLaunchPropertyType $process 'commandLine' 'String' 'Snapshot process entry'
        if (-not (Test-LeanLaunchAcceptedNumericValue $process.id)) { throw "Snapshot process entry property 'id' must be a genuine numeric value." }
        if (-not (Test-LeanLaunchAcceptedNumericValue $process.parentId)) { throw "Snapshot process entry property 'parentId' must be a genuine numeric value." }
        if (-not (Test-LeanLaunchAcceptedNumericValue $process.workingSetBytes)) { throw "Snapshot process entry property 'workingSetBytes' must be a genuine numeric value." }
    }
    foreach ($service in @($snapshot.services)) {
        Test-LeanLaunchRequiredProperties $service @('name', 'displayName', 'status', 'startType', 'processId') 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'name' 'String' 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'displayName' 'String' 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'status' 'String' 'Snapshot service entry'
        Test-LeanLaunchPropertyType $service 'startType' 'String' 'Snapshot service entry'
        if (-not (Test-LeanLaunchAcceptedNumericValue $service.processId)) { throw "Snapshot service entry property 'processId' must be a genuine numeric value." }
    }
    foreach ($startupEntry in @($snapshot.startupEntries)) {
        Test-LeanLaunchRequiredProperties $startupEntry @('location', 'name', 'command', 'user') 'Snapshot startup entry'
        foreach ($stringProperty in @('location', 'name', 'command', 'user')) {
            Test-LeanLaunchPropertyType $startupEntry $stringProperty 'String' 'Snapshot startup entry'
        }
    }
    foreach ($task in @($snapshot.scheduledTasks)) {
        Test-LeanLaunchRequiredProperties $task @('taskPath', 'taskName', 'state') 'Snapshot scheduled task entry'
        foreach ($stringProperty in @('taskPath', 'taskName', 'state')) {
            Test-LeanLaunchPropertyType $task $stringProperty 'String' 'Snapshot scheduled task entry'
        }
    }
    foreach ($collectionError in @($snapshot.collectionErrors)) {
        Test-LeanLaunchRequiredProperties $collectionError @('collector', 'message') 'Snapshot collection-error entry'
        Test-LeanLaunchPropertyType $collectionError 'collector' 'String' 'Snapshot collection-error entry'
        Test-LeanLaunchPropertyType $collectionError 'message' 'String' 'Snapshot collection-error entry'
    }
    return $snapshot
}

function Get-LeanLaunchProcessGroups {
    param($Processes)
    $groups = @{}
    foreach ($process in @($Processes)) {
        $key = (([string]$process.name).ToLowerInvariant() + '|' + ([string]$process.path).ToLowerInvariant())
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ name=[string]$process.name; path=[string]$process.path; count=0; workingSetBytes=[long]0 }
        }
        $groups[$key].count++
        $groups[$key].workingSetBytes += [long]$process.workingSetBytes
    }
    return $groups
}

function Get-LeanLaunchKeyedRecords {
    param($Records, [scriptblock]$KeySelector)
    $index = @{}
    foreach ($record in @($Records)) { $index[(& $KeySelector $record)] = $record }
    return $index
}

function Compare-LeanLaunchSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]$Before,
        [Parameter(Mandatory = $true, Position = 1)]$After
    )
    Test-LeanLaunchPropertyType $Before 'schemaVersion' 'Int' 'Snapshot'
    Test-LeanLaunchPropertyType $After 'schemaVersion' 'Int' 'Snapshot'
    if ($Before.schemaVersion -ne 1 -or $After.schemaVersion -ne 1) { throw 'Unsupported snapshot schema version.' }

    $beforeProcesses = Get-LeanLaunchProcessGroups $Before.processes
    $afterProcesses = Get-LeanLaunchProcessGroups $After.processes
    $processChanges = @()
    foreach ($key in @($beforeProcesses.Keys + $afterProcesses.Keys | Sort-Object -Unique)) {
        $beforeItem = $beforeProcesses[$key]
        $afterItem = $afterProcesses[$key]
        $beforeCount = if ($null -eq $beforeItem) { 0 } else { $beforeItem.count }
        $afterCount = if ($null -eq $afterItem) { 0 } else { $afterItem.count }
        $beforeMemory = if ($null -eq $beforeItem) { 0 } else { $beforeItem.workingSetBytes }
        $afterMemory = if ($null -eq $afterItem) { 0 } else { $afterItem.workingSetBytes }
        $name = if ($null -ne $afterItem) { $afterItem.name } else { $beforeItem.name }
        $path = if ($null -ne $afterItem) { $afterItem.path } else { $beforeItem.path }
        $memoryDelta = [long]$afterMemory - [long]$beforeMemory
        if ($beforeCount -ne $afterCount -or [Math]::Abs($memoryDelta) -ge 10MB) {
            $processChanges += [pscustomobject]@{
                name=$name; path=$path; beforeCount=$beforeCount; afterCount=$afterCount
                countDelta=($afterCount-$beforeCount); workingSetDeltaBytes=$memoryDelta
            }
        }
    }

    $beforeServices = Get-LeanLaunchKeyedRecords $Before.services { param($x) ([string]$x.name).ToLowerInvariant() }
    $afterServices = Get-LeanLaunchKeyedRecords $After.services { param($x) ([string]$x.name).ToLowerInvariant() }
    $serviceChanges = @()
    foreach ($key in @($beforeServices.Keys + $afterServices.Keys | Sort-Object -Unique)) {
        $b = $beforeServices[$key]; $a = $afterServices[$key]
        $beforeStatus = if ($null -eq $b) { '<missing>' } else { [string]$b.status }
        $afterStatus = if ($null -eq $a) { '<missing>' } else { [string]$a.status }
        $beforeStart = if ($null -eq $b) { '<missing>' } else { [string]$b.startType }
        $afterStart = if ($null -eq $a) { '<missing>' } else { [string]$a.startType }
        if ($beforeStatus -ne $afterStatus -or $beforeStart -ne $afterStart) {
            $serviceChanges += [pscustomobject]@{
                name=if ($null -ne $a) { $a.name } else { $b.name }
                beforeStatus=$beforeStatus; afterStatus=$afterStatus
                beforeStartType=$beforeStart; afterStartType=$afterStart
            }
        }
    }

    $beforeStartup = Get-LeanLaunchKeyedRecords $Before.startupEntries { param($x) $user = if (Test-LeanLaunchHasProperty $x 'user') { [string]$x.user } else { '' }; (([string]$x.location)+'|'+([string]$x.name)+'|'+([string]$x.command)+'|'+$user).ToLowerInvariant() }
    $afterStartup = Get-LeanLaunchKeyedRecords $After.startupEntries { param($x) $user = if (Test-LeanLaunchHasProperty $x 'user') { [string]$x.user } else { '' }; (([string]$x.location)+'|'+([string]$x.name)+'|'+([string]$x.command)+'|'+$user).ToLowerInvariant() }
    $beforeTasks = Get-LeanLaunchKeyedRecords $Before.scheduledTasks { param($x) (([string]$x.taskPath)+'|'+([string]$x.taskName)).ToLowerInvariant() }
    $afterTasks = Get-LeanLaunchKeyedRecords $After.scheduledTasks { param($x) (([string]$x.taskPath)+'|'+([string]$x.taskName)).ToLowerInvariant() }

    [pscustomobject]@{
        schemaVersion = 1
        comparedAtUtc = [DateTime]::UtcNow.ToString('o')
        processChanges = @($processChanges | Sort-Object countDelta, workingSetDeltaBytes -Descending)
        serviceChanges = @($serviceChanges | Sort-Object name)
        addedStartupEntries = @($afterStartup.Keys | Where-Object { -not $beforeStartup.ContainsKey($_) } | ForEach-Object { $afterStartup[$_] })
        removedStartupEntries = @($beforeStartup.Keys | Where-Object { -not $afterStartup.ContainsKey($_) } | ForEach-Object { $beforeStartup[$_] })
        addedScheduledTasks = @($afterTasks.Keys | Where-Object { -not $beforeTasks.ContainsKey($_) } | ForEach-Object { $afterTasks[$_] })
        removedScheduledTasks = @($beforeTasks.Keys | Where-Object { -not $afterTasks.ContainsKey($_) } | ForEach-Object { $beforeTasks[$_] })
        # Each entry keeps its original 'collector'/'message' fields (existing consumers - the CLI's
        # collector-name warning included - keep working unchanged) and gains a 'source' field so a
        # reviewer can tell which snapshot a given collector failure came from without guessing.
        collectionErrors = @(
            @($Before.collectionErrors | ForEach-Object { [pscustomobject]@{ source = 'before'; collector = $_.collector; message = $_.message } }) +
            @($After.collectionErrors | ForEach-Object { [pscustomobject]@{ source = 'after'; collector = $_.collector; message = $_.message } })
        )
    }
}

# --- Application records: policy toggle + enforced before/after audit workflow -----------------
#
# An "application" record ties a reviewed install together: which resources a before/after snapshot
# diff surfaced, how each was classified, and one explicit policy toggle (Managed/Unmanaged). This is
# the shared model consumed by both the CLI and the GUI so lifecycle logic is never duplicated.
#
# Safety invariant encoded here: startup entries and scheduled tasks can only ever be marked
# Reviewed/Unreviewed, never Managed - LeanLaunch never disables autoruns or scheduled tasks, so the
# classification vocabulary itself makes that action impossible to request.
