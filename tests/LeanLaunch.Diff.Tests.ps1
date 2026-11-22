. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'LeanLaunch snapshot comparison' {
    It 'reports process count/resource deltas and service state changes' {
        $before = [pscustomobject]@{
            schemaVersion = 1
            processes = @([pscustomobject]@{ name='app'; id=1; path='C:\app.exe'; workingSetBytes=100 })
            services = @([pscustomobject]@{ name='VendorSvc'; status='Stopped'; startType='Manual' })
            startupEntries = @()
            scheduledTasks = @()
            collectionErrors = @()
        }
        $after = [pscustomobject]@{
            schemaVersion = 1
            processes = @(
                [pscustomobject]@{ name='app'; id=1; path='C:\app.exe'; workingSetBytes=20971620 },
                [pscustomobject]@{ name='helper'; id=2; path='C:\helper.exe'; workingSetBytes=200 }
            )
            services = @([pscustomobject]@{ name='VendorSvc'; status='Running'; startType='Manual' })
            startupEntries = @([pscustomobject]@{ location='HKCU'; name='Updater'; command='update.exe' })
            scheduledTasks = @([pscustomobject]@{ taskPath='\'; taskName='Update'; state='Ready' })
            collectionErrors = @()
        }
        $diff = Compare-LeanLaunchSnapshot -Before $before -After $after
        ($diff.processChanges | Where-Object name -eq 'helper').countDelta | Should Be 1
        ($diff.processChanges | Where-Object name -eq 'app').workingSetDeltaBytes | Should Be 20971520
        $diff.serviceChanges[0].beforeStatus | Should Be 'Stopped'
        $diff.serviceChanges[0].afterStatus | Should Be 'Running'
        $diff.addedStartupEntries.Count | Should Be 1
        $diff.addedScheduledTasks.Count | Should Be 1
    }

    It 'ignores small working-set jitter when process counts are unchanged' {
        $before = [pscustomobject]@{ schemaVersion=1; processes=@([pscustomobject]@{name='browser';id=7;path='C:\browser.exe';workingSetBytes=100000000}); services=@(); startupEntries=@(); scheduledTasks=@(); collectionErrors=@() }
        $after = [pscustomobject]@{ schemaVersion=1; processes=@([pscustomobject]@{name='browser';id=7;path='C:\browser.exe';workingSetBytes=101000000}); services=@(); startupEntries=@(); scheduledTasks=@(); collectionErrors=@() }
        (Compare-LeanLaunchSnapshot $before $after).processChanges.Count | Should Be 0
    }

    It 'reports removed process groups' {
        $before = [pscustomobject]@{ schemaVersion=1; processes=@([pscustomobject]@{name='old';id=7;path='';workingSetBytes=10}); services=@(); startupEntries=@(); scheduledTasks=@(); collectionErrors=@() }
        $after = [pscustomobject]@{ schemaVersion=1; processes=@(); services=@(); startupEntries=@(); scheduledTasks=@(); collectionErrors=@() }
        (Compare-LeanLaunchSnapshot $before $after).processChanges[0].countDelta | Should Be -1
    }

    It 'treats startup entries for different users as distinct' {
        $before = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@([pscustomobject]@{location='HKCU';name='Updater';command='update.exe';user='alice'});scheduledTasks=@();collectionErrors=@()}
        $after = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@([pscustomobject]@{location='HKCU';name='Updater';command='update.exe';user='bob'});scheduledTasks=@();collectionErrors=@()}
        $diff = Compare-LeanLaunchSnapshot $before $after
        $diff.addedStartupEntries.Count | Should Be 1
        $diff.removedStartupEntries.Count | Should Be 1
    }

    It 'labels collectionErrors provenance as before or after without dropping the original collector/message fields' {
        $before = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@([pscustomobject]@{collector='Services';message='boom-before'})}
        $after = [pscustomobject]@{schemaVersion=1;processes=@();services=@();startupEntries=@();scheduledTasks=@();collectionErrors=@([pscustomobject]@{collector='Processes';message='boom-after'})}
        $diff = Compare-LeanLaunchSnapshot -Before $before -After $after
        @($diff.collectionErrors).Count | Should Be 2
        ($diff.collectionErrors | Where-Object collector -eq 'Services').source | Should Be 'before'
        ($diff.collectionErrors | Where-Object collector -eq 'Services').message | Should Be 'boom-before'
        ($diff.collectionErrors | Where-Object collector -eq 'Processes').source | Should Be 'after'
        ($diff.collectionErrors | Where-Object collector -eq 'Processes').message | Should Be 'boom-after'
    }
}
