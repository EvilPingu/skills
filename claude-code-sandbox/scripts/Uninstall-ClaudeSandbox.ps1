# Removes what Install-ClaudeSandbox.ps1 set up. Ownership changes are not reverted, see the README.
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [string]$UserName,
    [string]$Volumes,
    [switch]$AclTestOnly,
    [string]$SandboxResume,
    [Parameter(ValueFromRemainingArguments)][string[]]$UnknownArguments
)

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
[Threading.Thread]::CurrentThread.CurrentCulture = $culture
$ErrorActionPreference = 'Stop'

function Stop-Uninstall {
    param([int]$Code)
    Write-Host "Exit code: $Code."
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        try { $null = Read-Host 'Press Enter to close' } catch { }
    }
    exit $Code
}

function Stop-WithError {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Stop-Uninstall -Code 1
}

if ($UnknownArguments) { Stop-WithError "Unknown argument: $($UnknownArguments -join ' ')" }

Import-Module (Join-Path $PSScriptRoot 'ClaudeSandbox.psm1') -Force -DisableNameChecking

if (-not (Test-SandboxAdministrator)) { Stop-WithError 'This script must run with administrator rights.' }

$usedReasons = @()
if ($SandboxResume) {
    $resume = ConvertFrom-SandboxResumeArgument -Value $SandboxResume
    $usedReasons = @($resume.Reasons)
    foreach ($name in $resume.Parameters.Keys) { Set-Variable -Name $name -Value $resume.Parameters[$name] }
    if ($resume.Parameters.ContainsKey('WhatIf') -and $resume.Parameters['WhatIf']) { $WhatIfPreference = $true }
}
$isWhatIf = [bool]$WhatIfPreference

function Restart-Uninstall {
    param([string]$PwshFolder, [string]$ScriptPath, [string]$Reason)
    $parameters = @{ UserName = $UserName; Volumes = $Volumes; AclTestOnly = [bool]$AclTestOnly; WhatIf = $isWhatIf }
    $encoded = ConvertTo-SandboxResumeArgument -Parameters $parameters -UsedRestartReasons (@($usedReasons) + $Reason)
    & (Join-Path $PwshFolder 'pwsh.exe') -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -SandboxResume $encoded
    exit $LASTEXITCODE
}

$machinePwsh = Get-SandboxMachinePwsh
$inMachine = Test-SandboxRunningInMachinePwsh -PsHome $PSHOME -MachineLocation $machinePwsh
if (-not $inMachine) {
    if (-not $machinePwsh) { Stop-WithError 'The machine-wide PowerShell 7 was not found.' }
    if ($usedReasons -contains 'pwsh') { Stop-WithError 'The restart in the machine-wide PowerShell 7 did not work.' }
    Restart-Uninstall -PwshFolder $machinePwsh -ScriptPath $PSCommandPath -Reason 'pwsh'
}

$layout = Get-SandboxLayout -Test:$AclTestOnly
$realLayout = Get-SandboxLayout
$config = Read-SandboxJson -Path $layout.ConfigPath
if (-not $config) { Stop-WithError "No configuration at $($layout.ConfigPath). Nothing to remove." }
if (-not $UserName) { $UserName = $config.UserName }

# Same location check as the installation: this script runs as administrator.
$writerSids = @(@(Get-SandboxTargetSids -UserName $config.UserName) + @($config.TokenSids) | Select-Object -Unique)
if (Test-SandboxLocationWritable -Path $PSScriptRoot -Sids $writerSids) {
    if ($usedReasons -contains 'install') { Stop-WithError "$PSScriptRoot is still writable for the target user." }
    if ($isWhatIf) {
        Write-Host "What if: '$PSScriptRoot' is writable for the target user. The scripts would be copied to $($realLayout.Install) after confirmation."
    } else {
        Write-Host "The target user can write to $PSScriptRoot. SHA256 of the scripts:"
        $sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
        foreach ($source in $sources) { Write-Host ('{0}  {1}' -f (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash, $source.Name) }
        if (-not (Read-SandboxYesNo -Prompt "Copy them to $($realLayout.Install) and continue from there?")) { Stop-WithError 'Stopped: the script does not run from a location the target user can write to.' }
        New-SandboxProtectedFolder -Path $realLayout.Root
        New-SandboxProtectedFolder -Path $realLayout.Install
        foreach ($source in $sources) { Copy-Item -LiteralPath $source.FullName -Destination $realLayout.Install -Force }
        Restart-Uninstall -PwshFolder $machinePwsh -ScriptPath (Join-Path $realLayout.Install 'Uninstall-ClaudeSandbox.ps1') -Reason 'install'
    }
}

$targetSid = $config.TargetSid
$allVolumes = @(Get-SandboxVolumes)
$selection = if ($AclTestOnly) { Resolve-SandboxVolumeSelection -Requested @(Split-SandboxList -Value $Volumes) -Volumes $allVolumes } else { $config.VolumeKeys }
if ($AclTestOnly -and -not $selection) { Stop-WithError '-AclTestOnly needs -Volumes.' }
if ($AclTestOnly) {
    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($user -and $user.SID.Value -ne $targetSid) { Stop-WithError "'$UserName' is not the test user of $($layout.ConfigPath)." }
}

if ($isWhatIf) {
    Write-Host 'What if: tasks stop, the entries of the target user are removed, and the sandbox folders are deleted.'
    Stop-Uninstall -Code 0
}

Set-Location -LiteralPath $env:SystemRoot
$exitCode = 0
try {
    Write-Host '== Stopping tasks'
    if ($AclTestOnly) {
        $testTask = Get-ScheduledTask -TaskName 'ClaudeSandbox-Test' -ErrorAction SilentlyContinue
        if ($testTask) {
            Stop-ScheduledTask -TaskName 'ClaudeSandbox-Test' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName 'ClaudeSandbox-Test' -Confirm:$false -ErrorAction SilentlyContinue
        }
    } else {
        # First, otherwise a running task sets the locks again right away.
        Stop-SandboxTasks -Unregister
    }
    $locks = [Collections.Generic.List[object]]::new()
    foreach ($mode in 'Check', 'Root', 'Scan') {
        if (-not (Test-Path -LiteralPath $layout.LockDir)) { break }
        $lock = Enter-SandboxLock -Layout $layout -Name "mode-$mode" -TimeoutSeconds 120
        if (-not $lock) { throw "The $mode run could not be stopped." }
        $locks.Add($lock)
    }

    Write-Host '== Removing the entries of the target user. This can take a long time.'
    $model = Get-SandboxModel -Config $config -Volumes $allVolumes
    # Git and Claude folders stay writable for the target until here: only their top folder is changed.
    $writableTrees = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($config.ClaudePath, $config.GitPath) | Where-Object { $_ }) { $null = $writableTrees.Add($path.TrimEnd('\')) }
    foreach ($path in $writableTrees) {
        if (Test-Path -LiteralPath $path) { $null = Invoke-SandboxIcacls -Path $path -Operation @('/remove', "*$targetSid") }
    }
    foreach ($volume in $allVolumes) {
        if ($selection -and $selection -notcontains $volume.Key) { continue }
        if ($volume.Status -ne 'Available') {
            Write-Host "WARNING: $($volume.MountPath) is $($volume.Status), its entries stay until it is cleaned in another run." -ForegroundColor Yellow
            $exitCode = 2
            continue
        }
        Write-Host "Volume $($volume.MountPath)"
        if ($volume.IsSystem) {
            foreach ($item in [IO.DirectoryInfo]::new($volume.MountPath).EnumerateFileSystemInfos()) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $full = $item.FullName.TrimEnd('\')
                if ($writableTrees.Contains($full)) { continue }
                if (@($model.Info.Untouched | Where-Object { Test-SandboxSamePath -Left $_ -Right $full }).Count -gt 0) { continue }
                if (Test-SandboxSamePath -Left $full -Right $model.Info.ProfileRoot) {
                    foreach ($profileFolder in [IO.DirectoryInfo]::new($full).EnumerateDirectories()) {
                        if ($profileFolder.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                        if (Test-SandboxSamePath -Left $profileFolder.FullName -Right $config.TargetProfile) { continue }
                        Remove-SandboxSidAces -Path $profileFolder.FullName -Sid $targetSid -Skip $writableTrees
                    }
                    continue
                }
                if ($item -is [IO.DirectoryInfo]) { Remove-SandboxSidAces -Path $full -Sid $targetSid -Skip $writableTrees }
                else { $null = Invoke-SandboxIcacls -Path $full -Operation @('/remove', "*$targetSid") }
            }
            $null = Invoke-SandboxIcacls -Path $volume.MountPath -Operation @('/remove', "*$targetSid")
        } else {
            Remove-SandboxSidAces -Path $volume.MountPath -Sid $targetSid -Skip $writableTrees
        }
    }

    foreach ($lock in $locks) { Exit-SandboxLock -Lock $lock }

    # The logs are deleted with the sandbox folders below, the list of ownership changes has to survive.
    $ownershipLog = $null
    $ownerLogs = @(Get-ChildItem -LiteralPath $layout.LogDir -Filter '*.owner.log' -File -ErrorAction SilentlyContinue)
    if ($ownerLogs.Count -gt 0) {
        $ownershipLog = Join-Path $env:USERPROFILE ('ClaudeSandbox-ownership-{0:yyyyMMdd-HHmmss}.log' -f [DateTime]::UtcNow)
        $ownerLogs | Get-Content -Encoding utf8 | Set-Content -LiteralPath $ownershipLog -Encoding utf8
    }

    if ($AclTestOnly) {
        Write-Host '== Removing the test user and its profile'
        $profileEntry = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID = '$targetSid'" -ErrorAction SilentlyContinue
        if ($profileEntry) { Remove-CimInstance -InputObject $profileEntry -ErrorAction SilentlyContinue }
        if (Get-LocalUser -SID $targetSid -ErrorAction SilentlyContinue) { Remove-LocalUser -SID $targetSid }
        Remove-Item -LiteralPath $layout.Base -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $realLayout.ConfigPath)) {
            Remove-Item -LiteralPath $realLayout.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host '== Removing firewall rules, policy and link'
        Get-NetFirewallRule -Group (Get-SandboxFirewallGroup) -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $hiveOk = Invoke-SandboxWithUserHive -Sid $targetSid -ProfilePath $config.TargetProfile -Action {
            param($hive)
            $policy = [Microsoft.Win32.Registry]::Users.OpenSubKey("$hive\Software\Policies\Microsoft\Windows\RemovableStorageDevices", $true)
            if ($policy) { try { $policy.DeleteValue('Deny_All', $false) } finally { $policy.Dispose() } }
        }
        if (-not $hiveOk) { Write-Host 'WARNING: The removable storage policy of the target user could not be removed.' -ForegroundColor Yellow; $exitCode = 2 }
        $link = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Terminal.lnk'
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }

        $localFolder = Join-Path $env:LOCALAPPDATA 'ClaudeSandbox'
        $removeUser = Read-SandboxYesNo -Prompt "Also delete the user '$($config.UserName)' and its profile? Its files in the profile are lost"
        if ($removeUser) {
            foreach ($process in Get-SandboxUserProcesses -Sid $targetSid) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
            $profileEntry = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID = '$targetSid'" -ErrorAction SilentlyContinue
            if ($profileEntry) { Remove-CimInstance -InputObject $profileEntry -ErrorAction SilentlyContinue }
            if (Get-LocalUser -SID $targetSid -ErrorAction SilentlyContinue) { Remove-LocalUser -SID $targetSid }
            if (Test-Path -LiteralPath $localFolder) { Remove-Item -LiteralPath $localFolder -Recurse -Force }
        } elseif (Test-Path -LiteralPath $localFolder) {
            # Without this file the password of the remaining user would be lost.
            Get-ChildItem -LiteralPath $localFolder -File | Where-Object { $_.Name -ne 'credential.xml' } | Remove-Item -Force
            Write-Host "The stored password stays in $localFolder because the user remains."
        }
        # Last: this script itself may run from install\.
        Remove-Item -LiteralPath $realLayout.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($ownershipLog) { Write-Host "Ownership that moved to Administrators stays that way. Affected objects: $ownershipLog" }
} catch {
    Write-Host "ERROR: Uninstall failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
Stop-Uninstall -Code $exitCode
