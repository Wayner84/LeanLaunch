. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

function New-LeanLaunchTestApp {
    param([string]$Name = 'testapp', [string]$Root = $FixtureRoot)
    $exe = Join-Path $Root ($Name + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) { Set-Content -LiteralPath $exe -Value 'fixture' }
    New-LeanLaunchApplication -Name $Name -Executable $exe -DataRoot $Root | Out-Null
    return $exe
}

Describe 'LeanLaunch application records' {
    It 'creates an application defaulting to the Unmanaged policy' {
        $root = Join-Path $FixtureRoot 'app-new'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.policy | Should Be 'Unmanaged'
        $application.profileName | Should Be $null
    }

    It 'does not create an application when -WhatIf is used' {
        $root = Join-Path $FixtureRoot 'app-whatif'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'whatif.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        $result = New-LeanLaunchApplication -Name 'whatif' -Executable $exe -DataRoot $root -WhatIf
        $result | Should Be $null
        Test-Path -LiteralPath (Join-Path (Join-Path $root 'apps') 'whatif.json') | Should Be $false
    }

    It 'refuses to overwrite an existing application without -Force' {
        $root = Join-Path $FixtureRoot 'app-duplicate'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $exe = Join-Path $root 'demo.exe'
        { New-LeanLaunchApplication -Name 'demo' -Executable $exe -DataRoot $root } | Should Throw
    }

    It 'rejects non-string top-level executable-policy and identity fields without coercion' {
        $root = Join-Path $FixtureRoot 'app-strict-top-level-types'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        $forgedPath = Join-Path $paths.Apps 'demo.json'
        foreach ($property in @('name','displayName','executable','policy','createdAtUtc','updatedAtUtc')) {
            $record = [ordered]@{
                schemaVersion=1; name='demo'; displayName='demo'; executable='C:\demo.exe'; policy='Unmanaged'
                profileName=$null; profileAuditId=$null; profileContentHash=$null; currentAudit=$null
                auditHistory=@(); parkedServices=@(); createdAtUtc='x'; updatedAtUtc='x'
            }
            $record[$property] = 123
            $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $forgedPath -Encoding UTF8
            { Import-LeanLaunchApplication -Name 'demo' -DataRoot $root } | Should Throw
        }
    }

    It 'rejects a forged application name and cannot save outside the apps directory' {
        $root = Join-Path $FixtureRoot 'app-forged-name'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        $forgedPath = Join-Path $paths.Apps 'demo.json'
        [ordered]@{
            schemaVersion=1; name='..\profiles\victim'; displayName='forged'; executable='C:\forged.exe';
            policy='Unmanaged'; profileName=$null; currentAudit=$null; auditHistory=@(); createdAtUtc='x'; updatedAtUtc='x'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $forgedPath -Encoding UTF8

        { Import-LeanLaunchApplication -Name 'demo' -DataRoot $root } | Should Throw
        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy Managed -DataRoot $root -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'profiles\victim.json') | Should Be $false
    }

    It 'rejects a forged or malformed profileAuditId' {
        $root = Join-Path $FixtureRoot 'app-forged-profile-audit-id'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        $forgedPath = Join-Path $paths.Apps 'demo.json'
        [ordered]@{
            schemaVersion=1; name='demo'; displayName='demo'; executable='C:\forged.exe';
            policy='Managed'; profileName='demo'; profileAuditId='not-a-guid'; currentAudit=$null; auditHistory=@(); createdAtUtc='x'; updatedAtUtc='x'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $forgedPath -Encoding UTF8

        { Import-LeanLaunchApplication -Name 'demo' -DataRoot $root } | Should Throw
    }

    It 'rejects a hand-edited profileContentHash that is not a well-formed SHA-256 hex string' {
        $root = Join-Path $FixtureRoot 'app-forged-profile-content-hash'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        $forgedPath = Join-Path $paths.Apps 'demo.json'
        [ordered]@{
            schemaVersion=1; name='demo'; displayName='demo'; executable='C:\forged.exe'
            policy='Managed'; profileName='demo'; profileAuditId=([Guid]::NewGuid().ToString()); profileContentHash='not-a-hash'
            currentAudit=$null; auditHistory=@(); parkedServices=@(); createdAtUtc='x'; updatedAtUtc='x'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $forgedPath -Encoding UTF8

        { Import-LeanLaunchApplication -Name 'demo' -DataRoot $root } | Should Throw
    }

    It 'rejects a hand-edited classification entry with a decision that is not valid for its resourceType' {
        $root = Join-Path $FixtureRoot 'app-forged-classification-decision'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        $forgedPath = Join-Path $paths.Apps 'demo.json'
        [ordered]@{
            schemaVersion=1; name='demo'; displayName='demo'; executable='C:\forged.exe'
            policy='Unmanaged'; profileName=$null; profileAuditId=$null; profileContentHash=$null
            currentAudit=[ordered]@{
                auditId=([Guid]::NewGuid().ToString()); beforeSnapshot='b'; afterSnapshot='a'; auditPath='p'
                startedAtUtc='x'; completedAtUtc='x'
                classifications=@([ordered]@{
                    key='StartupEntry|hkcu|x'; resourceType='StartupEntry'; name='x'; path='x.exe'
                    evidence='e'; decision='Managed'; note=''; updatedAtUtc='x'
                })
            }
            auditHistory=@(); parkedServices=@(); createdAtUtc='x'; updatedAtUtc='x'
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $forgedPath -Encoding UTF8

        # A StartupEntry can never legitimately be Managed - the classification vocabulary itself
        # makes this impossible through the guided write paths, so a hand-edit claiming it must fail
        # to load rather than silently expand what Managed execution could ever touch.
        { Import-LeanLaunchApplication -Name 'demo' -DataRoot $root } | Should Throw
    }

    It 'rejects a hand-edited classification entry whose Service name is not a syntactically valid service name' {
        $root = Join-Path $FixtureRoot 'app-forged-classification-service-name'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        $forgedPath = Join-Path $paths.Apps 'demo.json'
        [ordered]@{
            schemaVersion=1; name='demo'; displayName='demo'; executable='C:\forged.exe'
            policy='Unmanaged'; profileName=$null; profileAuditId=$null; profileContentHash=$null
            currentAudit=[ordered]@{
                auditId=([Guid]::NewGuid().ToString()); beforeSnapshot='b'; afterSnapshot='a'; auditPath='p'
                startedAtUtc='x'; completedAtUtc='x'
                classifications=@([ordered]@{
                    key='Service|bad'; resourceType='Service'; name='bad; Stop-Service evil'; path=$null
                    evidence='e'; decision='Managed'; note=''; updatedAtUtc='x'
                })
            }
            auditHistory=@(); parkedServices=@(); createdAtUtc='x'; updatedAtUtc='x'
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $forgedPath -Encoding UTF8

        { Import-LeanLaunchApplication -Name 'demo' -DataRoot $root } | Should Throw
    }

    It 'rejects a hand-edited parkedServices entry whose name is not a syntactically valid service name' {
        $root = Join-Path $FixtureRoot 'app-forged-parked-service-name'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        $forgedPath = Join-Path $paths.Apps 'demo.json'
        [ordered]@{
            schemaVersion=1; name='demo'; displayName='demo'; executable='C:\forged.exe'
            policy='Unmanaged'; profileName=$null; profileAuditId=$null; profileContentHash=$null
            currentAudit=$null; auditHistory=@()
            parkedServices=@([ordered]@{ name='bad name!'; originalStartMode='Auto'; parkedAtUtc='x'; currentlyParked=$true })
            createdAtUtc='x'; updatedAtUtc='x'
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $forgedPath -Encoding UTF8

        { Import-LeanLaunchApplication -Name 'demo' -DataRoot $root } | Should Throw
    }

    It 'surfaces a malformed application record in the list rather than silently hiding it' {
        $root = Join-Path $FixtureRoot 'app-malformed-surfaced'
        $paths = Get-LeanLaunchPaths -DataRoot $root
        New-Item -ItemType Directory -Path $paths.Apps -Force | Out-Null
        New-LeanLaunchTestApp -Name 'good' -Root $root
        $forgedPath = Join-Path $paths.Apps 'corrupt.json'
        '{ this is not valid json' | Set-Content -LiteralPath $forgedPath -Encoding UTF8

        $applications = @(Get-LeanLaunchApplications -DataRoot $root)
        @($applications).Count | Should Be 2
        $malformed = $applications | Where-Object { $_.name -eq 'corrupt' }
        $malformed | Should Not Be $null
        $malformed.isMalformed | Should Be $true
        [string]::IsNullOrWhiteSpace($malformed.malformedReason) | Should Be $false

        $rows = Get-LeanLaunchApplicationSummaryRows -Applications $applications
        $malformedRow = $rows | Where-Object { $_.name -eq 'corrupt' }
        $malformedRow.policy | Should Be 'Malformed'
        $malformedRow.auditStatus | Should Be 'Malformed'
        $goodRow = $rows | Where-Object { $_.name -eq 'good' }
        $goodRow.policy | Should Be 'Unmanaged'
    }

    It 'returns an empty list without throwing when no applications exist' {
        $root = Join-Path $FixtureRoot 'app-empty-list'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $applications = @(Get-LeanLaunchApplications -DataRoot $root)
        $applications.Count | Should Be 0
        $rows = Get-LeanLaunchApplicationSummaryRows -Applications $applications
        @($rows).Count | Should Be 0
    }

    It 'rejects an invalid policy value' {
        $root = Join-Path $FixtureRoot 'app-bad-policy'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'SortOf' -DataRoot $root } | Should Throw
    }

    It 'toggles policy between Managed and Unmanaged' {
        $root = Join-Path $FixtureRoot 'app-toggle-policy'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).policy | Should Be 'Managed'
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Unmanaged' -DataRoot $root -Confirm:$false | Out-Null
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).policy | Should Be 'Unmanaged'
    }
}

Describe 'LeanLaunch enforced before/after audit workflow' {
    $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }

    It 'always captures a brand-new before snapshot, never reusing an old name' {
        $root = Join-Path $FixtureRoot 'audit-fresh-baseline'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $first = New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false
        Start-Sleep -Seconds 1
        $second = New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false
        $first.snapshotName | Should Not Be $second.snapshotName
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.currentAudit.beforeSnapshot | Should Be $second.snapshotName
        @($application.auditHistory).Count | Should Be 1
    }

    It 'keeps snapshot names unique for rapid repeated captures within one second' {
        $root = Join-Path $FixtureRoot 'audit-rapid-baseline'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $names = @(
            (New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false).snapshotName
            (New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false).snapshotName
        )
        @($names | Select-Object -Unique).Count | Should Be 2
    }

    It 'refuses to capture an after-install scan with no active before baseline' {
        $root = Join-Path $FixtureRoot 'audit-no-baseline'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        { Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false } | Should Throw
    }

    It 'refuses to complete an audit when any collector failed' {
        $root = Join-Path $FixtureRoot 'audit-collector-failure'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root | Out-Null
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $failedCollectors = @{ Processes={ throw 'process collector failed' }; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        { Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $failedCollectors -Confirm:$false } | Should Throw
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).currentAudit.afterSnapshot | Should Be $null
    }

    It 'refuses to start a new before-install baseline when any collector failed' {
        $root = Join-Path $FixtureRoot 'audit-before-collector-failure'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root | Out-Null
        $failedCollectors = @{ Processes={ throw 'process collector failed' }; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        { New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $failedCollectors -Confirm:$false } | Should Throw
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).currentAudit | Should Be $null
    }

    It 'surfaces new services, growing process groups, and added startup entries as candidates' {
        $root = Join-Path $FixtureRoot 'audit-candidates'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @([pscustomobject]@{Name='helper';ProcessId=5;ParentProcessId=1;ExecutablePath='C:\Vendor\helper.exe';CommandLine='';WorkingSetSize=1000}) }
            Services = { @([pscustomobject]@{Name='VendorSvc';DisplayName='Vendor';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @([pscustomobject]@{Location='HKCU';Name='VendorTask';Command='C:\Vendor\task.exe';User='me'}) }
            ScheduledTasks = { @() }
        }
        $result = Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false
        $classifications = $result.application.currentAudit.classifications
        @($classifications | Where-Object { $_.resourceType -eq 'Service' -and $_.name -eq 'VendorSvc' }).Count | Should Be 1
        @($classifications | Where-Object { $_.resourceType -eq 'Process' -and $_.name -eq 'helper' }).Count | Should Be 1
        @($classifications | Where-Object { $_.resourceType -eq 'StartupEntry' -and $_.name -eq 'VendorTask' }).Count | Should Be 1
        @($classifications | Where-Object { $_.decision -ne 'Unreviewed' }).Count | Should Be 0
    }

    It 'refuses to complete an audit twice against the same before baseline without a fresh rescan' {
        $root = Join-Path $FixtureRoot 'audit-single-use-baseline'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='VendorSvc';DisplayName='Vendor';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $firstAuditId = (Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false).application.currentAudit.auditId
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|vendorsvc' -Decision 'Managed' -Note 'ok' -DataRoot $root -Confirm:$false | Out-Null

        # A second scan-after against the SAME (already-completed) before baseline - without a fresh
        # before-install scan in between - must be refused outright: this is exactly the path that
        # previously let new evidence silently coexist with an already-reviewed, possibly-Managed
        # profile binding without invalidating anything.
        { Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false } | Should Throw

        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.currentAudit.auditId | Should Be $firstAuditId
        ($application.currentAudit.classifications | Where-Object { $_.key -eq 'Service|vendorsvc' }).decision | Should Be 'Managed'
    }

    It 'carries forward the previous audit''s classification decision when a fresh baseline rediscovers the same resource' {
        $root = Join-Path $FixtureRoot 'audit-carry-forward-history'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='VendorSvc';DisplayName='Vendor';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        $firstAuditId = (Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false).application.currentAudit.auditId
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|vendorsvc' -Decision 'Managed' -Note 'ok' -DataRoot $root -Confirm:$false | Out-Null

        # The ONLY legitimate way to get new evidence: a fresh before-install baseline. This mints a
        # new auditId and archives the completed audit into history.
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $rescanned = Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false
        $secondAuditId = $rescanned.application.currentAudit.auditId

        $secondAuditId | Should Not Be $firstAuditId
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        @($application.auditHistory).Count | Should Be 1
        ($application.auditHistory[0]).auditId | Should Be $firstAuditId
        # The reviewer's prior decision for the SAME resource carries forward into the new audit cycle.
        ($application.currentAudit.classifications | Where-Object { $_.key -eq 'Service|vendorsvc' }).decision | Should Be 'Managed'
    }

    It 'does not invalidate a bound profile when reclassifying to the same decision' {
        $root = Join-Path $FixtureRoot 'audit-idempotent-reclassify'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @() }
            Services = { @([pscustomobject]@{Name='VendorSvc';DisplayName='Vendor';State='Running';StartMode='Automatic';ProcessId=10}) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|vendorsvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy Managed -DataRoot $root -Confirm:$false | Out-Null

        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|vendorsvc' -Decision 'Managed' -Note 'still fine' -DataRoot $root -Confirm:$false | Out-Null
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.policy | Should Be 'Managed'
        $application.profileName | Should Be 'demo'
    }
}

Describe 'LeanLaunch resource classification safety rules' {
    $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
    $afterCollectors = @{
        Processes = { @() }
        Services = { @([pscustomobject]@{Name='VendorSvc';DisplayName='Vendor';State='Running';StartMode='Automatic';ProcessId=10}) }
        Startup = { @([pscustomobject]@{Location='HKCU';Name='VendorTask';Command='C:\Vendor\task.exe';User='me'}) }
        ScheduledTasks = { @([pscustomobject]@{TaskPath='\';TaskName='VendorTask';State='Ready'}) }
    }

    function New-LeanLaunchClassifiedFixture {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $Root
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $Root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $Root -Collectors $afterCollectors -Confirm:$false | Out-Null
    }

    It 'never allows a startup entry to be classified Managed' {
        $root = Join-Path $FixtureRoot 'classify-startup-reject'
        New-LeanLaunchClassifiedFixture -Root $root
        { Set-LeanLaunchResourceClassification -Name 'demo' -Key 'StartupEntry|hkcu|vendortask' -Decision 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'never allows a scheduled task to be classified Managed' {
        $root = Join-Path $FixtureRoot 'classify-task-reject'
        New-LeanLaunchClassifiedFixture -Root $root
        { Set-LeanLaunchResourceClassification -Name 'demo' -Key 'ScheduledTask|\|vendortask' -Decision 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'allows a startup entry to be marked Reviewed' {
        $root = Join-Path $FixtureRoot 'classify-startup-reviewed'
        New-LeanLaunchClassifiedFixture -Root $root
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'StartupEntry|hkcu|vendortask' -Decision 'Reviewed' -Note 'vendor updater' -DataRoot $root -Confirm:$false | Out-Null
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        ($application.currentAudit.classifications | Where-Object { $_.resourceType -eq 'StartupEntry' }).decision | Should Be 'Reviewed'
    }

    It 'allows a service to be classified Managed or Unmanaged' {
        $root = Join-Path $FixtureRoot 'classify-service'
        New-LeanLaunchClassifiedFixture -Root $root
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|vendorsvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).currentAudit.classifications[0].decision | Should Be 'Managed'
    }

    It 'rejects an unknown classification key' {
        $root = Join-Path $FixtureRoot 'classify-unknown-key'
        New-LeanLaunchClassifiedFixture -Root $root
        { Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|doesnotexist' -Decision 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }
}

Describe 'LeanLaunch profile generation from reviewed resources' {
    It 'refuses profile generation before the after scan and while any candidate is unreviewed' {
        $root = Join-Path $FixtureRoot 'profile-incomplete-review'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        { New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false } | Should Throw
        $after = @{ Processes={@()}; Services={@([pscustomobject]@{Name='VendorSvc';DisplayName='Vendor';State='Running';StartMode='Automatic';ProcessId=9})}; Startup={@()}; ScheduledTasks={@()} }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $after -Confirm:$false | Out-Null
        { New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'includes only Managed services and processes, excluding reviewed Unmanaged resources' {
        $root = Join-Path $FixtureRoot 'profile-from-review'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $afterCollectors = @{
            Processes = { @([pscustomobject]@{Name='helper';ProcessId=5;ParentProcessId=1;ExecutablePath='C:\Vendor\helper.exe';CommandLine='';WorkingSetSize=1000}) }
            Services = { @(
                [pscustomobject]@{Name='ManagedSvc';DisplayName='Managed';State='Running';StartMode='Automatic';ProcessId=10},
                [pscustomobject]@{Name='UnmanagedSvc';DisplayName='Unmanaged';State='Running';StartMode='Automatic';ProcessId=11}
            ) }
            Startup = { @() }; ScheduledTasks = { @() }
        }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $afterCollectors -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|managedsvc' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|unmanagedsvc' -Decision 'Unmanaged' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Process|helper|c:\vendor\helper.exe' -Decision 'Managed' -DataRoot $root -Confirm:$false | Out-Null

        $result = New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false
        $profile = Import-LeanLaunchProfile -Path $result.path.FullName -SkipExecutableCheck
        $profile.services | Should Be @('ManagedSvc')
        $profile.residualProcesses.Count | Should Be 1
        $profile.residualProcesses[0].name | Should Be 'helper'
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).profileName | Should Be 'demo'
    }

    It 'invalidates the generated profile and Managed policy when a decision or baseline changes' {
        $root = Join-Path $FixtureRoot 'profile-invalidation'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $after = @{ Processes={@()}; Services={@([pscustomobject]@{Name='VendorSvc';DisplayName='Vendor';State='Running';StartMode='Automatic';ProcessId=10})}; Startup={@()}; ScheduledTasks={@()} }
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $after -Confirm:$false | Out-Null
        foreach ($item in @(Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).currentAudit.classifications) {
            Set-LeanLaunchResourceClassification -Name 'demo' -Key $item.key -Decision 'Unmanaged' -DataRoot $root -Confirm:$false | Out-Null
        }
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy Managed -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchResourceClassification -Name 'demo' -Key 'Service|vendorsvc' -Decision Managed -DataRoot $root -Confirm:$false | Out-Null
        $changed = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $changed.policy | Should Be 'Unmanaged'
        $changed.profileName | Should Be $null

        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Force -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy Managed -DataRoot $root -Confirm:$false | Out-Null
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        $reAudit = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $reAudit.policy | Should Be 'Unmanaged'
        $reAudit.profileName | Should Be $null
    }

    It 'refuses to overwrite an existing profile without -Force' {
        $root = Join-Path $FixtureRoot 'profile-no-overwrite'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        { New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false } | Should Throw
    }
}

Describe 'LeanLaunch application launch policy enforcement' {
    It 'launches an Unmanaged application directly with no service or cleanup action' {
        $root = Join-Path $FixtureRoot 'run-unmanaged'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $calls = New-Object System.Collections.ArrayList
        $adapter = @{
            GetService={[void]$calls.Add('GetService')}; StartService={[void]$calls.Add('StartService')}; StopService={[void]$calls.Add('StopService')}
            GetProcesses={[void]$calls.Add('GetProcesses'); @()}
            StartProcess={ param($exe,$args,$wd) [void]$calls.Add("StartProcess:$exe"); [pscustomobject]@{Id=42;Name='demo';CreationDate='main'} }
            WaitProcess={[void]$calls.Add('WaitProcess')}; StopProcess={[void]$calls.Add('StopProcess')}
        }
        $run = Invoke-LeanLaunchApplicationRun -Name 'demo' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $adapter
        $run.status | Should Be 'UnmanagedLaunch'
        $run.processId | Should Be 42
        @($calls | Where-Object { $_ -like 'StartProcess:*' }).Count | Should Be 1
        $calls -contains 'GetService' | Should Be $false
        $calls -contains 'StartService' | Should Be $false
        $calls -contains 'GetProcesses' | Should Be $false
    }

    It 'does not start a process for an Unmanaged dry run' {
        $root = Join-Path $FixtureRoot 'run-unmanaged-dryrun'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $calls = New-Object System.Collections.ArrayList
        $adapter = @{ StartProcess={ [void]$calls.Add('StartProcess'); [pscustomobject]@{Id=1;Name='demo';CreationDate='x'} } }
        $run = Invoke-LeanLaunchApplicationRun -Name 'demo' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $adapter -DryRun
        $run.status | Should Be 'DryRun'
        $calls.Count | Should Be 0
    }

    It 'refuses to enable Managed policy without a complete profile bound to the current audit' {
        $root = Join-Path $FixtureRoot 'run-managed-no-profile'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'delegates a Managed run to the shared run lifecycle and tags the result' {
        $root = Join-Path $FixtureRoot 'run-managed-with-profile'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false | Out-Null

        $adapter = @{
            GetService={}; StartService={}; StopService={}; GetProcesses={@()}
            StartProcess={ [pscustomobject]@{Id=77;Name='demo';CreationDate='main'} }
            WaitProcess={}; StopProcess={}
        }
        $run = Invoke-LeanLaunchApplicationRun -Name 'demo' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $adapter
        $run.status | Should Be 'Completed'
        $run.applicationName | Should Be 'demo'
        $run.policy | Should Be 'Managed'
    }

    It 'refuses to enable Managed policy when the generated profile file was tampered with before activation' {
        $root = Join-Path $FixtureRoot 'policy-managed-profile-tampered'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        # Same file name, same declared audit binding fields - but the bytes on disk no longer match
        # what New-LeanLaunchApplicationProfile actually generated and hashed.
        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.services = @('InjectedService')
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'refuses Managed policy when the bound profile executable was hand-edited, even though services/residualProcesses still match' {
        $root = Join-Path $FixtureRoot 'policy-managed-executable-tampered'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.executable = Join-Path $root 'not-the-reviewed-executable.exe'
        Set-Content -LiteralPath $tampered.executable -Value 'decoy' -Force
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'refuses Managed policy when the bound profile has injected arguments not part of the reviewed generation template' {
        $root = Join-Path $FixtureRoot 'policy-managed-arguments-tampered'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.arguments = @('/injected-flag')
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'refuses Managed policy when the bound profile working directory was hand-edited' {
        $root = Join-Path $FixtureRoot 'policy-managed-workdir-tampered'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.workingDirectory = $root
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'refuses Managed policy when the bound profile displayName was hand-edited' {
        $root = Join-Path $FixtureRoot 'policy-managed-displayname-tampered'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.displayName = 'Something else entirely'
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'refuses Managed policy when the bound profile adds waitForProcessNames not part of the reviewed generation template' {
        $root = Join-Path $FixtureRoot 'policy-managed-waitnames-tampered'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.waitForProcessNames = @('injected')
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'refuses Managed policy when the bound profile cleanup flags were weakened by a hand-edit' {
        $root = Join-Path $FixtureRoot 'policy-managed-cleanup-tampered'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.cleanup.stopResidualProcesses = $false
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        { Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false } | Should Throw
    }

    It 'returns a self-contained validated profile object that does not depend on the file still existing afterward (proves no re-read after validation)' {
        $root = Join-Path $FixtureRoot 'binding-no-second-read'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false | Out-Null

        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $profile = Get-LeanLaunchValidatedManagedProfile -Application $application -DataRoot $root
        $profile | Should Not Be $null

        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        Remove-Item -LiteralPath $profilePath -Force
        Test-Path -LiteralPath $profilePath | Should Be $false

        $adapter = @{
            GetService={}; StartService={}; StopService={}; GetProcesses={@()}
            StartProcess={ [pscustomobject]@{Id=77;Name='demo';CreationDate='main'} }
            WaitProcess={}; StopProcess={}
        }
        $run = Invoke-LeanLaunchRun -Profile $profile -Adapter $adapter
        $run.status | Should Be 'Completed'
    }

    It 'fails closed at Managed run time when the bound profile file is replaced after being generated' {
        $root = Join-Path $FixtureRoot 'run-managed-profile-replaced'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'demo' -Policy 'Managed' -DataRoot $root -Confirm:$false | Out-Null

        # A profile that validated at the moment policy flipped to Managed is not trusted forever -
        # replacing the file afterwards (same name, different content, e.g. a new service injected)
        # must be caught the next time this application is actually run, not just at policy-change time.
        $profilePath = Join-Path (Join-Path $root 'profiles') 'demo.json'
        $tampered = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $tampered.services = @('InjectedService')
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

        $adapter = @{
            GetService={}; StartService={}; StopService={}; GetProcesses={@()}
            StartProcess={ [pscustomobject]@{Id=77;Name='demo';CreationDate='main'} }
            WaitProcess={}; StopProcess={}
        }
        { Invoke-LeanLaunchApplicationRun -Name 'demo' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $adapter } | Should Throw
    }

    It 'fails closed when a hand-edited application record claims Managed with a matching auditId but the profile does not reflect the reviewed decision set' {
        $root = Join-Path $FixtureRoot 'run-managed-forged-record'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'demo' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'demo' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'demo' -DataRoot $root -Confirm:$false | Out-Null

        # Hand-edit the application record directly: claim Managed, keep the REAL profileAuditId and
        # profileContentHash (so an ID-only or hash-only check would be fooled), but inject a new
        # Managed service classification the profile file was never regenerated to include.
        $appPath = Join-Path (Join-Path $root 'apps') 'demo.json'
        $forged = Get-Content -LiteralPath $appPath -Raw | ConvertFrom-Json
        $forged.policy = 'Managed'
        $forged.currentAudit.classifications += [pscustomobject]@{
            key='Service|injectedsvc'; resourceType='Service'; name='InjectedSvc'; path=$null
            evidence='forged'; decision='Managed'; note=''; updatedAtUtc=(Get-Date).ToString('o'); parkWhenIdle=$false
        }
        $forged | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $appPath -Encoding UTF8

        $adapter = @{
            GetService={}; StartService={}; StopService={}; GetProcesses={@()}
            StartProcess={ [pscustomobject]@{Id=77;Name='demo';CreationDate='main'} }
            WaitProcess={}; StopProcess={}
        }
        { Invoke-LeanLaunchApplicationRun -Name 'demo' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $adapter } | Should Throw
    }

    It 'never falls back to a same-named repository profile for a Managed run when the bound user profile is missing' {
        $root = Join-Path $FixtureRoot 'run-managed-no-repo-fallback'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-LeanLaunchTestApp -Name 'example' -Root $root
        $emptyCollectors = @{ Processes={@()}; Services={@()}; Startup={@()}; ScheduledTasks={@()} }
        New-LeanLaunchApplicationBeforeSnapshot -Name 'example' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        Complete-LeanLaunchApplicationAudit -Name 'example' -DataRoot $root -Collectors $emptyCollectors -Confirm:$false | Out-Null
        New-LeanLaunchApplicationProfile -Name 'example' -DataRoot $root -Confirm:$false | Out-Null
        Set-LeanLaunchApplicationPolicy -Name 'example' -Policy 'Managed' -DataRoot $root -Confirm:$false | Out-Null

        # Delete the bound (user) profile. The repository ships an unrelated profiles/example.json
        # template with the same name - a Managed run must never silently fall back to it.
        Remove-Item -LiteralPath (Join-Path (Join-Path $root 'profiles') 'example.json') -Force

        $adapter = @{
            GetService={}; StartService={}; StopService={}; GetProcesses={@()}
            StartProcess={ [pscustomobject]@{Id=77;Name='example';CreationDate='main'} }
            WaitProcess={}; StopProcess={}
        }
        { Invoke-LeanLaunchApplicationRun -Name 'example' -DataRoot $root -RepositoryRoot $ProjectRoot -Adapter $adapter } | Should Throw
    }
}

Describe 'LeanLaunch GUI/CLI shared view-model helpers' {
    It 'reports safety warnings for an Unmanaged application' {
        $application = [pscustomobject]@{ policy = 'Unmanaged'; profileName = $null; currentAudit = $null }
        $warnings = @(Get-LeanLaunchApplicationSafetyWarnings -Application $application)
        $warnings.Count | Should Be 1
        $warnings[0] | Should Match 'Unmanaged'
    }

    It 'warns about a missing profile and unreviewed resources for a Managed application' {
        $application = [pscustomobject]@{
            policy = 'Managed'; profileName = $null
            currentAudit = [pscustomobject]@{ afterSnapshot = 'after-1'; classifications = @([pscustomobject]@{decision='Unreviewed'}) }
        }
        $warnings = Get-LeanLaunchApplicationSafetyWarnings -Application $application
        ($warnings -join ' ') | Should Match 'no profile'
        ($warnings -join ' ') | Should Match '1 discovered resource'
    }

    It 'computes audit status transitions' {
        Get-LeanLaunchApplicationAuditStatus ([pscustomobject]@{ currentAudit = $null }) | Should Be 'NoAudit'
        Get-LeanLaunchApplicationAuditStatus ([pscustomobject]@{ currentAudit = [pscustomobject]@{ afterSnapshot = $null; classifications = @() } }) | Should Be 'BeforeCaptured'
        Get-LeanLaunchApplicationAuditStatus ([pscustomobject]@{ currentAudit = [pscustomobject]@{ afterSnapshot = 'a'; classifications = @([pscustomobject]@{decision='Unreviewed'}) } }) | Should Be 'AwaitingReview'
        Get-LeanLaunchApplicationAuditStatus ([pscustomobject]@{ currentAudit = [pscustomobject]@{ afterSnapshot = 'a'; classifications = @([pscustomobject]@{decision='Managed'}) } }) | Should Be 'Reviewed'
    }

    It 'builds summary rows without throwing for an empty or null application list' {
        @(Get-LeanLaunchApplicationSummaryRows -Applications @()).Count | Should Be 0
        @(Get-LeanLaunchApplicationSummaryRows -Applications $null).Count | Should Be 0
    }

    It 'renders an Unmanaged run plan as a single explanatory line' {
        $lines = @(Get-LeanLaunchRunPlanSummaryLines -Plan 'Launch directly' -Policy 'Unmanaged')
        $lines.Count | Should Be 1
        $lines[0] | Should Match 'Unmanaged'
    }

    It 'renders a Managed run plan with services and residual process rules' {
        $plan = [pscustomobject]@{
            profile='demo'; executable='C:\demo.exe'; servicesToStart=@('Svc1'); servicesAlreadyRunning=@()
            residualProcessRules=@([pscustomobject]@{name='helper';executablePath='C:\helper.exe'})
        }
        $lines = Get-LeanLaunchRunPlanSummaryLines -Plan $plan -Policy 'Managed'
        ($lines -join ' ') | Should Match 'Svc1'
        ($lines -join ' ') | Should Match 'helper'
    }
}
