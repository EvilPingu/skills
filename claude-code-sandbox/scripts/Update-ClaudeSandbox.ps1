# Scheduled follow-up, runs as SYSTEM. Starts nothing through PATH: registry, fixed paths and files only.
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [ValidateSet('Check', 'Root', 'Scan')][string]$Mode = 'Check',
    [string]$ConfigPath,
    [Parameter(ValueFromRemainingArguments)][string[]]$UnknownArguments
)

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
[Threading.Thread]::CurrentThread.CurrentCulture = $culture
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeSandbox.psm1') -Force -DisableNameChecking
Set-SandboxQuiet

if ($UnknownArguments) { Write-Error "Unknown argument: $($UnknownArguments -join ' ')"; exit 1 }

$layout = Get-SandboxLayout -ConfigPath $ConfigPath
Set-SandboxLogPath -Path (Join-Path $layout.LogDir 'task.log')
$config = Read-SandboxJson -Path $layout.ConfigPath
if (-not $config) { Write-SandboxMessage -Level Error -Message "No configuration at $($layout.ConfigPath)."; exit 1 }

$modeLock = Enter-SandboxLock -Layout $layout -Name "mode-$Mode"
if (-not $modeLock) { Write-SandboxMessage -LogOnly -Message "$Mode is already running."; exit 0 }

function Test-VolumeInScope {
    param([hashtable]$Volume)
    return (-not $config.VolumeKeys -or @($config.VolumeKeys) -contains $Volume.Key)
}

function Start-SandboxFollowUp {
    # Test configurations never start the real tasks.
    param([string]$TaskName)
    if ($config.Test) { return }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
}

function Invoke-CheckMode {
    # Firewall first: this part must never wait for ACL work.
    $userPath = Get-SandboxUserPathFromHive -Sid $config.ExecutorSid
    $programs = Get-SandboxClaudeBlockPaths -ExecutorProfile $config.ExecutorProfile -UserPathValue $userPath
    if ($config.Test) {
        Write-SandboxMessage -LogOnly -Message ("Test mode, Claude paths found: " + ($programs -join '; '))
    } elseif ($config.FirewallVerified) {
        $null = Sync-SandboxFirewallRules -ExecutorSid $config.ExecutorSid -Programs $programs
    }

    $volumes = @(Get-SandboxVolumes)
    $model = Get-SandboxModel -Config $config -Volumes $volumes
    $state = Read-SandboxJson -Path $layout.StatePath
    $rootNeeded = $false

    foreach ($volume in $volumes) {
        if (-not (Test-VolumeInScope $volume)) { continue }
        if ($volume.Status -in 'Locked', 'NoAcls') {
            Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $volume.Status
            continue
        }
        if ($volume.IsSystem) {
            $missing = @(Get-SandboxSystemDriveTargets -Model $model | Where-Object { -not (Test-SandboxHasDeny -Path $_.Path -Sid $config.TargetSid) })
            if ($missing.Count -gt 0 -or -not (Test-SandboxSystemRootRule -Path $volume.MountPath -Sid $config.TargetSid)) { $rootNeeded = $true }
            continue
        }
        if (-not (Test-SandboxContainerRules -Path $volume.MountPath -Sid $config.TargetSid)) {
            $rootNeeded = $true
            Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status 'Incomplete' -ScanPending $true
            continue
        }
        # An unlocked volume keeps its deny. Restore the last result so the status stops saying Locked.
        $entry = if ($state -and $state.Volumes) { $state.Volumes[$volume.Key] }
        if ($entry -and $entry.Status -eq 'Locked' -and $entry.LastScanStatus) {
            Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $entry.LastScanStatus
        }
    }

    foreach ($toolchain in Get-SandboxToolchains) {
        $known = @($config.Toolchains) + @($config.AllowPaths) + @($model.Info.Untouched)
        if (@($known | Where-Object { $_ -and (Test-SandboxPathWithin -Path $toolchain -Base $_) }).Count -gt 0) { continue }
        Add-SandboxStateMessage -Layout $layout -Message "New toolchain found at $toolchain. Release it with a new installation run and -AllowPath."
    }

    if ($state -and $state.Heartbeat) {
        foreach ($longMode in 'Root', 'Scan') {
            $beat = $state.Heartbeat[$longMode]
            if ($beat -and $state.Running[$longMode] -and ([DateTime]::UtcNow - ([DateTime]$beat).ToUniversalTime()).TotalHours -gt 1) {
                Add-SandboxStateMessage -Layout $layout -Message "The $longMode task has not reported progress for over an hour."
            }
        }
    }
    Update-SandboxState -Layout $layout -Change { param($s) $s['RootNeeded'] = $rootNeeded; $s['LastCheckUtc'] = [DateTime]::UtcNow.ToString('o') }
    if ($rootNeeded) { Start-SandboxFollowUp -TaskName 'ClaudeSandbox-Root' }
}

function Invoke-RootMode {
    Set-SandboxHeartbeat -Layout $layout -Mode Root
    try {
        $volumes = @(Get-SandboxVolumes)
        $model = Get-SandboxModel -Config $config -Volumes $volumes
        foreach ($volume in $volumes) {
            if (-not (Test-VolumeInScope $volume) -or $volume.Status -ne 'Available') { continue }
            $volumeLock = Enter-SandboxLock -Layout $layout -Name "volume-$($volume.Key)" -TimeoutSeconds 5
            if (-not $volumeLock) { continue }
            try {
                if ($volume.IsSystem) {
                    # New top level folders: a toolchain becomes a release, anything else gets locked and reported.
                    $newTargets = @(Get-SandboxSystemDriveTargets -Model $model | Where-Object { -not (Test-SandboxHasDeny -Path $_.Path -Sid $config.TargetSid) })
                    if ($newTargets.Count -eq 0 -and (Test-SandboxSystemRootRule -Path $volume.MountPath -Sid $config.TargetSid)) { continue }
                    $toolchains = @(Get-SandboxToolchains)
                    $added = @($toolchains | Where-Object {
                        $tool = $_
                        @($newTargets | Where-Object { Test-SandboxPathWithin -Path $tool -Base $_.Path }).Count -gt 0
                    })
                    if ($added.Count -gt 0) {
                        $config['Toolchains'] = @(@($config.Toolchains) + $added | Where-Object { $_ } | Select-Object -Unique)
                        Write-SandboxJson -Path $layout.ConfigPath -Value $config
                        $model = Get-SandboxModel -Config $config -Volumes $volumes
                    }
                    $protection = Set-SandboxVolumeProtection -Config $config -Model $model -Volume $volume -Volumes $volumes -Layout $layout
                    foreach ($target in $newTargets) {
                        if ($protection.Targets.Path -contains $target.Path) {
                            Add-SandboxStateMessage -Layout $layout -Message "New item locked: $($target.Path). Release it with a new installation run and -AllowPath."
                        }
                    }
                    Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $(if ($protection.Ok) { 'Unverified' } else { 'Incomplete' }) -ScanPending $true
                } else {
                    if (Test-SandboxContainerRules -Path $volume.MountPath -Sid $config.TargetSid) { continue }
                    $protection = Set-SandboxVolumeProtection -Config $config -Model $model -Volume $volume -Volumes $volumes -Layout $layout
                    Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $(if ($protection.Ok) { 'Unverified' } else { 'Incomplete' }) -ScanPending $true
                }
            } finally { Exit-SandboxLock -Lock $volumeLock }
            Set-SandboxHeartbeat -Layout $layout -Mode Root
        }
    } finally {
        Set-SandboxHeartbeat -Layout $layout -Mode Root -Running $false
    }
    Start-SandboxFollowUp -TaskName 'ClaudeSandbox-Scan'
}

function Invoke-ScanMode {
    Set-SandboxHeartbeat -Layout $layout -Mode Scan
    try {
        $volumes = @(Get-SandboxVolumes)
        $model = Get-SandboxModel -Config $config -Volumes $volumes
        $state = Read-SandboxJson -Path $layout.StatePath
        foreach ($volume in $volumes) {
            if (-not (Test-VolumeInScope $volume) -or $volume.Status -ne 'Available') { continue }
            $entry = if ($state -and $state.Volumes) { $state.Volumes[$volume.Key] }
            if (-not $entry) { continue }
            $due = [bool]$entry.ScanPending
            if (-not $due -and $entry.Status -eq 'Incomplete' -and [int]$entry.ScanFailures -lt 3) {
                $due = (-not $entry.LastScanUtc) -or (([DateTime]::UtcNow - ([DateTime]$entry.LastScanUtc).ToUniversalTime()).TotalHours -ge 23)
            }
            if (-not $due) { continue }
            $volumeLock = Enter-SandboxLock -Layout $layout -Name "volume-$($volume.Key)" -TimeoutSeconds 30
            if (-not $volumeLock) { continue }
            try {
                $targets = @()
                if ($volume.IsSystem) { $targets = @(Get-SandboxSystemDriveTargets -Model $model) }
                $beat = { Set-SandboxHeartbeat -Layout $layout -Mode Scan }
                $scan = Invoke-SandboxVolumeScan -Config $config -Model $model -Volume $volume -Layout $layout -Targets $targets -Heartbeat $beat
                Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $scan.Status -Scan $scan
            } finally { Exit-SandboxLock -Lock $volumeLock }
        }
    } finally {
        Set-SandboxHeartbeat -Layout $layout -Mode Scan -Running $false
    }
}

$exitCode = 0
try {
    switch ($Mode) {
        'Check' { Invoke-CheckMode }
        'Root' { Invoke-RootMode }
        'Scan' { Invoke-ScanMode }
    }
} catch {
    Write-SandboxMessage -Level Error -Message "$Mode failed: $($_.Exception.GetType().Name) at line $($_.InvocationInfo.ScriptLineNumber)."
    $exitCode = 1
} finally {
    Exit-SandboxLock -Lock $modeLock
}
exit $exitCode
