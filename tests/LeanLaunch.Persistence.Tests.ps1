. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'LeanLaunch atomic JSON persistence primitive' {
    It 'writes a new destination file with no leftover temp file' {
        $root = Join-Path $FixtureRoot 'atomic-new'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 1 }) -Depth 4
        Test-Path -LiteralPath $path | Should Be $true
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 1
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count | Should Be 0
    }

    It 'creates the target directory when it does not yet exist' {
        $root = Join-Path $FixtureRoot 'atomic-newdir'
        $path = Join-Path (Join-Path $root 'nested') 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 1 }) -Depth 4
        Test-Path -LiteralPath $path | Should Be $true
    }

    It 'replaces an existing destination file using IO.File.Replace semantics with no leftover temp file' {
        $root = Join-Path $FixtureRoot 'atomic-replace'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 1 }) -Depth 4
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 2 }) -Depth 4
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 2
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count | Should Be 0
    }

    It 'leaves the original destination untouched when the write is interrupted before commit' {
        $root = Join-Path $FixtureRoot 'atomic-interrupted'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'original' }) -Depth 4
        {
            Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'new' }) -Depth 4 `
                -TestHookBeforeCommit { throw 'simulated crash before rename' }
        } | Should Throw
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 'original'
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count | Should Be 0
    }

    It 'leaves no destination file behind when a brand-new write is interrupted before commit' {
        $root = Join-Path $FixtureRoot 'atomic-interrupted-new'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        {
            Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'new' }) -Depth 4 `
                -TestHookBeforeCommit { throw 'simulated crash before rename' }
        } | Should Throw
        Test-Path -LiteralPath $path | Should Be $false
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count | Should Be 0
    }

    It 'still validates the application name before any write reaches the atomic primitive' {
        $root = Join-Path $FixtureRoot 'atomic-app-containment'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $application = [pscustomobject]@{ name = '..\escaped' }
        { Save-LeanLaunchApplication -Application $application -DataRoot $root } | Should Throw
        Test-Path -LiteralPath (Join-Path $FixtureRoot 'escaped.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root 'apps') | Should Be $false
    }

    It 'refuses to write through a reparse point anywhere in the destination path chain' {
        $root = Join-Path $FixtureRoot 'atomic-reparse'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $target = Join-Path $FixtureRoot 'atomic-reparse-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $junctionDir = Join-Path $root 'linked'
        New-Item -ItemType Junction -Path $junctionDir -Target $target | Out-Null
        $path = Join-Path $junctionDir 'record.json'
        { Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 1 }) -Depth 4 } | Should Throw
        Test-Path -LiteralPath $path | Should Be $false
    }

    It 'refuses a compare-and-swap write when the destination content changed since it was expected' {
        $root = Join-Path $FixtureRoot 'atomic-cas-mismatch'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'original' }) -Depth 4
        $staleExpected = Get-Content -LiteralPath $path -Raw
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'changed-by-someone-else' }) -Depth 4

        { Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'new' }) -Depth 4 -RequireUnchanged -ExpectedCurrentContent $staleExpected } | Should Throw
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 'changed-by-someone-else'
    }

    It 'allows a compare-and-swap write when the destination content still matches what was expected' {
        $root = Join-Path $FixtureRoot 'atomic-cas-match'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'original' }) -Depth 4
        $expected = Get-Content -LiteralPath $path -Raw
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'new' }) -Depth 4 -RequireUnchanged -ExpectedCurrentContent $expected
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 'new'
    }

    It 'allows a compare-and-swap write when the destination is expected to be absent and still is' {
        $root = Join-Path $FixtureRoot 'atomic-cas-absent'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 1 }) -Depth 4 -RequireUnchanged -ExpectedCurrentContent $null
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 1
    }

    It 'refuses a compare-and-swap write when the destination is expected to be absent but now exists' {
        $root = Join-Path $FixtureRoot 'atomic-cas-unexpected-exists'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'surprise' }) -Depth 4
        { Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 1 }) -Depth 4 -RequireUnchanged -ExpectedCurrentContent $null } | Should Throw
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 'surprise'
    }

    It 'does not require the destination to be unchanged when -RequireUnchanged is omitted' {
        $root = Join-Path $FixtureRoot 'atomic-cas-not-requested'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'original' }) -Depth 4
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'changed-by-someone-else' }) -Depth 4
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'plain-overwrite' }) -Depth 4
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 'plain-overwrite'
    }

    It 'Save-LeanLaunchApplication refuses a compare-and-swap write when the record changed concurrently' {
        $root = Join-Path $FixtureRoot 'save-application-cas'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'demo' -Executable $exe -DataRoot $root | Out-Null
        $loaded = Import-LeanLaunchApplicationForUpdate -Name 'demo' -DataRoot $root

        # Someone else (another CLI invocation, the GUI) saves a change in between this read and write.
        $concurrent = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $concurrent.displayName = 'changed-concurrently'
        Save-LeanLaunchApplication -Application $concurrent -DataRoot $root | Out-Null

        $loaded.Application.displayName = 'this-write-should-be-refused'
        { Save-LeanLaunchApplication -Application $loaded.Application -DataRoot $root -ExpectedCurrentContent $loaded.RawContent } | Should Throw
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).displayName | Should Be 'changed-concurrently'
    }

    It 'Save-LeanLaunchApplication performs a plain overwrite when -ExpectedCurrentContent is not supplied' {
        $root = Join-Path $FixtureRoot 'save-application-no-cas'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $exe = Join-Path $root 'demo.exe'
        Set-Content -LiteralPath $exe -Value 'fixture'
        New-LeanLaunchApplication -Name 'demo' -Executable $exe -DataRoot $root | Out-Null
        $application = Import-LeanLaunchApplication -Name 'demo' -DataRoot $root
        $application.displayName = 'updated'
        Save-LeanLaunchApplication -Application $application -DataRoot $root | Out-Null
        (Import-LeanLaunchApplication -Name 'demo' -DataRoot $root).displayName | Should Be 'updated'
    }

    It 'returns the exact SHA-256 hash of the bytes it wrote, computed from the write buffer rather than a post-write re-read' {
        $root = Join-Path $FixtureRoot 'atomic-returned-hash'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        $result = Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'hash-me' }) -Depth 4
        $result.Path | Should Be $path
        $result.ContentHash | Should Be (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $result.ContentHash | Should Match '^[0-9A-F]{64}$'
    }

    It 'serializes writes to the same path against a concurrent lock holder and only proceeds once it releases (cooperating-writer CAS)' {
        $root = Join-Path $FixtureRoot 'atomic-lock-contention'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $path = Join-Path $root 'record.json'
        Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'original' }) -Depth 4 | Out-Null
        $lockPath = $path + '.lock'
        $sentinelPath = Join-Path $root 'lock-acquired.sentinel'

        # A real, separate process holds the exact same sidecar lock file this function uses, so this
        # proves genuine OS-level mutual exclusion across process boundaries - not merely in-process
        # cooperation - matching the real GUI-process/CLI-process concurrency this protects against.
        $job = Start-Job -ScriptBlock {
            param($lockPath, $sentinelPath)
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            Set-Content -LiteralPath $sentinelPath -Value 'locked'
            Start-Sleep -Milliseconds 1000
            $stream.Dispose()
        } -ArgumentList $lockPath, $sentinelPath

        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (-not (Test-Path -LiteralPath $sentinelPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Test-Path -LiteralPath $sentinelPath | Should Be $true

            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            Write-LeanLaunchJsonAtomic -Path $path -InputObject ([pscustomobject]@{ a = 'after-wait' }) -Depth 4 | Out-Null
            $stopwatch.Stop()

            (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).a | Should Be 'after-wait'
            $stopwatch.Elapsed.TotalMilliseconds | Should BeGreaterThan 400
        }
        finally {
            Wait-Job -Job $job -Timeout 5 | Out-Null
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}
