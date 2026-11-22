$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'LeanLaunch.psd1'
Import-Module $modulePath -Force

function ConvertTo-LeanLaunchEntryLiteral {
    param([AllowNull()][string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Test-LeanLaunchEntryAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# PowerToys Command Palette and normal shell launches are usually non-elevated. Preflight a real run
# as a dry run; only when it proves that a stopped service must be started do we request UAC and move
# the complete lifecycle into one elevated supervisor process. Running services and Unmanaged apps do
# not trigger elevation.
$entryArguments = @($args)
$commandName = if ($entryArguments.Count) { ([string]$entryArguments[0]).ToLowerInvariant() } else { '' }
$isRunCommand = $commandName -eq 'run' -or
    ($commandName -eq 'app' -and $entryArguments.Count -gt 1 -and ([string]$entryArguments[1]).ToLowerInvariant() -eq 'run')
$hasDryRun = @($entryArguments | Where-Object { ([string]$_).ToLowerInvariant() -eq '--dry-run' }).Count -gt 0
if ($isRunCommand -and -not $hasDryRun -and -not (Test-LeanLaunchEntryAdministrator)) {
    $previewArguments = @($entryArguments) + '--dry-run'
    $preview = Invoke-LeanLaunchCommand -CommandArguments $previewArguments -RepositoryRoot $PSScriptRoot
    if ($preview.exitCode -eq 0 -and $null -ne $preview.data -and
        (Test-LeanLaunchHasProperty $preview.data 'plan') -and
        @($preview.data.plan.servicesToStart).Count -gt 0) {
        $literalArguments = @($entryArguments | ForEach-Object { ConvertTo-LeanLaunchEntryLiteral ([string]$_) }) -join ','
        $scriptLiteral = ConvertTo-LeanLaunchEntryLiteral $PSCommandPath
        $elevatedCommand = "`$leanLaunchArgs = @($literalArguments); & $scriptLiteral @leanLaunchArgs; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedCommand))
        $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) `
            -Verb RunAs -WindowStyle Hidden -PassThru
        Write-Output "LeanLaunch requested administrator approval for required service control (supervisor PID $($child.Id))."
        exit 0
    }
}

$result = Invoke-LeanLaunchCommand -CommandArguments @($args) -RepositoryRoot $PSScriptRoot

if ($result.exitCode -eq 0 -and $null -ne $result.data -and (Test-LeanLaunchHasProperty $result.data 'action') -and $result.data.action -eq 'LaunchGui') {
    $guiScript = Join-Path $PSScriptRoot 'src\LeanLaunch.Gui.ps1'
    if (-not (Test-Path -LiteralPath $guiScript -PathType Leaf)) {
        Write-Error "GUI script not found: $guiScript"
        exit 1
    }
    . $guiScript
    Show-LeanLaunchGui -RepositoryRoot $PSScriptRoot
    exit 0
}

Write-Output $result.message

if ($null -ne $result.data) {
    $command = if ($args.Count -gt 0) { ([string]$args[0]).ToLowerInvariant() } else { 'help' }
    $subCommand = if ($args.Count -gt 1) { ([string]$args[1]).ToLowerInvariant() } else { '' }
    switch ($command) {
        'doctor' { $result.data | Format-List | Out-String | Write-Output }
        'list' { $result.data | Select-Object name, source, path | Format-Table -AutoSize | Out-String | Write-Output }
        'show' { $result.data | Select-Object * -ExcludeProperty sourcePath | ConvertTo-Json -Depth 8 | Write-Output }
        'diff' {
            if (@($result.data.processChanges).Count) {
                Write-Output "`nProcess changes:"
                $result.data.processChanges | Select-Object name,countDelta,workingSetDeltaBytes,path | Format-Table -AutoSize | Out-String | Write-Output
            }
            if (@($result.data.serviceChanges).Count) {
                Write-Output "`nService changes:"
                $result.data.serviceChanges | Format-Table -AutoSize | Out-String | Write-Output
            }
            if (@($result.data.addedStartupEntries).Count) {
                Write-Output "`nNew startup entries:"
                $result.data.addedStartupEntries | Format-Table -AutoSize | Out-String | Write-Output
            }
            if (@($result.data.addedScheduledTasks).Count) {
                Write-Output "`nNew scheduled tasks:"
                $result.data.addedScheduledTasks | Format-Table -AutoSize | Out-String | Write-Output
            }
            if (@($result.data.removedStartupEntries).Count) {
                Write-Output "`nRemoved startup entries:"
                $result.data.removedStartupEntries | Format-Table -AutoSize | Out-String | Write-Output
            }
            if (@($result.data.removedScheduledTasks).Count) {
                Write-Output "`nRemoved scheduled tasks:"
                $result.data.removedScheduledTasks | Format-Table -AutoSize | Out-String | Write-Output
            }
            if (@($result.data.collectionErrors).Count) {
                Write-Warning ('Some collectors failed: ' + (($result.data.collectionErrors | ForEach-Object message) -join '; '))
            }
        }
        'run' { $result.data | Select-Object status,processId,startedServices,stoppedServices,stoppedProcesses | Format-List | Out-String | Write-Output }
        'app' {
            switch ($subCommand) {
                'list' { $result.data | Format-Table -AutoSize | Out-String | Write-Output }
                'show' {
                    $result.data | Select-Object name,displayName,executable,policy,profileName | Format-List | Out-String | Write-Output
                    if ($null -ne $result.data.currentAudit) {
                        Write-Output 'Current audit:'
                        $result.data.currentAudit | Select-Object beforeSnapshot,afterSnapshot,startedAtUtc,completedAtUtc | Format-List | Out-String | Write-Output
                        if (@($result.data.currentAudit.classifications).Count) {
                            Write-Output 'Classifications:'
                            $result.data.currentAudit.classifications | Select-Object key,resourceType,name,decision,evidence | Format-Table -AutoSize | Out-String | Write-Output
                        }
                    }
                    $warnings = Get-LeanLaunchApplicationSafetyWarnings -Application $result.data
                    if (@($warnings).Count) {
                        Write-Output 'Safety warnings:'
                        $warnings | ForEach-Object { Write-Output " - $_" }
                    }
                }
                'scan-after' {
                    if (@($result.data.diff.processChanges).Count -or @($result.data.diff.serviceChanges).Count) {
                        Write-Output 'Review candidates with: leanlaunch app show <name>'
                    }
                }
                'run' { $result.data | Select-Object status,applicationName,policy,processId,startedServices,stoppedServices,stoppedProcesses | Format-List | Out-String | Write-Output }
                default { }
            }
        }
    }
}
exit [int]$result.exitCode
