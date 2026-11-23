Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-LeanLaunchProfileFromContent {
    <#
    Parses and strictly validates profile JSON that is ALREADY held in memory as a string - this
    function never performs its own filesystem read. $SourcePath is used only as a label (the
    filename-must-match-declared-name check, and the returned sourcePath field); it is never
    re-opened here. This is the one shared validation body both Import-LeanLaunchProfile (which reads
    $Path's bytes itself, exactly once, then calls this) and Get-LeanLaunchValidatedManagedProfile
    (which already holds the exact bytes it separately hashed for the Managed-run binding check) funnel
    through, so a profile is never validated from a second, potentially different, disk read.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [switch]$SkipExecutableCheck
    )
    try {
        $raw = $Content | ConvertFrom-Json
    }
    catch {
        throw "Profile is not valid JSON: $SourcePath. $($_.Exception.Message)"
    }
    Test-LeanLaunchPropertyType $raw 'schemaVersion' 'Int' 'Profile'
    if ($raw.schemaVersion -ne 1) { throw 'Profile schemaVersion must be 1.' }
    if (-not ($raw.name -is [string]) -or -not (Test-LeanLaunchProfileName $raw.name)) { throw 'Profile name is invalid.' }
    if (-not ($raw.executable -is [string])) { throw 'Profile executable must be a string.' }
    if (-not ([IO.Path]::GetFileNameWithoutExtension($SourcePath)).Equals($raw.name, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Profile filename must match its declared name.'
    }
    foreach ($arrayProperty in @('arguments','services','residualProcesses','waitForProcessNames')) {
        if ((Test-LeanLaunchHasProperty $raw $arrayProperty) -and $null -ne $raw.$arrayProperty -and
            -not ($raw.$arrayProperty -is [System.Array])) {
            throw "Profile property '$arrayProperty' must be an array."
        }
    }
    foreach ($stringProperty in @('displayName','workingDirectory')) {
        if ((Test-LeanLaunchHasProperty $raw $stringProperty) -and $null -ne $raw.$stringProperty -and
            -not ($raw.$stringProperty -is [string])) {
            throw "Profile property '$stringProperty' must be a string."
        }
    }

    $executable = Expand-LeanLaunchValue $raw.executable
    if ([string]::IsNullOrWhiteSpace($executable)) { throw 'Profile executable is required.' }
    if (-not $SkipExecutableCheck -and -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Profile executable was not found: $executable"
    }

    $services = @()
    $rawServices = $null
    if (Test-LeanLaunchHasProperty $raw 'services') { $rawServices = $raw.services }
    foreach ($service in (ConvertTo-LeanLaunchArray $rawServices)) {
        if (-not ($service -is [string])) { throw 'Every service entry must be a string.' }
        $serviceName = [string]$service
        if (-not (Test-LeanLaunchServiceName $serviceName)) { throw "Invalid service name: $serviceName" }
        $services += $serviceName
    }

    $residual = @()
    $rawResidualProcesses = $null
    if (Test-LeanLaunchHasProperty $raw 'residualProcesses') { $rawResidualProcesses = $raw.residualProcesses }
    foreach ($item in (ConvertTo-LeanLaunchArray $rawResidualProcesses)) {
        if ($null -eq $item -or -not (Test-LeanLaunchHasProperty $item 'name') -or -not ($item.name -is [string])) {
            throw 'Every residual process entry must be an object with a string name.'
        }
        $processName = [string]$item.name
        if (-not (Test-LeanLaunchProcessName $processName)) { throw "Invalid residual process name: $processName" }
        $processPath = $null
        if ((Test-LeanLaunchHasProperty $item 'executablePath') -and $item.executablePath) {
            if (-not ($item.executablePath -is [string])) { throw "Residual process '$processName' executablePath must be a string." }
            $processPath = Expand-LeanLaunchValue ([string]$item.executablePath)
        }
        if ([string]::IsNullOrWhiteSpace($processPath)) {
            throw "Residual process '$processName' requires executablePath."
        }
        $residual += [pscustomobject]@{ name = $processName; executablePath = $processPath }
    }

    $waitNames = @()
    $rawWaitNames = $null
    if (Test-LeanLaunchHasProperty $raw 'waitForProcessNames') { $rawWaitNames = $raw.waitForProcessNames }
    foreach ($name in (ConvertTo-LeanLaunchArray $rawWaitNames)) {
        if (-not ($name -is [string])) { throw 'Every waitForProcessNames entry must be a string.' }
        $processName = [string]$name
        if (-not (Test-LeanLaunchProcessName $processName)) { throw "Invalid wait process name: $processName" }
        $waitNames += $processName
    }

    $stopStartedServices = $true
    $stopResidualProcesses = $true
    if ((Test-LeanLaunchHasProperty $raw 'cleanup') -and $null -ne $raw.cleanup) {
        if ($raw.cleanup -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'Profile cleanup must be an object.'
        }
        if (Test-LeanLaunchHasProperty $raw.cleanup 'stopStartedServices') {
            if (-not ($raw.cleanup.stopStartedServices -is [bool])) { throw 'cleanup.stopStartedServices must be boolean.' }
            $stopStartedServices = [bool]$raw.cleanup.stopStartedServices
        }
        if (Test-LeanLaunchHasProperty $raw.cleanup 'stopResidualProcesses') {
            if (-not ($raw.cleanup.stopResidualProcesses -is [bool])) { throw 'cleanup.stopResidualProcesses must be boolean.' }
            $stopResidualProcesses = [bool]$raw.cleanup.stopResidualProcesses
        }
    }

    $displayName = [string]$raw.name
    if ((Test-LeanLaunchHasProperty $raw 'displayName') -and $raw.displayName) {
        $displayName = [string]$raw.displayName
    }
    $workingDirectory = Split-Path -Parent $executable
    if ((Test-LeanLaunchHasProperty $raw 'workingDirectory') -and $raw.workingDirectory) {
        $workingDirectory = Expand-LeanLaunchValue ([string]$raw.workingDirectory)
    }
    $arguments = @()
    if (Test-LeanLaunchHasProperty $raw 'arguments') {
        $arguments = @((ConvertTo-LeanLaunchArray $raw.arguments) | ForEach-Object {
            if (-not ($_ -is [string])) { throw 'Every argument must be a string.' }
            Expand-LeanLaunchValue ([string]$_)
        })
    }

    [pscustomobject]@{
        schemaVersion = 1
        name = [string]$raw.name
        displayName = $displayName
        executable = $executable
        arguments = $arguments
        workingDirectory = $workingDirectory
        services = $services
        residualProcesses = $residual
        waitForProcessNames = $waitNames
        cleanup = [pscustomobject]@{
            stopStartedServices = $stopStartedServices
            stopResidualProcesses = $stopResidualProcesses
        }
        sourcePath = $SourcePath
    }
}

function Import-LeanLaunchProfile {
    <#
    Reads $Path's exact bytes exactly once and validates that same immutable buffer via
    ConvertTo-LeanLaunchProfileFromContent - never re-opening $Path a second time within this call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$SkipExecutableCheck
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Profile not found: $Path"
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $bytes = [IO.File]::ReadAllBytes($resolvedPath)
    $content = [Text.Encoding]::UTF8.GetString($bytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
    return ConvertTo-LeanLaunchProfileFromContent -Content $content -SourcePath $resolvedPath -SkipExecutableCheck:$SkipExecutableCheck
}

function New-LeanLaunchProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string]$DataRoot,
        [switch]$Force
    )
    if (-not (Test-LeanLaunchProfileName $Name)) { throw 'Profile name is invalid.' }
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $path = Join-Path $paths.Profiles ($Name + '.json')
    if ((Test-Path -LiteralPath $path) -and -not $Force) { throw "Profile already exists: $path" }
    if (-not $PSCmdlet.ShouldProcess($path, 'Create LeanLaunch profile')) { return $null }
    New-Item -ItemType Directory -Path $paths.Profiles -Force | Out-Null
    $profile = [ordered]@{
        schemaVersion = 1
        name = $Name
        displayName = $Name
        executable = $Executable
        arguments = @()
        workingDirectory = ''
        services = @()
        residualProcesses = @()
        waitForProcessNames = @()
        cleanup = [ordered]@{ stopStartedServices = $true; stopResidualProcesses = $true }
    }
    Write-LeanLaunchJsonAtomic -Path $path -InputObject $profile -Depth 6 | Out-Null
    return Get-Item -LiteralPath $path
}

function Get-LeanLaunchProfiles {
    [CmdletBinding()]
    param([string]$DataRoot, [string]$RepositoryProfiles)
    $paths = Get-LeanLaunchPaths -DataRoot $DataRoot
    $byName = @{}
    foreach ($root in @($paths.Profiles, $RepositoryProfiles)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)) {
                $key = $file.BaseName.ToLowerInvariant()
                if (-not $byName.ContainsKey($key)) {
                    $byName[$key] = [pscustomobject]@{ name = $file.BaseName; path = $file.FullName; source = $root }
                }
            }
        }
    }
    return @($byName.Values | Sort-Object name)
}
