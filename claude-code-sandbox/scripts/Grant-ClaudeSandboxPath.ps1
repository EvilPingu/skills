# Releases more folders for the target user after the installation, or takes a release back.
# Quick compared to a full installation run: only the given folders and their parents are touched.
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [string]$Path,
    [ValidateSet('', 'Read', 'Write')][string]$Access = '',
    [switch]$Remove,
    [switch]$List,
    [string]$SandboxResume,
    [Parameter(ValueFromRemainingArguments)][string[]]$UnknownArguments
)

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
[Threading.Thread]::CurrentThread.CurrentCulture = $culture
$ErrorActionPreference = 'Stop'

function Stop-Grant {
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
    Stop-Grant -Code 1
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

function Restart-Grant {
    param([string]$PwshFolder, [string]$ScriptPath, [string]$Reason)
    $parameters = @{ Path = $Path; Access = $Access; Remove = [bool]$Remove; List = [bool]$List; WhatIf = $isWhatIf }
    $encoded = ConvertTo-SandboxResumeArgument -Parameters $parameters -UsedRestartReasons (@($usedReasons) + $Reason)
    & (Join-Path $PwshFolder 'pwsh.exe') -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -SandboxResume $encoded
    exit $LASTEXITCODE
}

$machinePwsh = Get-SandboxMachinePwsh
if (-not (Test-SandboxRunningInMachinePwsh -PsHome $PSHOME -MachineLocation $machinePwsh)) {
    if (-not $machinePwsh) { Stop-WithError 'The machine-wide PowerShell 7 was not found.' }
    if ($usedReasons -contains 'pwsh') { Stop-WithError 'The restart in the machine-wide PowerShell 7 did not work.' }
    Restart-Grant -PwshFolder $machinePwsh -ScriptPath $PSCommandPath -Reason 'pwsh'
}

$layout = Get-SandboxLayout
$config = Read-SandboxJson -Path $layout.ConfigPath
if (-not $config) { Stop-WithError "No installation found at $($layout.ConfigPath). Run Install-ClaudeSandbox.ps1 first." }
$executorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($config.ExecutorSid -ne $executorSid) { Stop-WithError 'Run this from the account that did the installation: it holds the password and the settings.' }

$showCurrent = {
    Write-Host "Scripts: $(Get-SandboxShortHash -Hash (Get-SandboxScriptHash -ScriptRoot $PSScriptRoot)). Installed: $(Get-SandboxShortHash -Hash $config.InstalledHash)."
    Write-Host "Claude folder (full control): $($config.ClaudePath)"
    Write-Host "Git folder (read and write):  $($config.GitPath)"
    foreach ($item in @($config.WritePaths) | Where-Object { $_ }) { Write-Host "Read and write: $item" }
    foreach ($item in @($config.AllowPaths) | Where-Object { $_ }) { Write-Host "Read only:      $item" }
}
if ($List) {
    & $showCurrent
    Stop-Grant -Code 0
}

# Same location check as the installation: this script runs as administrator.
$writerSids = @(@(Get-SandboxTargetSids -UserName $config.UserName) + @($config.TokenSids) | Select-Object -Unique)
if (Test-SandboxLocationWritable -Path $PSScriptRoot -Sids $writerSids) {
    if ($usedReasons -contains 'install') { Stop-WithError "$PSScriptRoot is still writable for the target user." }
    if ($isWhatIf) {
        Write-Host "What if: '$PSScriptRoot' is writable for the target user. The scripts would be copied to $($layout.Install) after confirmation."
    } else {
        Write-Host "The target user can write to $PSScriptRoot. SHA256 of the scripts:"
        $sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
        foreach ($source in $sources) { Write-Host ('{0}  {1}' -f (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash, $source.Name) }
        Write-Host 'Earlier manipulation of these files cannot be detected by copying them.'
        if (-not (Read-SandboxYesNo -Prompt "Copy them to $($layout.Install) and continue from there?")) { Stop-WithError 'Stopped: the script does not run from a location the target user can write to.' }
        foreach ($source in $sources) { Copy-Item -LiteralPath $source.FullName -Destination $layout.Install -Force }
        Restart-Grant -PwshFolder $machinePwsh -ScriptPath (Join-Path $layout.Install 'Grant-ClaudeSandboxPath.ps1') -Reason 'install'
    }
}

if (-not (Test-SandboxVersionAllowed -Installed $config.InstalledHash -ScriptRoot $PSScriptRoot)) { Stop-WithError 'Stopped: update the scripts first.' }

if (-not $Path) {
    & $showCurrent
    $question = if ($Remove) { 'Which folders should lose access? Separate several with ;' } else { 'Which folders should be released? Separate several with ;' }
    $Path = Read-SandboxValue -Prompt $question
    if (-not $Path) { Stop-WithError 'No folder given. Use -Path when running without a console.' }
}
if (-not $Remove -and -not $Access) {
    $Access = if (Read-SandboxYesNo -Prompt 'Allow writing as well? No means read only') { 'Write' } else { 'Read' }
}

$targetSid = $config.TargetSid
$exitCode = 0
$credentialPath = Join-Path $env:LOCALAPPDATA 'ClaudeSandbox\credential.xml'
$originalAllow = @(@($config.AllowPaths) | Where-Object { $_ })
$originalWrite = @(@($config.WritePaths) | Where-Object { $_ })
$locks = [Collections.Generic.List[object]]::new()

try {
    $volumeList = @(Get-SandboxVolumes)
    $info = Get-SandboxSystemInfo -ExecutorProfile $config.ExecutorProfile -TargetProfile $config.TargetProfile
    $targets = [Collections.Generic.List[string]]::new()
    $absorbed = [Collections.Generic.List[string]]::new()

    foreach ($requested in Split-SandboxList -Value $Path) {
        if ($Remove) {
            $final = @($originalAllow + $originalWrite | Where-Object { Test-SandboxSamePath -Left $_ -Right $requested }) | Select-Object -First 1
            if (-not $final) {
                $resolved = Resolve-SandboxFinalPath -Path $requested
                $final = @($originalAllow + $originalWrite | Where-Object { Test-SandboxSamePath -Left $_ -Right $resolved }) | Select-Object -First 1
            }
            if (-not $final) { Stop-WithError "'$requested' is not one of the released folders. Git and Claude folders change with a new installation run." }
            $targets.Add($final)
            continue
        }
        if (-not (Test-Path -LiteralPath $requested)) { Stop-WithError "'$requested' does not exist." }
        if ((Get-Item -LiteralPath $requested -Force) -isnot [IO.DirectoryInfo]) { Stop-WithError "'$requested' is not a folder." }
        $final = Resolve-SandboxFinalPath -Path $requested
        if (-not $final) { Stop-WithError "'$requested' could not be resolved." }
        $owner = Get-SandboxVolumeOfPath -Path $final -Volumes $volumeList
        if (-not $owner) { Stop-WithError "'$final' is not on a fixed local volume." }
        if ($owner.Status -ne 'Available') { Stop-WithError "'$final' is on a volume with status $($owner.Status) and cannot be secured." }

        $kind = if ($Access -eq 'Write') { 'Git' } else { 'Allow' }
        $check = Get-SandboxPathRejection -Path $final -Kind $kind -Info $info -GitPath $config.GitPath -ClaudePath $config.ClaudePath
        if (-not $check.Ok) { Stop-WithError "'$final' cannot be used: $($check.Reason)" }
        $conflict = Get-SandboxGrantConflict -Path $final -Access $Access -AllowPaths $originalAllow -WritePaths $originalWrite -GitPath $config.GitPath -ClaudePath $config.ClaudePath
        if ($conflict.Reason) { Stop-WithError $conflict.Reason }
        if ($conflict.Absorb.Count -gt 0) {
            Write-Host "'$final' contains folders that are already released. They become part of it and lose their own entry:"
            foreach ($item in $conflict.Absorb) { Write-Host " - $item" }
            if (-not (Read-SandboxYesNo -Prompt 'Continue?')) { Stop-WithError 'Stopped at your request.' }
            foreach ($item in $conflict.Absorb) { $absorbed.Add($item) }
        }
        if ($check.NeedsConfirmation -and -not (Read-SandboxYesNo -Prompt "'$final' is inside your own profile. The target user gets access to it. Continue?")) { Stop-WithError 'Stopped at your request.' }
        $targets.Add($final)
    }

    if ($Remove) {
        foreach ($target in $targets) {
            $problem = Get-SandboxRemovalProblem -Path $target -Removing @($targets) -AllowPaths $originalAllow -WritePaths $originalWrite -GitPath $config.GitPath -ClaudePath $config.ClaudePath
            if ($problem) { Stop-WithError $problem }
        }
    } elseif ($Access -eq 'Write') {
        foreach ($target in $targets) {
            foreach ($other in $targets) {
                if (-not (Test-SandboxSamePath -Left $target -Right $other) -and (Test-SandboxPathWithin -Path $target -Base $other)) { Stop-WithError "'$target' is inside '$other'. Give only the outer folder." }
            }
        }
    }

    if ($isWhatIf) {
        foreach ($target in $targets) {
            if ($Remove) { Write-Host "What if: '$target' would lose its release and be locked again." }
            else { Write-Host "What if: '$target' would be released with access '$Access'." }
        }
        Stop-Grant -Code 0
    }

    # The tasks need the module that knows the new setting, otherwise their scan would take the release away again.
    foreach ($name in 'Update-ClaudeSandbox.ps1', 'ClaudeSandbox.psm1', 'Show-ClaudeStatus.ps1') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $layout.Root -Force
    }
    foreach ($source in Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
        if (-not (Test-SandboxSamePath -Left $PSScriptRoot -Right $layout.Install)) { Copy-Item -LiteralPath $source.FullName -Destination $layout.Install -Force }
    }

    Stop-SandboxTasks
    foreach ($mode in 'Check', 'Root', 'Scan') {
        $lock = Enter-SandboxLock -Layout $layout -Name "mode-$mode" -TimeoutSeconds 120
        if (-not $lock) { throw "The $mode task is still running and could not be stopped." }
        $locks.Add($lock)
    }

    $newAllow = [Collections.Generic.List[string]]::new()
    $dropped = @($targets) + @($absorbed)
    foreach ($item in $originalAllow) { if (@($dropped | Where-Object { Test-SandboxSamePath -Left $_ -Right $item }).Count -eq 0) { $newAllow.Add($item) } }
    $newWrite = [Collections.Generic.List[string]]::new()
    foreach ($item in $originalWrite) { if (@($dropped | Where-Object { Test-SandboxSamePath -Left $_ -Right $item }).Count -eq 0) { $newWrite.Add($item) } }
    if (-not $Remove) {
        foreach ($target in $targets) { if ($Access -eq 'Write') { $newWrite.Add($target) } else { $newAllow.Add($target) } }
    }

    if ($Remove) {
        # The allow goes first, so the tree is no longer writable when it is checked below.
        foreach ($target in $targets) {
            if (Test-Path -LiteralPath $target) { $null = Invoke-SandboxIcacls -Path $target -Operation @('/remove:g', "*$targetSid") }
        }
    } else {
        # Own entries of absorbed folders go before the outer folder becomes writable.
        foreach ($item in $absorbed) {
            if (Test-Path -LiteralPath $item) { $null = Invoke-SandboxIcacls -Path $item -Operation @('/remove:g', "*$targetSid") }
        }
        # Trees the target can already write to are never walked, also not below a new outer folder.
        $writableTrees = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @($config.GitPath, $config.ClaudePath) + $originalWrite | Where-Object { $_ }) { $null = $writableTrees.Add($item.TrimEnd('\')) }
        foreach ($target in $targets) {
            $wasReleased = @($originalAllow + $originalWrite | Where-Object { Test-SandboxSamePath -Left $_ -Right $target }).Count -gt 0
            # An old deny would beat the new allow. The tree is not writable for the target yet.
            if (-not $wasReleased) {
                Write-Host "Removing old locks below $target"
                Remove-SandboxSidAces -Path $target -Sid $targetSid -DenyOnly -Skip $writableTrees
            }
            # A change from read and write to read only must not leave the broader allow behind.
            $null = Invoke-SandboxIcacls -Path $target -Operation @('/remove:g', "*$targetSid")
        }
    }

    # Saved before the permissions change: a task started later must already know the new release.
    $config['AllowPaths'] = @($newAllow)
    $config['WritePaths'] = @($newWrite)
    # The tasks and the install folder were just brought to these scripts.
    $config['InstalledHash'] = Get-SandboxScriptHash -ScriptRoot $PSScriptRoot
    Write-SandboxJson -Path $layout.ConfigPath -Value $config

    $model = Get-SandboxModel -Config $config -Volumes $volumeList
    $touched = @($targets | ForEach-Object { Get-SandboxVolumeOfPath -Path $_ -Volumes $volumeList } | Where-Object { $_ } | Sort-Object { $_.Key } -Unique)
    foreach ($volume in $touched) {
        $volumeLock = Enter-SandboxLock -Layout $layout -Name "volume-$($volume.Key)" -TimeoutSeconds 60
        if (-not $volumeLock) { throw "The volume $($volume.MountPath) is locked by a running task." }
        $locks.Add($volumeLock)
        Write-Host "Updating permissions on $($volume.MountPath)"
        if ($config.VolumeKeys -and @($config.VolumeKeys) -notcontains $volume.Key) {
            # Outside the -Volumes selection nothing gets locked, only the release itself is set.
            $ok = Set-SandboxGrantsForVolume -Model $model -Volume $volume -Volumes $volumeList -Sid $targetSid
        } else {
            $protection = Set-SandboxVolumeProtection -Config $config -Model $model -Volume $volume -Volumes $volumeList -Layout $layout
            $ok = $protection.Ok
        }
        if (-not $ok) { Write-Host 'WARNING: Some permissions could not be set.' -ForegroundColor Yellow; $exitCode = 1 }
    }

    if ($Remove) {
        foreach ($target in $targets) {
            if ((Invoke-SandboxPathCheck -Path $target -Config $config -Model $model -Layout $layout) -gt 0) { Write-Host "WARNING: $target has write errors." -ForegroundColor Yellow; $exitCode = 1 }
        }
    }

    foreach ($lock in $locks) { Exit-SandboxLock -Lock $lock }
    $locks.Clear()

    if (Test-Path -LiteralPath $credentialPath) {
        $tests = [Collections.Generic.List[object]]::new()
        foreach ($target in $targets) {
            if ($Remove) {
                if (@($info.Untouched | Where-Object { Test-SandboxPathWithin -Path $target -Base $_ }).Count -eq 0) {
                    $tests.Add(@{ Name = "No access any more: $target"; Op = 'ListDirectory'; Path = $target; Expect = 'Denied' })
                }
                # Releases below it must survive.
                foreach ($kept in @($config.GitPath, $config.ClaudePath) + @($newAllow) + @($newWrite) | Where-Object { $_ }) {
                    if ((Test-SandboxPathWithin -Path $kept -Base $target) -and (Test-Path -LiteralPath $kept)) {
                        $tests.Add(@{ Name = "Still accessible: $kept"; Op = 'ListDirectory'; Path = $kept; Expect = 'Allowed' })
                    }
                }
            } else {
                $tests.Add(@{ Name = "Readable: $target"; Op = 'ListDirectory'; Path = $target; Expect = 'Allowed' })
                $tests.Add(@{ Name = "$(if ($Access -eq 'Write') { 'Writable' } else { 'Not writable' }): $target"; Op = 'WriteFile'; Path = $target; Expect = $(if ($Access -eq 'Write') { 'Allowed' } else { 'Denied' }) })
            }
        }
        $credential = Import-Clixml -LiteralPath $credentialPath
        $result = Invoke-SandboxProbe -Credential $credential -PwshPath $machinePwsh -Layout $layout -Tests @($tests)
        foreach ($entry in @($result.Results)) {
            if ($entry.Outcome -eq $entry.Expect) { Write-Host "OK: $($entry.Name)" -ForegroundColor Green }
            else { Write-Host "FAILED: $($entry.Name) (expected $($entry.Expect), got $($entry.Outcome))" -ForegroundColor Red; $exitCode = 1 }
        }
    } else {
        Write-Host 'WARNING: The stored password was not found, the result could not be tested as the target user.' -ForegroundColor Yellow
        $exitCode = 1
    }
    if ($Remove) { Write-Host 'Programs of the target user that already opened files there keep those open until they end.' }
    else { Write-Host 'This applies at once, also in a Claude terminal that is already open.' }
} catch {
    $detail = $_.Exception.Message
    if ($_.Exception -is [ComponentModel.Win32Exception]) { $detail = "Windows error $($_.Exception.NativeErrorCode)" }
    Write-Host "ERROR: Failed at line $($_.InvocationInfo.ScriptLineNumber): $detail" -ForegroundColor Red
    $exitCode = 1
} finally {
    foreach ($lock in $locks) { Exit-SandboxLock -Lock $lock }
}
Stop-Grant -Code $exitCode
