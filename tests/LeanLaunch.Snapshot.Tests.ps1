. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'LeanLaunch snapshots' {
    It 'builds a schema-versioned normalized snapshot from collectors' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'helper'; Id = 42; Path = 'C:\App\helper.exe'; WorkingSet64 = 2048; CPU = 1.5 }) }
            Services = { @([pscustomobject]@{ Name = 'SvcB'; DisplayName = 'Service B'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @([pscustomobject]@{ Location = 'HKCU'; Name = 'Updater'; Command = 'updater.exe' }) }
            ScheduledTasks = { @([pscustomobject]@{ TaskPath = '\Vendor\'; TaskName = 'Update'; State = 'Ready' }) }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.schemaVersion | Should Be 1
        $snapshot.processes[0].name | Should Be 'helper'
        $snapshot.processes[0].workingSetBytes | Should Be 2048
        $snapshot.services[0].startType | Should Be 'Automatic'
        $snapshot.startupEntries.Count | Should Be 1
        $snapshot.scheduledTasks.Count | Should Be 1
    }

    It 'records a collector error and preserves other collectors evidence when a collector returns values that fail to normalize' {
        $collectors = @{
            # ProcessId 'not-a-number' fails the [int]$id cast inside the Processes normalizer, not
            # the collector invocation itself - the collector return value looks superficially fine.
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = 'not-a-number'; Path = 'C:\bad.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }
            ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
        $snapshot.services[0].name | Should Be 'GoodSvc'
    }

    It 'records a collector error and preserves other collectors evidence when a process entry is missing its name' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Id = 42; Path = 'C:\bad.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'records a collector error when a process entry has neither ProcessId nor Id (missing, not merely null)' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Path = 'C:\bad.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'records a collector error when a process entry is missing both ExecutablePath and Path' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = 42; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'records a collector error when a process entry is missing both WorkingSetSize and WorkingSet64' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = 42; Path = 'C:\bad.exe' }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'records a collector error and preserves other collectors evidence when a service entry is missing its name' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'good'; Id = 1; Path = 'C:\good.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ DisplayName = 'Bad Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.services.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Services').Count | Should Be 1
        $snapshot.processes.Count | Should Be 1
    }

    It 'records a collector error when a service entry has neither State nor Status (missing, not merely null)' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'good'; Id = 1; Path = 'C:\good.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'BadSvc'; DisplayName = 'Bad Service'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.services.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Services').Count | Should Be 1
        $snapshot.processes.Count | Should Be 1
    }

    It 'records a collector error and preserves other collectors evidence when a startup entry is missing its location' {
        $collectors = @{
            Processes = { @() }; Services = { @() }
            Startup = { @([pscustomobject]@{ Name = 'Updater'; Command = 'updater.exe' }) }
            ScheduledTasks = { @([pscustomobject]@{ TaskPath = '\'; TaskName = 'Good'; State = 'Ready' }) }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.startupEntries.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Startup').Count | Should Be 1
        $snapshot.scheduledTasks.Count | Should Be 1
    }

    It 'records a collector error and preserves other collectors evidence when a scheduled task entry is missing its state' {
        $collectors = @{
            Processes = { @() }; Services = { @() }
            Startup = { @([pscustomobject]@{ Location = 'HKCU'; Name = 'Good'; Command = 'good.exe' }) }
            ScheduledTasks = { @([pscustomobject]@{ TaskPath = '\'; TaskName = 'Bad' }) }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.scheduledTasks.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'ScheduledTasks').Count | Should Be 1
        $snapshot.startupEntries.Count | Should Be 1
    }

    It 'rejects a process entry whose ID is a numeric-looking string instead of a real integer' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = '42'; Path = 'C:\bad.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'rejects a process entry whose name is a non-string value' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 123; Id = 42; Path = 'C:\bad.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'rejects a process entry whose working-set size is a numeric-looking string instead of a real number' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = 42; Path = 'C:\bad.exe'; WorkingSet64 = '100' }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'rejects a process entry whose path is a non-string value' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'bad'; Id = 42; Path = 12345; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'GoodSvc'; DisplayName = 'Good Service'; Status = 'Running'; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.processes.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Processes').Count | Should Be 1
        $snapshot.services.Count | Should Be 1
    }

    It 'rejects a service entry whose status is a non-string value' {
        $collectors = @{
            Processes = { @([pscustomobject]@{ Name = 'good'; Id = 1; Path = 'C:\good.exe'; WorkingSet64 = 100 }) }
            Services = { @([pscustomobject]@{ Name = 'BadSvc'; DisplayName = 'Bad Service'; Status = 7; StartType = 'Automatic' }) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.services.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Services').Count | Should Be 1
        $snapshot.processes.Count | Should Be 1
    }

    It 'rejects a startup entry whose command is a non-string value' {
        $collectors = @{
            Processes = { @() }; Services = { @() }
            Startup = { @([pscustomobject]@{ Location = 'HKCU'; Name = 'Bad'; Command = 999 }) }
            ScheduledTasks = { @([pscustomobject]@{ TaskPath = '\'; TaskName = 'Good'; State = 'Ready' }) }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.startupEntries.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'Startup').Count | Should Be 1
        $snapshot.scheduledTasks.Count | Should Be 1
    }

    It 'rejects a scheduled task entry whose state is a non-string value' {
        $collectors = @{
            Processes = { @() }; Services = { @() }
            Startup = { @([pscustomobject]@{ Location = 'HKCU'; Name = 'Good'; Command = 'good.exe' }) }
            ScheduledTasks = { @([pscustomobject]@{ TaskPath = '\'; TaskName = 'Bad'; State = 42 }) }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $snapshot.scheduledTasks.Count | Should Be 0
        @($snapshot.collectionErrors | Where-Object collector -eq 'ScheduledTasks').Count | Should Be 1
        $snapshot.startupEntries.Count | Should Be 1
    }

    It 'saves and imports a named snapshot only inside the snapshot directory' {
        $collectors = @{
            Processes = { @() }; Services = { @() }; Startup = { @() }; ScheduledTasks = { @() }
        }
        $snapshot = New-LeanLaunchSnapshot -Collectors $collectors
        $file = Save-LeanLaunchSnapshot -Snapshot $snapshot -Name 'before-install' -DataRoot $FixtureRoot
        $file.FullName.StartsWith((Join-Path $FixtureRoot 'snapshots')) | Should Be $true
        (Import-LeanLaunchSnapshot -Name 'before-install' -DataRoot $FixtureRoot).schemaVersion | Should Be 1
    }

    It 'rejects unsafe snapshot names' {
        $snapshot = [pscustomobject]@{ schemaVersion = 1 }
        { Save-LeanLaunchSnapshot -Snapshot $snapshot -Name '../escape' -DataRoot $FixtureRoot } | Should Throw
    }

    It 'rejects a snapshot whose processes property is not an array' {
        $path = Join-Path $FixtureRoot 'bad-processes.json'
        '{"schemaVersion":1,"processes":{"not":"array"},"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a snapshot missing a required top-level property' {
        $path = Join-Path $FixtureRoot 'missing-property.json'
        '{"schemaVersion":1,"processes":[],"services":[],"startupEntries":[],"scheduledTasks":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a snapshot with a string schemaVersion instead of coercing it' {
        $path = Join-Path $FixtureRoot 'string-schema.json'
        '{"schemaVersion":"1","processes":[],"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a malformed snapshot service entry' {
        $path = Join-Path $FixtureRoot 'bad-service.json'
        '{"schemaVersion":1,"processes":[],"services":[{"name":"Svc"}],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot whose process id is a numeric-looking string instead of coercing it' {
        $path = Join-Path $FixtureRoot 'bad-process-id-string.json'
        '{"schemaVersion":1,"processes":[{"name":"p","id":"42","parentId":0,"path":"C:\\p.exe","commandLine":"","workingSetBytes":100}],"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot whose process parentId is a numeric-looking string instead of coercing it' {
        $path = Join-Path $FixtureRoot 'bad-parentid-string.json'
        '{"schemaVersion":1,"processes":[{"name":"p","id":42,"parentId":"0","path":"C:\\p.exe","commandLine":"","workingSetBytes":100}],"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot whose process workingSetBytes is a numeric-looking string instead of coercing it' {
        $path = Join-Path $FixtureRoot 'bad-workingset-string.json'
        '{"schemaVersion":1,"processes":[{"name":"p","id":42,"parentId":0,"path":"C:\\p.exe","commandLine":"","workingSetBytes":"100"}],"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'accepts a persisted snapshot whose process workingSetBytes exceeds Int32 range as a genuine large integer' {
        $path = Join-Path $FixtureRoot 'large-workingset.json'
        '{"schemaVersion":1,"processes":[{"name":"p","id":42,"parentId":0,"path":"C:\\p.exe","commandLine":"","workingSetBytes":9000000000}],"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        (Import-LeanLaunchSnapshot -Path $path).processes[0].workingSetBytes | Should Be 9000000000
    }

    It 'rejects a persisted snapshot whose process commandLine is a non-string value' {
        $path = Join-Path $FixtureRoot 'bad-commandline.json'
        '{"schemaVersion":1,"processes":[{"name":"p","id":42,"parentId":0,"path":"C:\\p.exe","commandLine":5,"workingSetBytes":100}],"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot whose service processId is a numeric-looking string instead of coercing it' {
        $path = Join-Path $FixtureRoot 'bad-service-processid-string.json'
        '{"schemaVersion":1,"processes":[],"services":[{"name":"Svc","displayName":"Svc","status":"Running","startType":"Auto","processId":"10"}],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot whose service displayName is a non-string value' {
        $path = Join-Path $FixtureRoot 'bad-service-displayname.json'
        '{"schemaVersion":1,"processes":[],"services":[{"name":"Svc","displayName":5,"status":"Running","startType":"Auto","processId":10}],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot startup entry missing its user field' {
        $path = Join-Path $FixtureRoot 'bad-startup-missing-user.json'
        '{"schemaVersion":1,"processes":[],"services":[],"startupEntries":[{"location":"HKCU","name":"n","command":"c.exe"}],"scheduledTasks":[],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot scheduled task entry with a non-string state' {
        $path = Join-Path $FixtureRoot 'bad-task-state.json'
        '{"schemaVersion":1,"processes":[],"services":[],"startupEntries":[],"scheduledTasks":[{"taskPath":"\\","taskName":"n","state":1}],"collectionErrors":[]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }

    It 'rejects a persisted snapshot collection-error entry missing its message field' {
        $path = Join-Path $FixtureRoot 'bad-collectionerror-missing-message.json'
        '{"schemaVersion":1,"processes":[],"services":[],"startupEntries":[],"scheduledTasks":[],"collectionErrors":[{"collector":"Processes"}]}' |
            Set-Content -LiteralPath $path
        { Import-LeanLaunchSnapshot -Path $path } | Should Throw
    }
}
