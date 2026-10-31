# Installs a restricted Windows account for Claude Code. See ..\README.md before running it.
# Stays parsable in Windows PowerShell 5.1, so it can report a missing pwsh and install it.
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [string]$UserName = 'claude-code',
    [string]$ClaudeDrive,
    [string]$GitPath,
    [string]$Volumes,
    [string]$AllowPath,
    [string]$RemoveAllowPath,
    [switch]$SkipAclScan,
    [switch]$AclTestOnly,
    [string]$SandboxResume,
    [Parameter(ValueFromRemainingArguments)][string[]]$UnknownArguments
)

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
[Threading.Thread]::CurrentThread.CurrentCulture = $culture
$ErrorActionPreference = 'Stop'

$script:LogFile = $null
$script:Warnings = New-Object System.Collections.ArrayList
$script:ExitCode = 0

function Stop-Installation {
    # The window opened by -Verb RunAs closes at the end, so code and log path come last and it waits.
    param([int]$Code)
    if ($script:LogFile) { Write-Host "Exit code: $Code. Log: $($script:LogFile)" }
    else { Write-Host "Exit code: $Code." }
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        try { $null = Read-Host 'Press Enter to close' } catch { }
    }
    exit $Code
}

function Stop-WithError {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    if (Get-Command Write-SandboxMessage -ErrorAction SilentlyContinue) { Write-SandboxMessage -LogOnly -Level Error -Message $Message }
    Stop-Installation -Code 1
}

function Add-ReportWarning {
    param([string]$Message)
    $null = $script:Warnings.Add($Message)
    Write-SandboxMessage -Level Warn -Message $Message
}

if ($UnknownArguments) { Stop-WithError "Unknown argument: $($UnknownArguments -join ' ')" }

Import-Module (Join-Path $PSScriptRoot 'ClaudeSandbox.psm1') -Force -DisableNameChecking

# ---- Step 1: PowerShell, rights, architecture -------------------------------------------------

$usedReasons = @()
if ($SandboxResume) {
    $resume = ConvertFrom-SandboxResumeArgument -Value $SandboxResume
    $usedReasons = @($resume.Reasons)
    foreach ($name in $resume.Parameters.Keys) { Set-Variable -Name $name -Value $resume.Parameters[$name] }
    if ($resume.Parameters.ContainsKey('WhatIf') -and $resume.Parameters['WhatIf']) { $WhatIfPreference = $true }
}
$isWhatIf = [bool]$WhatIfPreference

if (-not (Test-SandboxAdministrator)) { Stop-WithError 'This script must run with administrator rights. See the README for the exact call.' }
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { Stop-WithError 'Start the script in a 64-bit PowerShell. In a 32-bit process %ProgramFiles% points to the x86 folder.' }

function Restart-Installation {
    param([string]$PwshFolder, [string]$ScriptPath, [string]$Reason)
    $parameters = @{
        UserName = $UserName; ClaudeDrive = $ClaudeDrive; GitPath = $GitPath; Volumes = $Volumes
        AllowPath = $AllowPath; RemoveAllowPath = $RemoveAllowPath
        SkipAclScan = [bool]$SkipAclScan; AclTestOnly = [bool]$AclTestOnly; WhatIf = $isWhatIf
    }
    $encoded = ConvertTo-SandboxResumeArgument -Parameters $parameters -UsedRestartReasons (@($usedReasons) + $Reason)
    & (Join-Path $PwshFolder 'pwsh.exe') -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -SandboxResume $encoded
    # Same console, exit code passed through. The inner run already waited for Enter.
    exit $LASTEXITCODE
}

$machinePwsh = Get-SandboxMachinePwsh
$inMachine = Test-SandboxRunningInMachinePwsh -PsHome $PSHOME -MachineLocation $machinePwsh
$firstAction = Get-SandboxRestartAction -InMachinePwsh $inMachine -MachinePwshFound ([bool]$machinePwsh) -LocationWritable $false -UsedReasons $usedReasons
if ($firstAction -eq 'FailLoop') { Stop-WithError 'The restart in the machine-wide PowerShell 7 did not work.' }
if ($firstAction -eq 'InstallPwsh') {
    if ($isWhatIf) {
        Write-Host 'What if: PowerShell 7 is missing machine-wide and would be installed with winget. Nothing else can be shown before that.'
        Stop-Installation -Code 0
    }
    $winget = Find-SandboxWinget
    if (-not $winget) { Stop-WithError 'PowerShell 7 is missing and winget was not found. Install PowerShell 7 for all users: https://aka.ms/powershell-release?tag=stable' }
    Write-Host 'Installing PowerShell 7 for all users...'
    try {
        $null = & $winget install --id Microsoft.PowerShell --exact --scope machine --silent --accept-package-agreements --accept-source-agreements 2>&1
        $wingetExit = $LASTEXITCODE
    } catch { $wingetExit = -1 }
    $machinePwsh = Get-SandboxMachinePwsh
    if (-not $machinePwsh) { Stop-WithError "PowerShell 7 could not be installed (winget exit code $wingetExit). Install it for all users: https://aka.ms/powershell-release?tag=stable" }
    $firstAction = 'RestartPwsh'
}
if ($firstAction -eq 'RestartPwsh') { Restart-Installation -PwshFolder $machinePwsh -ScriptPath $PSCommandPath -Reason 'pwsh' }

# From here on the script runs in the machine-wide pwsh 7.

$layout = Get-SandboxLayout -Test:$AclTestOnly
$realLayout = Get-SandboxLayout
$executorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$executorProfile = $env:USERPROFILE
$localFolder = Join-Path $env:LOCALAPPDATA 'ClaudeSandbox'

# ---- Step 2: account checks -------------------------------------------------------------------

$existingUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($existingUser -and $existingUser.SID.Value -eq $executorSid) { Stop-WithError "You are running this as '$UserName' itself. Run it from your own administrator account." }
$interactiveOwners = @(Get-SandboxInteractiveOwners)
if ($interactiveOwners.Count -gt 0 -and $interactiveOwners -notcontains $executorSid) {
    Stop-WithError 'The administrator account differs from the signed-in account. Link, password and firewall rule would land on the wrong account. Sign in with an account that has administrator rights.'
}
if ($interactiveOwners.Count -eq 0) { Write-Host 'WARNING: No desktop was found in this session, the signed-in account could not be compared.' -ForegroundColor Yellow }

# ---- Step 3: script location and own folders --------------------------------------------------

$writerSids = @(Get-SandboxTargetSids -UserName $UserName)
$problems = @(Get-SandboxFolderProblems -Path $realLayout.Root -WriterSids $writerSids -ExecutorSid $executorSid)
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host $problem }
    Stop-WithError "$($realLayout.Root) already exists and could have been prepared by a non-admin. Nothing was deleted. Review and remove it, then start again."
}
$locationWritable = Test-SandboxLocationWritable -Path $PSScriptRoot -Sids $writerSids
$locationAction = Get-SandboxRestartAction -InMachinePwsh $true -MachinePwshFound $true -LocationWritable $locationWritable -UsedReasons $usedReasons
if ($locationAction -eq 'FailLoop') { Stop-WithError "$PSScriptRoot is still writable for the target user." }
if ($locationAction -eq 'RestartInstall') {
    if ($isWhatIf) {
        Write-Host "What if: '$PSScriptRoot' is writable for the target user. The scripts would be copied to $($realLayout.Install) after confirmation and restarted from there."
    } else {
        Write-Host "The target user can write to $PSScriptRoot. Running from there would let it change what runs as administrator."
        Write-Host 'SHA256 of the scripts, compare them if you are not sure about their origin:'
        $sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
        foreach ($source in $sources) { Write-Host ('{0}  {1}' -f (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash, $source.Name) }
        Write-Host 'Earlier manipulation of these files cannot be detected by copying them.'
        if (-not (Read-SandboxYesNo -Prompt "Copy them to $($realLayout.Install) and continue from there?")) { Stop-WithError 'Stopped: the script does not run from a location the target user can write to.' }
        New-SandboxProtectedFolder -Path $realLayout.Root
        New-SandboxProtectedFolder -Path $realLayout.Install
        foreach ($source in $sources) { Copy-Item -LiteralPath $source.FullName -Destination $realLayout.Install -Force }
        Restart-Installation -PwshFolder $machinePwsh -ScriptPath (Join-Path $realLayout.Install 'Install-ClaudeSandbox.ps1') -Reason 'install'
    }
}

if ($isWhatIf) {
    Write-Host 'What if: the script would run these steps. This does not test any ACL, use -AclTestOnly on a VHDX for that.'
    $steps = if ($AclTestOnly) {
        @('create or reuse the test user', 'set grants and locks on the selected volumes', 'run Check, Root and Scan once as SYSTEM', 'run the self-test')
    } else {
        @('ensure Secondary Logon and Git', "create or update user '$UserName', store its password with DPAPI", 'restrict its groups', 'create the claude folder, grant the Git folder',
          'lock all fixed volumes and non-Windows folders on the system drive', 'block removable storage for the user', 'install Claude for the user if missing',
          'create the desktop link', 'test and add the firewall rules, register the scheduled tasks', 'run the self-test')
    }
    foreach ($step in $steps) { Write-Host " - $step" }
    if ($existingUser) {
        $running = @(Get-SandboxUserProcesses -Sid $existingUser.SID.Value)
        foreach ($process in $running) { Write-Host "Process of the target user that would have to end: $($process.Name) ($($process.ProcessId))" }
    }
    Stop-Installation -Code 0
}

New-SandboxProtectedFolder -Path $realLayout.Root
New-SandboxProtectedFolder -Path $realLayout.Install
New-SandboxProtectedFolder -Path $realLayout.Probe
New-SandboxProtectedFolder -Path $layout.Base
New-SandboxProtectedFolder -Path $layout.LockDir -UsersCanRead $false
New-SandboxProtectedFolder -Path $layout.LogDir -UsersCanRead $false
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-ClaudeSandboxProbe.ps1') -Destination $realLayout.Probe -Force

if ($AclTestOnly) {
    $script:LogFile = Join-Path $layout.LogDir 'install.log'
} else {
    if (-not (Test-Path -LiteralPath $localFolder)) {
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in $executorSid, 'S-1-5-18', 'S-1-5-32-544') {
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $localFolder)
    }
    $script:LogFile = Join-Path $localFolder 'install.log'
}
Set-SandboxLogPath -Path $script:LogFile
Write-SandboxMessage -LogOnly -Message "Started by $executorSid from $PSScriptRoot, test mode: $AclTestOnly"

$main = {
    # ---- Step 4: prerequisites --------------------------------------------------------------------
    Write-SandboxMessage -Level Step -Message 'Checking prerequisites'
    $service = Get-Service -Name seclogon
    if ($service.StartType -eq 'Disabled') { Set-Service -Name seclogon -StartupType Manual }
    if ($service.Status -ne 'Running') { Start-Service -Name seclogon }

    $gitRoot = $null
    if (-not $AclTestOnly) {
        $findGit = {
            $candidates = @()
            $registered = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\GitForWindows' -ErrorAction SilentlyContinue
            if ($registered -and $registered.InstallPath) { $candidates += $registered.InstallPath.TrimEnd('\') }
            $candidates += (Join-Path $env:ProgramFiles 'Git')
            foreach ($candidate in $candidates) {
                $exe = Join-Path $candidate 'cmd\git.exe'
                if ((Test-Path -LiteralPath $exe) -and -not (Test-SandboxSidsCanWrite -Path $exe -Sids $writerSids)) { return $candidate }
            }
            return $null
        }
        $gitRoot = & $findGit
        if (-not $gitRoot) {
            $winget = Find-SandboxWinget
            if (-not $winget) { Stop-WithError 'Git is missing and winget was not found. Install Git for Windows for all users: https://git-scm.com/downloads/win' }
            Write-SandboxMessage -Message 'Installing Git for all users...'
            $code = Invoke-SandboxQuietProcess -FilePath $winget -Activity 'Installing Git' -ArgumentList @('install', '--id', 'Git.Git', '--exact', '--scope', 'machine', '--silent', '--accept-package-agreements', '--accept-source-agreements')
            $gitRoot = & $findGit
            if (-not $gitRoot) { Stop-WithError "Git could not be installed (winget exit code $code). Install Git for Windows for all users: https://git-scm.com/downloads/win" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $gitRoot 'bin\bash.exe'))) { Stop-WithError "bin\bash.exe is missing in $gitRoot. Repair the Git for Windows installation." }
    }

    # ---- Inputs and questions: everything is asked before the long phases -------------------------
    Write-SandboxMessage -Level Step -Message 'Collecting the settings'
    $prior = Read-SandboxJson -Path $layout.ConfigPath
    $priorSameUser = $prior -and $existingUser -and $prior.TargetSid -eq $existingUser.SID.Value
    if ($prior -and -not $priorSameUser) { $prior = $null }
    $existingProfile = if ($existingUser) {
        $entry = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($existingUser.SID.Value)" -ErrorAction SilentlyContinue
        if ($entry) { [Environment]::ExpandEnvironmentVariables($entry.ProfileImagePath) }
    }
    $info = Get-SandboxSystemInfo -ExecutorProfile $executorProfile -TargetProfile $existingProfile
    $volumeList = @(Get-SandboxVolumes)
    $requestedVolumes = @(Split-SandboxList -Value $Volumes)
    $volumeKeys = Resolve-SandboxVolumeSelection -Requested $requestedVolumes -Volumes $volumeList
    if (-not $volumeKeys -and $prior -and $prior.VolumeKeys) { $volumeKeys = @($prior.VolumeKeys) }
    if ($AclTestOnly) {
        if (-not $volumeKeys) { Stop-WithError '-AclTestOnly needs -Volumes.' }
        foreach ($volume in @($volumeList | Where-Object { $volumeKeys -contains $_.Key })) {
            $isVirtual = $false
            try {
                $letter = $volume.MountPath.Substring(0, 1)
                $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
                $isVirtual = (Get-Disk -Number $partition.DiskNumber -ErrorAction Stop).BusType -eq 'File Backed Virtual'
            } catch { }
            if (-not $isVirtual -and -not (Read-SandboxYesNo -Prompt "$($volume.MountPath) is not a virtual disk. Change its permissions anyway?")) { Stop-WithError 'Stopped: the test volume is not a virtual disk.' }
        }
    }

    $checkPath = {
        # Validates one input and returns its final path, or $null while its volume is locked.
        param([string]$Path, [string]$Kind, [string]$Stored, [string]$CurrentGit, [string]$CurrentClaude)
        $final = Resolve-SandboxFinalPath -Path $Path
        if ($Stored) {
            $now = Resolve-SandboxFinalPath -Path $Stored
            $owner = Get-SandboxVolumeOfPath -Path $Stored -Volumes $volumeList
            if ($owner -and $owner.Status -eq 'Locked') { return $Stored }
            if (-not (Test-SandboxSamePath -Left $now -Right $Stored)) { Stop-WithError "'$Stored' now resolves to '$now'. It may have been swapped for a junction. Check it before running again." }
            $final = $Stored
        }
        if (-not $final) { $final = [IO.Path]::GetFullPath($Path) }
        $owner = Get-SandboxVolumeOfPath -Path $final -Volumes $volumeList
        if (-not $owner) { Stop-WithError "'$final' is not on a fixed local volume." }
        if ($owner.Status -eq 'NoAcls') { Stop-WithError "'$final' is on a volume without permissions and cannot be secured." }
        if ($AclTestOnly -and $volumeKeys -notcontains $owner.Key) { Stop-WithError "'$final' is not on one of the -Volumes." }
        $check = Get-SandboxPathRejection -Path $final -Kind $Kind -Info $info -GitPath $CurrentGit -ClaudePath $CurrentClaude
        if (-not $check.Ok) { Stop-WithError "'$final' cannot be used: $($check.Reason)" }
        if ($check.NeedsConfirmation -and -not $Stored -and -not (Read-SandboxYesNo -Prompt "'$final' is inside your own profile. The target user gets access to it. Continue?")) { Stop-WithError 'Stopped at your request.' }
        return $final
    }

    $claudePath = $null
    $oldClaude = if ($prior) { $prior.ClaudePath }
    if (-not $AclTestOnly) {
        if ($oldClaude -and -not $ClaudeDrive) {
            $claudePath = & $checkPath -Path $oldClaude -Kind Claude -Stored $oldClaude
        } else {
            $candidates = @($volumeList | Where-Object { $_.Status -eq 'Available' })
            if ($candidates.Count -eq 0) { Stop-WithError 'No volume is available for the claude folder.' }
            $choice = $ClaudeDrive
            while (-not $choice) {
                Write-Host 'Volumes for the claude folder:'
                foreach ($candidate in $candidates) { Write-Host " - $($candidate.MountPath)" }
                $choice = Read-SandboxValue -Prompt 'On which volume should the claude folder be created? (for example D:)'
                if (-not $choice -and -not (Test-SandboxInteractive)) { Stop-WithError 'Pass -ClaudeDrive when running without a console.' }
            }
            $selected = $candidates | Where-Object { Test-SandboxSamePath -Left $_.MountPath -Right ($choice.TrimEnd('\') + '\') } | Select-Object -First 1
            if (-not $selected) { Stop-WithError "'$choice' is not an available volume with permissions." }
            $claudeCandidate = Join-Path $selected.MountPath 'claude'
            if (Test-Path -LiteralPath $claudeCandidate) {
                if ((Get-Item -LiteralPath $claudeCandidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-WithError "'$claudeCandidate' is a reparse point." }
            }
            $claudePath = & $checkPath -Path $claudeCandidate -Kind Claude
        }
    }

    $oldGit = if ($prior) { $prior.GitPath }
    $finalGit = $null
    $gitInput = $GitPath
    if (-not $gitInput -and $oldGit) { $finalGit = & $checkPath -Path $oldGit -Kind Git -Stored $oldGit -CurrentClaude $claudePath }
    elseif (-not $gitInput -and -not $AclTestOnly) {
        while (-not $gitInput) {
            $gitInput = Read-SandboxValue -Prompt 'Where do your Git repositories live? The target user gets read and write access there'
            if (-not $gitInput -and -not (Test-SandboxInteractive)) { Stop-WithError 'Pass -GitPath when running without a console.' }
        }
    }
    if ($gitInput) { $finalGit = & $checkPath -Path $gitInput -Kind Git -CurrentClaude $claudePath }

    $removed = @(Split-SandboxList -Value $RemoveAllowPath | ForEach-Object { $resolved = Resolve-SandboxFinalPath -Path $_; if ($resolved) { $resolved } else { $_ } })
    $allowFinal = [Collections.Generic.List[string]]::new()
    foreach ($stored in @(if ($prior) { $prior.AllowPaths })) {
        if (-not $stored -or @($removed | Where-Object { Test-SandboxSamePath -Left $_ -Right $stored }).Count -gt 0) { continue }
        $allowFinal.Add((& $checkPath -Path $stored -Kind Allow -Stored $stored -CurrentGit $finalGit -CurrentClaude $claudePath))
    }
    foreach ($requested in Split-SandboxList -Value $AllowPath) {
        $value = & $checkPath -Path $requested -Kind Allow -CurrentGit $finalGit -CurrentClaude $claudePath
        if (@($allowFinal | Where-Object { Test-SandboxSamePath -Left $_ -Right $value }).Count -eq 0) { $allowFinal.Add($value) }
    }

    $priorPaths = @(@(if ($prior) { @($prior.GitPath, $prior.ClaudePath) + @($prior.AllowPaths) }) | Where-Object { $_ })
    $currentPaths = @(@($finalGit, $claudePath) + @($allowFinal) | Where-Object { $_ })
    $abandonedPaths = @($priorPaths | Where-Object { $old = $_; @($currentPaths | Where-Object { Test-SandboxSamePath -Left $_ -Right $old }).Count -eq 0 })
    $newlyGranted = @($currentPaths | Where-Object { $new = $_; @($priorPaths | Where-Object { Test-SandboxSamePath -Left $_ -Right $new }).Count -eq 0 })

    $createGit = $finalGit -and -not (Test-Path -LiteralPath $finalGit)
    if ($createGit -and -not (Read-SandboxYesNo -Prompt "'$finalGit' does not exist. Create it?" -Default $true)) { Stop-WithError 'Stopped: the Git folder does not exist.' }

    $trustRepos = [Collections.Generic.List[string]]::new()
    $gitName = $null
    $gitEmail = $null
    $deleteShadowCopies = $false
    $shadowCount = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue).Count
    if (-not $AclTestOnly) {
        $gitExe = Join-Path $gitRoot 'cmd\git.exe'
        if ($finalGit -and (Test-Path -LiteralPath $finalGit) -and $existingUser) {
            foreach ($repo in Get-ChildItem -LiteralPath $finalGit -Directory -Force -ErrorAction SilentlyContinue) {
                if ($repo.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $repo.FullName '.git'))) { continue }
                if ((Get-Acl -LiteralPath $repo.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $existingUser.SID.Value) { continue }
                $prompt = "'$($repo.FullName)' belongs to the target user. Trust it in your own Git config? Hooks placed there would then run under your account"
                if (Read-SandboxYesNo -Prompt $prompt) { $trustRepos.Add($repo.FullName.Replace('\', '/')) }
            }
        }
        # The values are the user's own Git config, not localized tool text.
        $gitName = Read-SandboxValue -Prompt 'Git user.name for the target user' -Default ([string](& $gitExe config --global --get user.name 2>$null))
        $gitEmail = Read-SandboxValue -Prompt 'Git user.email for the target user' -Default ([string](& $gitExe config --global --get user.email 2>$null))
    }
    if ($shadowCount -gt 0 -and -not $AclTestOnly) {
        $deleteShadowCopies = Read-SandboxYesNo -Prompt "$shadowCount shadow copies exist. They keep old, possibly more open permissions. Delete ALL of them? This also removes those restore points"
    }

    # ---- Processes of the target user: ended right before the first change to the account -----------
    if ($existingUser) {
        $running = @(Get-SandboxUserProcesses -Sid $existingUser.SID.Value)
        if ($running.Count -gt 0) {
            Write-Host "The target user has $($running.Count) running processes. They would keep old groups and open handles:"
            foreach ($process in $running) { Write-Host " - $($process.Name) ($($process.ProcessId))" }
            if (-not (Read-SandboxYesNo -Prompt 'End them now? A Claude session of this user ends as well')) { Stop-WithError 'Stopped: the processes of the target user are still running.' }
            foreach ($process in $running) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }

    # ---- Step 5 and 6: user and password ----------------------------------------------------------
    Write-SandboxMessage -Level Step -Message "Setting up user '$UserName'"
    $credentialPath = Join-Path $localFolder 'credential.xml'
    $password = $null
    $isKnownTestUser = $false
    if ($AclTestOnly -and $existingUser) {
        $testConfig = Read-SandboxJson -Path $layout.ConfigPath
        $isKnownTestUser = $testConfig -and $testConfig.TargetSid -eq $existingUser.SID.Value
    }
    if (-not $existingUser) {
        $password = New-SandboxPassword
        $existingUser = New-LocalUser -Name $UserName -Password $password -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -Description 'Restricted account for Claude Code'
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $existingUser.SID.Value -ErrorAction SilentlyContinue
    } elseif ($isKnownTestUser) {
        $password = New-SandboxPassword
        Set-LocalUser -SID $existingUser.SID.Value -Password $password
    } else {
        if (-not $AclTestOnly -and (Test-Path -LiteralPath $credentialPath)) {
            try {
                $stored = Import-Clixml -LiteralPath $credentialPath
                if (Test-SandboxLogon -UserName $UserName -Password $stored.Password) { $password = $stored.Password }
            } catch { Write-SandboxMessage -Level Warn -Message 'The stored password could not be read.' }
        }
        for ($attempt = 1; -not $password -and $attempt -le 3 -and (Test-SandboxInteractive); $attempt++) {
            $entered = Read-Host "Password of '$UserName' (attempt $attempt of 3)" -AsSecureString
            if (Test-SandboxLogon -UserName $UserName -Password $entered) { $password = $entered }
            else { Write-SandboxMessage -Level Warn -Message 'The password was not accepted.' }
        }
        if (-not $password) {
            if ($AclTestOnly) { Stop-WithError 'The password of the test user is unknown. Use a new test user name.' }
            Write-Host 'Resetting the password loses data of this user that Windows protects with it (DPAPI), such as stored Git credentials.'
            if (-not (Read-SandboxYesNo -Prompt 'Reset the password to a new random one?')) { Stop-WithError 'Stopped: the password of the target user is unknown.' }
            $password = New-SandboxPassword
            Set-LocalUser -SID $existingUser.SID.Value -Password $password
        }
    }
    $targetSid = $existingUser.SID.Value
    if (-not $existingUser.Enabled) { Enable-LocalUser -SID $targetSid }
    Set-LocalUser -SID $targetSid -PasswordNeverExpires $true -UserMayChangePassword $false
    $credential = [pscredential]::new($UserName, $password)
    if (-not $AclTestOnly) { $credential | Export-Clixml -LiteralPath $credentialPath }

    # ---- Step 7: groups -----------------------------------------------------------------------------
    if (-not $AclTestOnly) {
        foreach ($group in Get-SandboxUserGroups -UserSid $targetSid) {
            if ($group.SID -eq 'S-1-5-32-545') { continue }
            Remove-LocalGroupMember -SID $group.SID -Member $targetSid
            Add-ReportWarning "Removed '$UserName' from the group '$($group.Name)'."
        }
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $targetSid -ErrorAction SilentlyContinue
    }
    if (@(Get-SandboxUserGroups -UserSid $targetSid | Where-Object { $_.SID -eq 'S-1-5-32-544' }).Count -gt 0) { Stop-WithError "'$UserName' is still an administrator. Nothing further was changed." }

    # ---- Step 8: profile and token --------------------------------------------------------------------
    Write-SandboxMessage -Level Step -Message 'Creating the profile and reading the token'
    $probe = Invoke-SandboxProbe -Credential $credential -PwshPath $machinePwsh -Layout $realLayout
    if ($probe.Sid -ne $targetSid) { Stop-WithError 'The probe did not run as the target user.' }
    if (Test-SandboxSamePath -Left $probe.Profile -Right $executorProfile) { Stop-WithError 'The target user did not get its own profile.' }
    $targetProfile = $probe.Profile
    $tokenSids = @(@($probe.Sid) + @($probe.Groups) | Select-Object -Unique)

    # ---- Step 9: toolchains ---------------------------------------------------------------------------
    $toolchains = [Collections.Generic.List[string]]::new()
    $pathEntries = [Collections.Generic.List[string]]::new()
    if (-not $AclTestOnly) {
        foreach ($tool in Get-SandboxToolchains) { $toolchains.Add($tool) }
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if ((Test-Path -LiteralPath $vswhere) -and -not (Test-SandboxSidsCanWrite -Path $vswhere -Sids $writerSids)) {
            # The one explicit exception to "never read tool output": a documented JSON format.
            try {
                foreach ($instance in @(& $vswhere -products '*' -format json | Out-String | ConvertFrom-Json)) {
                    if ($instance.installationPath) { $toolchains.Add($instance.installationPath.TrimEnd('\')) }
                }
            } catch { Write-SandboxMessage -Level Warn -Message 'vswhere could not be read.' }
        }
        if ($gitRoot) { $toolchains.Add($gitRoot) }
        foreach ($installation in @($toolchains | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'MSBuild\Current\Bin\MSBuild.exe') })) {
            $pathEntries.Add((Join-Path $installation 'MSBuild\Current\Bin'))
        }
        if ($probe.ClaudePath) {
            $claudeFolder = Split-Path -Parent $probe.ClaudePath
            if (-not (Test-SandboxPathWithin -Path $claudeFolder -Base $targetProfile)) { $toolchains.Add($claudeFolder) }
        }
    }
    $uniqueToolchains = @($toolchains | Select-Object -Unique)

    $config = @{
        Version = 1; Test = [bool]$AclTestOnly; UserName = $UserName; TargetSid = $targetSid; TokenSids = $tokenSids
        ExecutorSid = $executorSid; ExecutorProfile = $executorProfile; TargetProfile = $targetProfile
        ClaudePath = $claudePath; GitPath = $finalGit; AllowPaths = @($allowFinal); Toolchains = $uniqueToolchains
        VolumeKeys = $volumeKeys; FirewallVerified = $false; PwshPath = $machinePwsh
    }
    Write-SandboxJson -Path $layout.ConfigPath -Value $config

    # ---- Step 10: directories ---------------------------------------------------------------------------
    Write-SandboxMessage -Level Step -Message 'Preparing the claude and Git folders'
    foreach ($old in $abandonedPaths) {
        if (Test-Path -LiteralPath $old) {
            # The allow goes first, so the tree is no longer writable when Phase 2 walks through it.
            $null = Invoke-SandboxIcacls -Path $old -Operation @('/remove:g', "*$targetSid")
            Write-SandboxMessage -Message "Released access to $old."
        }
    }
    foreach ($new in $newlyGranted) {
        # An old deny would beat the new allow. The tree is not writable for the target yet.
        if (Test-Path -LiteralPath $new) { Remove-SandboxSidAces -Path $new -Sid $targetSid -DenyOnly }
    }
    if ($claudePath -and -not (Test-Path -LiteralPath $claudePath)) {
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in $targetSid, $executorSid, 'S-1-5-18', 'S-1-5-32-544') {
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $claudePath)
    } elseif ($claudePath) {
        Add-ReportWarning "$claudePath already existed. Its other permissions were kept."
    }
    if ($createGit) {
        $null = [IO.Directory]::CreateDirectory($finalGit)
        $null = Invoke-SandboxIcacls -Path $finalGit -Operation @('/grant', "*${executorSid}:(OI)(CI)(M)")
    }
    foreach ($writable in @($claudePath, $finalGit) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
        # Read-only look, no reparse points followed. Admin and SYSTEM never change anything below the top folder.
        $pending = [Collections.Generic.Queue[object]]::new()
        $pending.Enqueue(@($writable, 0))
        while ($pending.Count -gt 0) {
            $current, $depth = $pending.Dequeue()
            foreach ($child in Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                try {
                    if ((Get-Acl -LiteralPath $child.FullName).AreAccessRulesProtected) { Add-ReportWarning "$($child.FullName) does not inherit and may not be accessible for the target user." }
                } catch { }
                if ($depth -lt 2) { $pending.Enqueue(@($child.FullName, ($depth + 1))) }
            }
        }
    }

    # ---- Step 11: permissions ---------------------------------------------------------------------------
    Write-SandboxMessage -Level Step -Message 'Setting permissions. This can take a long time, progress is shown below.'
    Stop-SandboxTasks
    $locks = [Collections.Generic.List[object]]::new()
    $junctionBefore = @{}
    try {
        foreach ($mode in 'Check', 'Root', 'Scan') {
            $lock = Enter-SandboxLock -Layout $layout -Name "mode-$mode" -TimeoutSeconds 120
            if (-not $lock) { Stop-WithError "The $mode task is still running and could not be stopped." }
            $locks.Add($lock)
        }
        $volumeList = @(Get-SandboxVolumes)
        $model = Get-SandboxModel -Config $config -Volumes $volumeList
        if ($AclTestOnly -and $finalGit -and (Test-Path -LiteralPath $finalGit)) {
            foreach ($child in Get-ChildItem -LiteralPath $finalGit -Force -ErrorAction SilentlyContinue) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $child.Target) {
                    foreach ($target in @($child.Target)) { $junctionBefore[$target] = (Get-Acl -LiteralPath $target).Sddl }
                }
            }
        }
        foreach ($volume in $volumeList) {
            if ($volumeKeys -and $volumeKeys -notcontains $volume.Key) { continue }
            if ($volume.Status -in 'Locked', 'NoAcls') {
                Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $volume.Status
                Add-ReportWarning "$($volume.MountPath): status $($volume.Status), not protected."
                continue
            }
            $volumeLock = Enter-SandboxLock -Layout $layout -Name "volume-$($volume.Key)" -TimeoutSeconds 60
            if (-not $volumeLock) { Stop-WithError "The volume $($volume.MountPath) is locked by a running task." }
            $locks.Add($volumeLock)
            Write-SandboxMessage -Message "Volume $($volume.MountPath): setting the deny and the releases"
            $protection = Set-SandboxVolumeProtection -Config $config -Model $model -Volume $volume -Volumes $volumeList -Layout $layout
            if (-not $protection.Ok) { Add-ReportWarning "$($volume.MountPath): some permissions could not be set." }
            if ($SkipAclScan) {
                Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $(if ($protection.Ok) { 'Unverified' } else { 'Incomplete' })
                continue
            }
            Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status 'Incomplete'
            Write-SandboxMessage -Message "Volume $($volume.MountPath): checking every object"
            $scan = Invoke-SandboxVolumeScan -Config $config -Model $model -Volume $volume -Layout $layout -Targets $protection.Targets
            $status = $scan.Status
            if (-not $protection.Ok) { $status = 'Incomplete' }
            Set-SandboxVolumeStatus -Layout $layout -Volume $volume -Status $status -Scan $scan
            Write-SandboxMessage -Message ("Volume {0}: {1}, {2:N0} objects, {3} unreadable, {4} write errors" -f $volume.MountPath, $status, $scan.Objects, $scan.Unreadable, $scan.WriteErrors)
        }
    } finally {
        foreach ($lock in $locks) { Exit-SandboxLock -Lock $lock }
    }
    Update-SandboxState -Layout $layout -Change { param($state) $state['PartialVolumes'] = [bool]$volumeKeys }
    if ($volumeKeys) { Add-ReportWarning 'Only the selected volumes are protected (-Volumes).' }

    if ($AclTestOnly) {
        # ---- Probelauf: Phase 1 as SYSTEM, all three modes, without touching a real installation ------
        Write-SandboxMessage -Level Step -Message 'Running Check, Root and Scan once as SYSTEM'
        if (-not (Test-Path -LiteralPath $realLayout.ConfigPath)) {
            foreach ($name in 'Update-ClaudeSandbox.ps1', 'ClaudeSandbox.psm1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $realLayout.Root -Force }
        }
        foreach ($volume in @($volumeList | Where-Object { $volumeKeys -contains $_.Key -and $_.Status -eq 'Available' -and -not $_.IsSystem })) {
            $null = Invoke-SandboxIcacls -Path $volume.MountPath -Operation @('/remove', "*$targetSid")
        }
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest -LogonType ServiceAccount
        foreach ($mode in 'Check', 'Root', 'Scan') {
            $action = Get-SandboxTaskAction -PwshPath $machinePwsh -Mode $mode -Layout $realLayout -ConfigPath $layout.ConfigPath
            $null = Register-ScheduledTask -TaskName 'ClaudeSandbox-Test' -Action $action -Principal $principal -Force
            try {
                Start-ScheduledTask -TaskName 'ClaudeSandbox-Test'
                Start-Sleep -Seconds 2
                $clock = [Diagnostics.Stopwatch]::StartNew()
                while ((Get-ScheduledTask -TaskName 'ClaudeSandbox-Test').State -eq 'Running') {
                    Write-Progress -Activity "SYSTEM test: $mode" -Status ('{0:hh\:mm\:ss} elapsed' -f $clock.Elapsed)
                    Start-Sleep -Seconds 2
                }
                Write-Progress -Activity "SYSTEM test: $mode" -Completed
                $result = (Get-ScheduledTaskInfo -TaskName 'ClaudeSandbox-Test').LastTaskResult
            } finally {
                Unregister-ScheduledTask -TaskName 'ClaudeSandbox-Test' -Confirm:$false -ErrorAction SilentlyContinue
            }
            if ($result -ne 0) { Add-ReportWarning "The SYSTEM test of $mode ended with $result."; $script:ExitCode = 1 }
            $state = Read-SandboxJson -Path $layout.StatePath
            if ($mode -eq 'Check' -and -not $state.RootNeeded) { Add-ReportWarning 'Check did not notice the removed deny.'; $script:ExitCode = 1 }
            if ($mode -eq 'Root') {
                foreach ($volume in @($volumeList | Where-Object { $volumeKeys -contains $_.Key -and $_.Status -eq 'Available' -and -not $_.IsSystem })) {
                    if (-not (Test-SandboxContainerRules -Path $volume.MountPath -Sid $targetSid)) { Add-ReportWarning "Root did not restore the deny on $($volume.MountPath)."; $script:ExitCode = 1 }
                }
            }
        }
        foreach ($target in $junctionBefore.Keys) {
            if ((Get-Acl -LiteralPath $target).Sddl -ne $junctionBefore[$target]) { Add-ReportWarning "The ACL of the junction target $target changed."; $script:ExitCode = 1 }
            else { Write-SandboxMessage -Level Ok -Message "The ACL of the junction target $target is unchanged." }
        }
    } else {
        # ---- Step 12 and 13: removable storage, PATH, Claude ------------------------------------------
        Write-SandboxMessage -Level Step -Message 'Blocking removable storage and installing Claude if needed'
        $current = Invoke-SandboxProbe -Credential $credential -PwshPath $machinePwsh -Layout $realLayout
        if (-not $current.ClaudePath) {
            Write-SandboxMessage -Message 'Installing Claude for the target user...'
            $install = Invoke-SandboxUserProcess -Credential $credential -FilePath (Join-Path $machinePwsh 'pwsh.exe') -TimeoutSeconds 900 -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://claude.ai/install.ps1 | iex'
            )
            if ($install.ExitCode -ne 0) { Add-ReportWarning "The Claude installer ended with exit code $($install.ExitCode)."; $script:ExitCode = 1 }
        }
        $localBin = '%USERPROFILE%\.local\bin'
        $entries = @($pathEntries) + $localBin
        $terminalStatus = Register-SandboxTerminal -Credential $credential
        switch ($terminalStatus) {
            'Available' {
                Write-SandboxMessage -Level Ok -Message 'Windows Terminal is available for the target user.'
                $entries += '%USERPROFILE%\AppData\Local\Microsoft\WindowsApps'
            }
            'NotInstalled' { Write-SandboxMessage -Message 'Windows Terminal is not installed, the link opens a plain console window.' }
            default { Add-ReportWarning 'Windows Terminal could not be registered for the target user, the link opens a plain console window. Signing in once with that account usually registers it.' }
        }
        $hiveOk = Invoke-SandboxWithUserHive -Sid $targetSid -ProfilePath $targetProfile -Action {
            param($hive)
            $policy = $hive.CreateSubKey('Software\Policies\Microsoft\Windows\RemovableStorageDevices')
            try { $policy.SetValue('Deny_All', 1, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $policy.Dispose() }
            Set-SandboxUserPathEntries -Root $hive -Entries $entries
        }
        if (-not $hiveOk) { Add-ReportWarning 'The registry of the target user could not be loaded: removable storage is not blocked and PATH was not extended. Run the script again.'; $script:ExitCode = 1 }

        # ---- Step 14 and 15: Git configuration ----------------------------------------------------------
        Write-SandboxMessage -Level Step -Message 'Configuring Git'
        $gitVersion = (Get-Item -LiteralPath $gitExe).VersionInfo.FileVersionRaw
        $safeValues = [Collections.Generic.List[string]]::new()
        if ($gitVersion -ge [version]'2.46') {
            $safeValues.Add($finalGit.Replace('\', '/') + '/*')
        } elseif (Test-Path -LiteralPath $finalGit) {
            foreach ($repo in Get-ChildItem -LiteralPath $finalGit -Directory -Force -ErrorAction SilentlyContinue) {
                if (Test-Path -LiteralPath (Join-Path $repo.FullName '.git')) { $safeValues.Add($repo.FullName.Replace('\', '/')) }
            }
        }
        $asTarget = { param([string[]]$Arguments) (Invoke-SandboxUserProcess -Credential $credential -FilePath $gitExe -ArgumentList $Arguments -WorkingDirectory $targetProfile).ExitCode }
        foreach ($value in $safeValues) {
            if ((& $asTarget @('config', '--global', '--fixed-value', '--get-all', 'safe.directory', $value)) -ne 0) {
                $null = & $asTarget @('config', '--global', '--add', 'safe.directory', $value)
            }
        }
        if ($gitName -and (& $asTarget @('config', '--global', '--get', 'user.name')) -ne 0) { $null = & $asTarget @('config', '--global', 'user.name', $gitName) }
        if ($gitEmail -and (& $asTarget @('config', '--global', '--get', 'user.email')) -ne 0) { $null = & $asTarget @('config', '--global', 'user.email', $gitEmail) }
        foreach ($repo in $trustRepos) {
            if ((Invoke-SandboxQuietProcess -FilePath $gitExe -ArgumentList @('config', '--global', '--fixed-value', '--get-all', 'safe.directory', $repo)) -ne 0) {
                $null = Invoke-SandboxQuietProcess -FilePath $gitExe -ArgumentList @('config', '--global', '--add', 'safe.directory', $repo)
            }
        }

        # ---- Step 16: desktop link ----------------------------------------------------------------------
        Write-SandboxMessage -Level Step -Message 'Creating the desktop link'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Show-ClaudeStatus.ps1') -Destination $realLayout.Root -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-ClaudeTerminal.ps1') -Destination $localFolder -Force
        Write-SandboxJson -Path (Join-Path $localFolder 'terminal.json') -Value @{
            ClaudePath = $claudePath; PwshPath = $machinePwsh; StatusScript = (Join-Path $realLayout.Root 'Show-ClaudeStatus.ps1')
        }
        $pwshExe = Join-Path $machinePwsh 'pwsh.exe'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Terminal.lnk'))
        $link.TargetPath = $pwshExe
        $link.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $localFolder 'Start-ClaudeTerminal.ps1')`""
        $link.WorkingDirectory = $localFolder
        $link.IconLocation = "$pwshExe,0"
        $link.Description = "Terminal as $UserName in $claudePath"
        $link.Save()

        # ---- Step 17: firewall and tasks ----------------------------------------------------------------
        Write-SandboxMessage -Level Step -Message 'Testing the firewall block and registering the tasks'
        foreach ($name in 'Update-ClaudeSandbox.ps1', 'ClaudeSandbox.psm1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $realLayout.Root -Force }
        foreach ($source in Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
            if (-not (Test-SandboxSamePath -Left $PSScriptRoot -Right $realLayout.Install)) { Copy-Item -LiteralPath $source.FullName -Destination $realLayout.Install -Force }
        }
        $firewallStatus = 'NotImplementedFirewallInactive'
        if (Test-SandboxFirewallEnabled) {
            New-SandboxProtectedFolder -Path $realLayout.FwTest
            $firewallStatus = Test-SandboxFirewallScoping -Credential $credential -ExecutorSid $executorSid -Layout $realLayout
        }
        $config['FirewallVerified'] = $firewallStatus -eq 'Passed'
        Write-SandboxJson -Path $layout.ConfigPath -Value $config
        Update-SandboxState -Layout $layout -Change { param($state) $state['FirewallStatus'] = $firewallStatus }
        if ($firewallStatus -eq 'Passed') {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $programs = Get-SandboxClaudeBlockPaths -ExecutorProfile $executorProfile -UserPathValue $userPath
            Sync-SandboxFirewallRules -ExecutorSid $executorSid -Programs $programs
            Write-SandboxMessage -Level Ok -Message "Firewall block set for $(@($programs).Count) Claude paths, only for your account."
        } else {
            Add-ReportWarning "The firewall block for your account is NOT set: $firewallStatus. Run the script again to repeat the test."
            if ($script:ExitCode -eq 0) { $script:ExitCode = 2 }
        }
        Register-SandboxTasks -PwshPath $machinePwsh -Layout $realLayout

        if ($deleteShadowCopies) {
            foreach ($copy in Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue) { Remove-CimInstance -InputObject $copy -ErrorAction SilentlyContinue }
        }
    }

    if ($shadowCount -gt 0 -and -not $deleteShadowCopies -and -not $AclTestOnly) { Add-ReportWarning "$shadowCount shadow copies keep old permissions and may be readable for the target user." }

    # ---- Step 18: self-test ---------------------------------------------------------------------------
    Write-SandboxMessage -Level Step -Message 'Self-test as the target user'
    $leftover = @(Get-SandboxUserProcesses -Sid $targetSid)
    if ($leftover.Count -gt 0) { Add-ReportWarning "$($leftover.Count) processes of the target user are still running and may keep old rights." }

    $state = Read-SandboxJson -Path $layout.StatePath
    $tests = [Collections.Generic.List[object]]::new()
    $addTest = { param($name, $op, $path, $expect, $arguments) $tests.Add(@{ Name = $name; Op = $op; Path = $path; Expect = $expect; Arguments = @($arguments) }) }
    if (-not $AclTestOnly) {
        & $addTest 'Password file is not readable' 'ReadFile' $credentialPath 'Denied'
        & $addTest 'Claude folder is writable' 'WriteFile' $claudePath 'Allowed'
        & $addTest 'claude starts' 'Run' 'claude' 'Exit0' @('--version')
        & $addTest 'Git Bash starts' 'Run' (Join-Path $gitRoot 'bin\bash.exe') 'Exit0' @('-c', 'exit')
        & $addTest 'git starts' 'Run' $gitExe 'Exit0' @('--version')
        if (@($pathEntries).Count -gt 0) { & $addTest 'msbuild starts by name' 'Run' 'msbuild' 'Exit0' @('-version') }
        $dotnetKey = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\dotnet\Setup\InstalledVersions\x64' -ErrorAction SilentlyContinue
        if ($dotnetKey -and $dotnetKey.InstallLocation) { & $addTest 'dotnet starts' 'Run' (Join-Path $dotnetKey.InstallLocation 'dotnet.exe') 'Exit0' @('--info') }
    }
    if ($finalGit -and (Test-Path -LiteralPath $finalGit)) {
        & $addTest 'Git folder is writable' 'WriteFile' $finalGit 'Allowed'
        if (-not $AclTestOnly) {
            $sampleRepo = Get-ChildItem -LiteralPath $finalGit -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } | Select-Object -First 1
            if ($sampleRepo) { & $addTest 'git status works in a repository' 'Run' $gitExe 'Exit0' @('-C', $sampleRepo.FullName, 'status') }
        }
    }
    foreach ($path in $allowFinal) { if (Test-Path -LiteralPath $path) { & $addTest "Release is readable: $path" 'ListDirectory' $path 'Allowed' } }
    foreach ($parent in $model.Parents) {
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        & $addTest "Parent is not listable: $parent" 'ListDirectory' $parent 'Denied'
        foreach ($sibling in @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not $model.Exempt.Contains($_.FullName) -and -not $model.Parents.Contains($_.FullName) } | Select-Object -First 3)) {
            & $addTest "Sibling is locked: $($sibling.FullName)" 'ListDirectory' $sibling.FullName 'Denied'
        }
    }
    foreach ($volume in $volumeList) {
        $entry = if ($state.Volumes) { $state.Volumes[$volume.Key] }
        if (-not $entry -or $entry.Status -notin 'Protected', 'ProtectedWithExceptions', 'Unverified') { continue }
        if ($volume.IsSystem) {
            & $addTest 'System drive root stays listable' 'ListDirectory' $volume.MountPath 'Allowed'
            & $addTest 'Creating a folder in the system drive root is denied' 'CreateDirectory' $volume.MountPath 'Denied'
            foreach ($target in @(Get-SandboxSystemDriveTargets -Model $model | Where-Object { $_.IsDirectory } | Select-Object -First 5)) {
                & $addTest "Locked: $($target.Path)" 'ListDirectory' $target.Path 'Denied'
            }
        } else {
            & $addTest "Root is not listable: $($volume.MountPath)" 'ListDirectory' $volume.MountPath 'Denied'
            & $addTest "Creating a folder in the root is denied: $($volume.MountPath)" 'CreateDirectory' $volume.MountPath 'Denied'
            foreach ($foreign in @(Get-ChildItem -LiteralPath $volume.MountPath -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -notin 'System Volume Information', '$RECYCLE.BIN' -and -not $model.Exempt.Contains($_.FullName) -and -not $model.Parents.Contains($_.FullName) } | Select-Object -First 3)) {
                & $addTest "Foreign folder is locked: $($foreign.FullName)" 'WriteFile' $foreign.FullName 'Denied'
            }
        }
    }
    $selfTest = Invoke-SandboxProbe -Credential $credential -PwshPath $machinePwsh -Layout $realLayout -Tests @($tests)
    if (Test-SandboxSamePath -Left $selfTest.Profile -Right $targetProfile) { Write-SandboxMessage -Level Ok -Message 'The target user runs with its own profile.' }
    else { Add-ReportWarning 'USERPROFILE of the target user is not its own profile.'; $script:ExitCode = 1 }
    if ($selfTest.Groups -contains 'S-1-5-32-544') { Add-ReportWarning 'The target user is an administrator.'; $script:ExitCode = 1 }
    foreach ($result in @($selfTest.Results)) {
        $passed = $result.Outcome -eq $result.Expect
        if ($result.Name -eq 'Password file is not readable' -and $result.Outcome -eq 'Missing') { $passed = $true }
        if ($passed) { Write-SandboxMessage -Level Ok -Message $result.Name }
        else { Add-ReportWarning "Self-test failed: $($result.Name) (expected $($result.Expect), got $($result.Outcome))."; $script:ExitCode = 1 }
    }

    # ---- Report ---------------------------------------------------------------------------------------
    if (-not $AclTestOnly) {
        foreach ($entry in ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ } | Select-Object -Unique)) {
            try {
                $expanded = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
                if (-not (Test-Path -LiteralPath $expanded)) { continue }
                if (Test-SandboxSidsCanWrite -Path $expanded -Sids $tokenSids) { Add-ReportWarning "PATH folder $expanded is writable for the target user. Programs placed there could start under your account." }
                $reachable = @($model.Info.Untouched) + @($model.Exempt)
                if (@($reachable | Where-Object { Test-SandboxPathWithin -Path $expanded -Base $_ }).Count -eq 0) { Write-SandboxMessage -Message "Note: the PATH entry $expanded is locked for the target user. Release it with -AllowPath if needed." }
            } catch { Add-ReportWarning "PATH folder $entry could not be checked ($($_.Exception.GetType().Name))." }
        }
        Write-SandboxMessage -Message 'Not blocked by the firewall on purpose: the Claude desktop app and programs that Claude starts (git, curl).'
        Write-SandboxMessage -Message 'System Volume Information and $RECYCLE.BIN keep only the deny from the volume root, their content is not checked one by one.'
    }

    $state = Read-SandboxJson -Path $layout.StatePath
    $gaps = $false
    foreach ($key in $state.Volumes.Keys) {
        $entry = $state.Volumes[$key]
        Write-SandboxMessage -Message "Volume $($entry.MountPath): $($entry.Status)"
        if ($entry.Status -in 'Incomplete', 'Unverified') { $script:ExitCode = 1 }
        if ($entry.Status -in 'Locked', 'NoAcls') { $gaps = $true }
    }
    if ($gaps -and $script:ExitCode -eq 0) { $script:ExitCode = 2 }
    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host "Warnings ($($script:Warnings.Count)):" -ForegroundColor Yellow
        foreach ($warning in $script:Warnings) { Write-Host " - $warning" -ForegroundColor Yellow }
    }
    if (-not $AclTestOnly) {
        Write-Host ''
        Write-Host 'Next: double-click "Claude Terminal" on your desktop, run claude and sign in. Sign in to GitHub on the first push.'
    }
}

try {
    & $main
} catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    $detail = $_.Exception.Message
    if ($_.Exception -is [ComponentModel.Win32Exception]) { $detail = "Windows error $($_.Exception.NativeErrorCode)" }
    Write-SandboxMessage -Level Error -Message "Failed at line ${line}: $detail"
    Write-SandboxMessage -Level Error -Message 'A stop can leave parts open. Volumes stay Incomplete until a new run finishes.'
    $script:ExitCode = 1
}
Stop-Installation -Code $script:ExitCode
