# Shared logic of the claude-code-sandbox skill.
# The file stays parsable in Windows PowerShell 5.1 because Install-ClaudeSandbox.ps1 imports it there
# for the bootstrap functions. Everything below "ACL and system functions" only runs in pwsh 7.

$script:FixedWriterSids = @('S-1-1-0', 'S-1-5-32-545', 'S-1-5-11', 'S-1-5-4')
$script:AdministratorsSid = 'S-1-5-32-544'
$script:UsersSid = 'S-1-5-32-545'
$script:SystemSid = 'S-1-5-18'
$script:FirewallGroup = 'ClaudeCodeSandbox'
$script:TaskNames = @('ClaudeSandbox-Check', 'ClaudeSandbox-Root', 'ClaudeSandbox-Scan')
$script:TestTaskName = 'ClaudeSandbox-Test'
# Leaves ReadAttributes, Traverse and Synchronize open: Node runs lstat on every path component.
$script:SparedDeny = '(DE,RC,WDAC,WO,RD,WD,AD,REA,WEA,DC,WA)'
$script:WindowsOwnNames = @('PerfLogs', 'Recovery', 'Boot', '$Recycle.Bin', 'System Volume Information', '$WinREAgent', '$SysReset', '$Windows.~BT', '$Windows.~WS', 'Config.Msi', 'Windows.old', 'OneDriveTemp')
$script:WindowsOwnFiles = @('pagefile.sys', 'swapfile.sys', 'hiberfil.sys', 'bootmgr', 'BOOTNXT', 'BOOTSECT.BAK', 'DumpStack.log', 'DumpStack.log.tmp')
$script:LogPath = $null
$script:RepositoryUrl = 'https://github.com/EvilPingu/skills.git'
$script:RepositoryRawCommitBase = 'https://raw.githubusercontent.com/EvilPingu/skills/{0}/claude-code-sandbox/scripts/'
# The files that make up the version. A new script has to be added here, which changes the hash as well.
$script:SandboxFiles = @('ClaudeSandbox.psm1', 'Grant-ClaudeSandboxPath.ps1', 'Install-ClaudeSandbox.ps1', 'Invoke-ClaudeSandboxProbe.ps1', 'Show-ClaudeStatus.ps1', 'Start-ClaudeTerminal.ps1', 'Uninstall-ClaudeSandbox.ps1', 'Update-ClaudeSandbox.ps1')

# ---------------------------------------------------------------------------------------------
# Bootstrap functions (also used from Windows PowerShell 5.1)
# ---------------------------------------------------------------------------------------------

function Set-SandboxCulture {
    $culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    [Threading.Thread]::CurrentThread.CurrentUICulture = $culture
    [Threading.Thread]::CurrentThread.CurrentCulture = $culture
}

function Split-SandboxList {
    param([string]$Value)
    if (-not $Value) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-SandboxAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SandboxSamePath {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    return [string]::Equals($Left.TrimEnd('\'), $Right.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Test-SandboxPathWithin {
    param([string]$Path, [string]$Base)
    if (-not $Path -or -not $Base) { return $false }
    $p = $Path.TrimEnd('\')
    $b = $Base.TrimEnd('\')
    if ([string]::Equals($p, $b, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SandboxMachinePwsh {
    $key = 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    foreach ($version in Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue) {
        $location = (Get-ItemProperty -LiteralPath $version.PSPath -ErrorAction SilentlyContinue).InstallLocation
        if ($location -and (Test-Path -LiteralPath (Join-Path $location 'pwsh.exe'))) { return $location.TrimEnd('\') }
    }
    return $null
}

function Test-SandboxRunningInMachinePwsh {
    param([string]$PsHome = $PSHOME, [string]$MachineLocation)
    return (Test-SandboxSamePath -Left $PsHome -Right $MachineLocation)
}

function ConvertTo-SandboxResumeArgument {
    param([hashtable]$Parameters, [string[]]$UsedRestartReasons)
    $payload = @{ Parameters = $Parameters; Reasons = @($UsedRestartReasons) } | ConvertTo-Json -Depth 4 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
}

function ConvertFrom-SandboxResumeArgument {
    param([string]$Value)
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
    $data = $json | ConvertFrom-Json
    $parameters = @{}
    foreach ($property in $data.Parameters.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    return @{ Parameters = $parameters; Reasons = @($data.Reasons | Where-Object { $_ }) }
}

function Get-SandboxRestartAction {
    <#
    .SYNOPSIS
    Decides the next start step. Started from 5.1 inside the repository two restarts are normal,
    so each reason has its own marker. A reason that was already used and still applies is an error.
    #>
    param([bool]$InMachinePwsh, [bool]$MachinePwshFound, [bool]$LocationWritable, [string[]]$UsedReasons = @())
    if (-not $InMachinePwsh) {
        if ($UsedReasons -contains 'pwsh') { return 'FailLoop' }
        if ($MachinePwshFound) { return 'RestartPwsh' }
        return 'InstallPwsh'
    }
    if ($LocationWritable) {
        if ($UsedReasons -contains 'install') { return 'FailLoop' }
        return 'RestartInstall'
    }
    return 'Continue'
}

function Set-SandboxQuiet {
    # Tasks have no console, so no progress output.
    $script:QuietProgress = $true
}

function Find-SandboxWinget {
    try {
        $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop | Select-Object -First 1
        if ($package -and (Test-Path -LiteralPath (Join-Path $package.InstallLocation 'winget.exe'))) {
            return (Join-Path $package.InstallLocation 'winget.exe')
        }
    } catch { }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    return $null
}

function Get-SandboxLayout {
    param([string]$ConfigPath, [switch]$Test)
    $root = Join-Path $env:ProgramData 'ClaudeSandbox'
    $base = $root
    if ($Test) { $base = Join-Path $root 'test' }
    if ($ConfigPath) { $base = Split-Path -Parent $ConfigPath }
    return @{
        Root       = $root
        Base       = $base
        Install    = (Join-Path $root 'install')
        Probe      = (Join-Path $root 'probe')
        FwTest     = (Join-Path $root 'fwtest')
        ConfigPath = (Join-Path $base 'config.json')
        StatePath  = (Join-Path $base 'state.json')
        LockDir    = (Join-Path $base 'locks')
        LogDir     = (Join-Path $base 'logs')
    }
}

# ---------------------------------------------------------------------------------------------
# Logging and prompts
# ---------------------------------------------------------------------------------------------

function Set-SandboxLogPath {
    param([string]$Path)
    $script:LogPath = $Path
}

function Write-SandboxMessage {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Info', 'Warn', 'Error', 'Step', 'Ok')][string]$Level = 'Info', [switch]$LogOnly)
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value ('{0:u} [{1}] {2}' -f [DateTime]::UtcNow, $Level, $Message) -Encoding utf8 } catch { }
    }
    if ($LogOnly) { return }
    $color = @{ Info = 'Gray'; Warn = 'Yellow'; Error = 'Red'; Step = 'Cyan'; Ok = 'Green' }[$Level]
    $prefix = @{ Info = ''; Warn = 'WARNING: '; Error = 'ERROR: '; Step = '== '; Ok = 'OK: ' }[$Level]
    Write-Host ($prefix + $Message) -ForegroundColor $color
}

function Write-SandboxResult {
    <#
    .SYNOPSIS
    Reports what a step really did: Changed, Unchanged or Skipped. Changes are kept for the summary at the end.
    Callers decide the status from a check, never from the fact that the step ran.
    #>
    param([Parameter(Mandatory)][ValidateSet('Changed', 'Unchanged', 'Skipped')][string]$Status, [Parameter(Mandatory)][string]$Message)
    $label = @{ Changed = 'changed'; Unchanged = 'unchanged'; Skipped = 'skipped' }[$Status]
    $color = @{ Changed = 'Green'; Unchanged = 'DarkGray'; Skipped = 'Yellow' }[$Status]
    Write-SandboxMessage -LogOnly -Message "$label`: $Message"
    Write-Host ('   {0,-10} {1}' -f $label, $Message) -ForegroundColor $color
    if ($Status -eq 'Changed') {
        if (-not $script:ChangedResults) { $script:ChangedResults = [Collections.Generic.List[string]]::new() }
        $script:ChangedResults.Add($Message)
    }
}

function Get-SandboxChangedResults {
    return @($script:ChangedResults)
}

function Get-SandboxAclChangeCount {
    # Successful icacls writes so far. All icacls calls change something, reading goes through Get-Acl.
    return [int]$script:AclChangeCount
}

function Test-SandboxInteractive {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Read-SandboxYesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    if (-not (Test-SandboxInteractive)) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Prompt [$hint]").Trim()
        if (-not $answer) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
    }
}

function Read-SandboxValue {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default)
    if (-not (Test-SandboxInteractive)) { return $Default }
    $text = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $answer = (Read-Host $text).Trim().Trim('"')
    if ($answer) { return $answer }
    return $Default
}

# ---------------------------------------------------------------------------------------------
# Pure path logic (no ACL or file system access, tested without admin rights)
# ---------------------------------------------------------------------------------------------

function Get-SandboxPathRejection {
    <#
    .SYNOPSIS
    Validates a user supplied path. Returns a hashtable with Ok, Reason and NeedsConfirmation.
    Info needs SystemRoot, ProgramFolders, ProgramData, ProfileRoot, OtherProfiles, ExecutorProfile,
    OwnFolders and Untouched.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Git', 'Claude', 'Allow')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$Info,
        [string]$GitPath,
        [string]$ClaudePath
    )
    $reject = { param($reason) return @{ Ok = $false; Reason = $reason; NeedsConfirmation = $false } }
    $trimmed = $Path.TrimEnd('\')

    if ($Path.StartsWith('\\')) { return (& $reject 'UNC paths cannot be secured with local ACLs.') }
    if ($trimmed.Length -le 2) { return (& $reject 'A volume root would release the whole volume.') }

    if (Test-SandboxPathWithin -Path $Path -Base $Info.SystemRoot) { return (& $reject 'The Windows folder and its content cannot be used.') }

    $exact = @($Info.ProgramFolders) + @($Info.ProgramData, $Info.ProfileRoot, $Info.ExecutorProfile) | Where-Object { $_ }
    foreach ($item in $exact) {
        if (Test-SandboxSamePath -Left $Path -Right $item) { return (& $reject "The system folder '$item' itself cannot be used.") }
        if (Test-SandboxPathWithin -Path $item -Base $Path) { return (& $reject "The path contains the system folder '$item'.") }
    }
    if (Test-SandboxPathWithin -Path $Info.SystemRoot -Base $Path) { return (& $reject 'The path contains the Windows folder.') }

    foreach ($other in @($Info.OtherProfiles)) {
        if (Test-SandboxPathWithin -Path $Path -Base $other) { return (& $reject "The path is inside the profile of another account ('$other').") }
        if (Test-SandboxPathWithin -Path $other -Base $Path) { return (& $reject "The path contains the profile of another account ('$other').") }
    }
    foreach ($own in @($Info.OwnFolders)) {
        if (Test-SandboxPathWithin -Path $Path -Base $own) { return (& $reject "The path is inside the sandbox folder '$own'.") }
        if (Test-SandboxPathWithin -Path $own -Base $Path) { return (& $reject "The path contains the sandbox folder '$own'.") }
    }

    if ($Kind -in 'Git', 'Claude') {
        foreach ($untouched in @($Info.Untouched)) {
            if (Test-SandboxPathWithin -Path $Path -Base $untouched) { return (& $reject "The path is inside '$untouched', which keeps its Windows permissions and would not be writable.") }
        }
    }
    if ($Kind -eq 'Allow') {
        foreach ($writable in @($GitPath, $ClaudePath) | Where-Object { $_ }) {
            if (Test-SandboxPathWithin -Path $Path -Base $writable) { return (& $reject "-AllowPath inside '$writable' is unnecessary and could be swapped for a junction.") }
        }
    }

    $confirm = $false
    if ($Info.ExecutorProfile -and (Test-SandboxPathWithin -Path $Path -Base $Info.ExecutorProfile)) {
        if ($Kind -ne 'Allow' -and (Test-SandboxPathWithin -Path $Path -Base (Join-Path $Info.ExecutorProfile 'AppData'))) {
            return (& $reject 'A writable folder below AppData would expose autostart and configuration folders.')
        }
        $confirm = $true
    }
    return @{ Ok = $true; Reason = $null; NeedsConfirmation = $confirm }
}

function Get-SandboxPathPlan {
    <#
    .SYNOPSIS
    Computes the three classes of the permission model. Grants are hashtables with Path, Rights and Kind.
    Returns Actions (Path, Rights, Kind, Action = None|Allow|ParentsOnly) and the Parents that need parent rules.
    #>
    param(
        [AllowEmptyCollection()][object[]]$Grants = @(),
        [AllowEmptyCollection()][string[]]$Untouched = @(),
        [Parameter(Mandatory)][string]$SystemDrive,
        [string]$OwnProfile,
        [string]$ProfileRoot,
        [AllowEmptyCollection()][string[]]$VolumeRoots = @()
    )
    $actions = [Collections.Generic.List[object]]::new()
    $parents = [Collections.Generic.List[string]]::new()
    $active = [Collections.Generic.List[string]]::new()

    foreach ($grant in $Grants) {
        $inUntouched = @($Untouched | Where-Object { Test-SandboxPathWithin -Path $grant.Path -Base $_ }).Count -gt 0
        $inOwnProfile = $OwnProfile -and $grant.Kind -ne 'OwnProfile' -and (Test-SandboxPathWithin -Path $grant.Path -Base $OwnProfile)
        $action = 'Allow'
        if ($inUntouched -or $inOwnProfile) { $action = 'None' }
        elseif ($grant.Kind -eq 'OwnProfile') { $action = 'ParentsOnly' }
        $actions.Add(@{ Path = $grant.Path; Rights = $grant.Rights; Kind = $grant.Kind; Action = $action })
        if ($action -ne 'None') { $active.Add($grant.Path) }
    }

    $sysRoot = $SystemDrive.TrimEnd('\')
    $profileRootOnSystem = $ProfileRoot -and (Test-SandboxPathWithin -Path $ProfileRoot -Base $sysRoot)
    foreach ($path in $active) {
        $current = Split-Path -Parent $path
        while ($current -and $current.TrimEnd('\').Length -gt 2) {
            if (@($VolumeRoots | Where-Object { Test-SandboxSamePath -Left $_ -Right $current }).Count -gt 0) { break }
            if (@($Untouched | Where-Object { Test-SandboxPathWithin -Path $current -Base $_ }).Count -gt 0) { break }
            if ($OwnProfile -and (Test-SandboxPathWithin -Path $current -Base $OwnProfile)) { break }
            if (@($active | Where-Object { Test-SandboxSamePath -Left $_ -Right $current }).Count -gt 0) { break }
            if ($profileRootOnSystem -and (Test-SandboxSamePath -Left $current -Right $ProfileRoot)) { break }
            if (@($parents | Where-Object { Test-SandboxSamePath -Left $_ -Right $current }).Count -eq 0) { $parents.Add($current) }
            $current = Split-Path -Parent $current
        }
    }
    return @{ Actions = @($actions); Parents = @($parents) }
}

function Get-SandboxGrantConflict {
    <#
    .SYNOPSIS
    Checks a new release against existing ones. Returns Reason (refused) and Absorb (releases that the new
    writable folder replaces). A release below a writable folder is refused or absorbed, never kept: the target
    user could swap a folder on its path for a junction, and later runs would set permissions through it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Read', 'Write')][string]$Access,
        [AllowEmptyCollection()][string[]]$AllowPaths = @(),
        [AllowEmptyCollection()][string[]]$WritePaths = @(),
        [string]$GitPath,
        [string]$ClaudePath
    )
    foreach ($base in @($GitPath, $ClaudePath) + @($WritePaths) | Where-Object { $_ }) {
        if (Test-SandboxSamePath -Left $Path -Right $base) { continue }
        if (Test-SandboxPathWithin -Path $Path -Base $base) { return @{ Reason = "'$Path' is inside '$base', which the target user can already write to."; Absorb = @() } }
    }
    if ($Access -eq 'Read') { return @{ Reason = $null; Absorb = @() } }
    foreach ($fixed in @($GitPath, $ClaudePath) | Where-Object { $_ }) {
        if (Test-SandboxPathWithin -Path $fixed -Base $Path) {
            return @{ Reason = "'$Path' contains '$fixed'. Read access works here, read and write would let the target user swap that folder. Use -Access Read or release the folders next to it."; Absorb = @() }
        }
    }
    $absorb = @(@($AllowPaths) + @($WritePaths) | Where-Object {
        $_ -and -not (Test-SandboxSamePath -Left $_ -Right $Path) -and (Test-SandboxPathWithin -Path $_ -Base $Path)
    })
    return @{ Reason = $null; Absorb = $absorb }
}

function Get-SandboxRemovalProblem {
    # A folder inside a release that stays keeps its access through inheritance, removing it would change nothing.
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$Removing = @(),
        [AllowEmptyCollection()][string[]]$AllowPaths = @(),
        [AllowEmptyCollection()][string[]]$WritePaths = @(),
        [string]$GitPath,
        [string]$ClaudePath
    )
    foreach ($base in @($GitPath, $ClaudePath) + @($AllowPaths) + @($WritePaths) | Where-Object { $_ }) {
        if (Test-SandboxSamePath -Left $base -Right $Path) { continue }
        if (-not (Test-SandboxPathWithin -Path $Path -Base $base)) { continue }
        if (@($Removing | Where-Object { Test-SandboxSamePath -Left $_ -Right $base }).Count -gt 0) { continue }
        return "'$Path' is inside the release '$base' and would stay accessible through it. Single subfolders of a release cannot be locked. Remove '$base' and release the folders you want next to it."
    }
    return $null
}

function ConvertTo-SandboxNormalizedBytes {
    # Git may store LF while a Windows clone has CRLF, and a BOM can differ as well. Neither is a real change.
    param([byte[]]$Bytes)
    $start = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $start = 3 }
    $stream = [IO.MemoryStream]::new($Bytes.Length)
    for ($i = $start; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 0x0D -and ($i + 1) -lt $Bytes.Length -and $Bytes[$i + 1] -eq 0x0A) { continue }
        $stream.WriteByte($Bytes[$i])
    }
    return ,$stream.ToArray()
}

function Get-SandboxContentHash {
    # File hashes are combined in a fixed order. $null content means the file is missing.
    param([Parameter(Mandatory)][hashtable]$Contents)
    $lines = foreach ($name in $script:SandboxFiles) {
        $content = $Contents[$name]
        if ($null -eq $content) { "$name missing"; continue }
        $normalized = ConvertTo-SandboxNormalizedBytes -Bytes $content
        "$name " + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$normalized))
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))
}

function Get-SandboxScriptHash {
    # Identifies the scripts in a folder. Every change to any of them changes this value.
    param([Parameter(Mandatory)][string]$ScriptRoot)
    $contents = @{}
    foreach ($name in $script:SandboxFiles) {
        $path = Join-Path $ScriptRoot $name
        if (Test-Path -LiteralPath $path) { $contents[$name] = [IO.File]::ReadAllBytes($path) }
    }
    return (Get-SandboxContentHash -Contents $contents)
}

function Get-SandboxCommitFromRefs {
    # Only a 40 digit hex value is taken from the answer, it ends up in a download address.
    # No word boundary in front: in this protocol a four digit length field comes directly before the hash.
    param([string]$Text)
    if (-not $Text) { return $null }
    $match = [regex]::Match($Text, '([0-9a-f]{40}) refs/heads/main(?=[\s\x00]|$)')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

function Get-SandboxRepositoryHash {
    <#
    .SYNOPSIS
    Hash of the scripts on the public main branch, or $null when the check is not possible.
    The downloads are only hashed, nothing from them is parsed or executed. A file that is gone there (404)
    counts as missing, which correctly gives a different hash.
    #>
    param([int]$TimeoutSeconds = 5, [string]$BaseUrl)
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try {
        if (-not $BaseUrl) {
            # The raw host caches a branch for minutes, which would report a false mismatch right after a merge.
            # A commit address is never stale. Without it the check is not reliable, so it is skipped.
            $refs = $client.GetStringAsync($script:RepositoryUrl + '/info/refs?service=git-upload-pack').GetAwaiter().GetResult()
            $commit = Get-SandboxCommitFromRefs -Text $refs
            if (-not $commit) { return $null }
            $BaseUrl = $script:RepositoryRawCommitBase -f $commit
        }
        $contents = @{}
        foreach ($name in $script:SandboxFiles) {
            $response = $client.GetAsync($BaseUrl + $name).GetAwaiter().GetResult()
            try {
                if ($response.StatusCode -eq [Net.HttpStatusCode]::NotFound) { continue }
                if (-not $response.IsSuccessStatusCode) { return $null }
                $contents[$name] = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            } finally { $response.Dispose() }
        }
        return (Get-SandboxContentHash -Contents $contents)
    } catch {
        return $null
    } finally { $client.Dispose() }
}

function Get-SandboxShortHash {
    param([string]$Hash)
    if (-not $Hash) { return 'unknown' }
    return $Hash.Substring(0, [Math]::Min(12, $Hash.Length)).ToLowerInvariant()
}

function Get-SandboxVersionAdvice {
    <#
    .SYNOPSIS
    Compares the running scripts with the public repository and with the installation.
    A hash cannot tell which side is newer. So the running scripts count as current only if they match the
    repository. In every other mismatch with the installation NeedsConfirmation is set: older scripts do not know
    settings of a newer installation, such as later releases, and could lose them.
    #>
    param([Parameter(Mandatory)][string]$Running, [string]$Repository, [string]$Installed)
    $messages = [Collections.Generic.List[string]]::new()
    $short = Get-SandboxShortHash -Hash $Running
    $outdated = $false
    $confirm = $false
    if ($Repository -and $Repository -ne $Running) {
        $outdated = $true
        $messages.Add("These scripts ($short) differ from the public repository ($(Get-SandboxShortHash -Hash $Repository)). They may be older or have local changes.")
    }
    if ($Installed -and $Installed -ne $Running) {
        if ($Repository -eq $Running) {
            $messages.Add("The installation ($(Get-SandboxShortHash -Hash $Installed)) differs from these scripts, which match the repository. An installation run brings everything up to date.")
        } else {
            $outdated = $true
            $confirm = $true
            $messages.Add("These scripts ($short) differ from the installation ($(Get-SandboxShortHash -Hash $Installed)). If they are older, they do not know its settings and could damage them.")
        }
    }
    return @{ Outdated = $outdated; NeedsConfirmation = $confirm; Messages = @($messages) }
}

function Get-SandboxUpdateInstructions {
    # Never starts git or downloads code itself: running fetched code as administrator is what this avoids.
    param([string]$ScriptRoot)
    $clone = '<your clone>'
    if ($ScriptRoot) {
        $candidate = Split-Path -Parent (Split-Path -Parent $ScriptRoot)
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate '.git') -ErrorAction SilentlyContinue)) { $clone = $candidate }
    }
    return @(
        'How to update:',
        "  1. In a normal terminal: git -C `"$clone`" pull",
        "     Without a clone: git clone $script:RepositoryUrl",
        '  2. Start Install-ClaudeSandbox.ps1 from that clone, not from %ProgramData%\ClaudeSandbox\install, as shown in the README.',
        '     Your settings and releases are kept. It offers to copy the new scripts to the install folder.'
    )
}

function Test-SandboxVersionAllowed {
    # Reports a mismatch and how to fix it. Returns $false if the user should not continue.
    param([string]$Installed, [Parameter(Mandatory)][string]$ScriptRoot)
    $advice = Get-SandboxVersionAdvice -Running (Get-SandboxScriptHash -ScriptRoot $ScriptRoot) -Repository (Get-SandboxRepositoryHash) -Installed $Installed
    foreach ($message in $advice.Messages) { Write-Host "WARNING: $message" -ForegroundColor Yellow }
    if ($advice.Outdated) {
        foreach ($line in Get-SandboxUpdateInstructions -ScriptRoot $ScriptRoot) { Write-Host $line -ForegroundColor Yellow }
    }
    if ($advice.NeedsConfirmation) { return (Read-SandboxYesNo -Prompt 'Continue with these scripts anyway?') }
    return $true
}

function New-SandboxPassword {
    # Upper case, lower case and digits only: no look-alikes, no layout dependent characters.
    $upper = 'ABCDEFGHJKLMNPQRSTUVWX'
    $lower = 'abcdefghijkmnpqrstuvwx'
    $digits = '23456789'
    $all = $upper + $lower + $digits
    $chars = [char[]]::new(32)
    for ($i = 0; $i -lt 32; $i++) { $chars[$i] = $all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)] }
    $positions = [Collections.Generic.List[int]]::new()
    while ($positions.Count -lt 3) {
        $candidate = [Security.Cryptography.RandomNumberGenerator]::GetInt32(32)
        if (-not $positions.Contains($candidate)) { $positions.Add($candidate) }
    }
    $chars[$positions[0]] = $upper[[Security.Cryptography.RandomNumberGenerator]::GetInt32($upper.Length)]
    $chars[$positions[1]] = $lower[[Security.Cryptography.RandomNumberGenerator]::GetInt32($lower.Length)]
    $chars[$positions[2]] = $digits[[Security.Cryptography.RandomNumberGenerator]::GetInt32($digits.Length)]
    $secure = [Security.SecureString]::new()
    foreach ($char in $chars) { $secure.AppendChar($char) }
    [Array]::Clear($chars, 0, $chars.Length)
    $secure.MakeReadOnly()
    return $secure
}

# ---------------------------------------------------------------------------------------------
# Native helpers
# ---------------------------------------------------------------------------------------------

function Initialize-SandboxNative {
    if ('ClaudeSandbox.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace ClaudeSandbox {
    public static class Native {
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LogonUser(string user, string domain, IntPtr password, int type, int provider, out IntPtr token);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern uint GetFinalPathNameByHandle(IntPtr handle, StringBuilder path, uint size, uint flags);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string system, string name, out long luid);
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct TokenPrivileges { public int Count; public long Luid; public int Attributes; }
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int length, IntPtr previous, IntPtr returned);

        public static int TestLogon(string user, System.Security.SecureString password) {
            IntPtr plain = Marshal.SecureStringToGlobalAllocUnicode(password);
            try {
                IntPtr token;
                if (!LogonUser(user, ".", plain, 2, 0, out token)) return Marshal.GetLastWin32Error();
                CloseHandle(token);
                return 0;
            } finally { Marshal.ZeroFreeGlobalAllocUnicode(plain); }
        }

        public static string GetFinalPath(string path) {
            IntPtr handle = CreateFile(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (handle == new IntPtr(-1)) return null;
            try {
                StringBuilder buffer = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0) return null;
                return buffer.ToString();
            } finally { CloseHandle(handle); }
        }

        public static bool EnablePrivilege(string name) {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return false;
            try {
                long luid;
                if (!LookupPrivilegeValue(null, name, out luid)) return false;
                TokenPrivileges state = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
                if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) return false;
                return Marshal.GetLastWin32Error() == 0;
            } finally { CloseHandle(token); }
        }
    }
}
'@
}

function Resolve-SandboxFinalPath {
    <#
    .SYNOPSIS
    Resolves junctions and symlinks. For a missing path, the deepest existing ancestor is resolved and
    the rest is appended. Returns $null if nothing on the path can be opened (for example a locked volume).
    #>
    param([Parameter(Mandatory)][string]$Path)
    Initialize-SandboxNative
    $full = [IO.Path]::GetFullPath($Path)
    $suffix = @()
    $current = $full
    while ($current) {
        $final = [ClaudeSandbox.Native]::GetFinalPath($current)
        if ($final) {
            $final = $final -replace '^\\\\\?\\UNC\\', '\\' -replace '^\\\\\?\\', ''
            foreach ($part in $suffix) { $final = Join-Path $final $part }
            if ($final.Length -gt 3) { $final = $final.TrimEnd('\') }
            return $final
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { return $null }
        $suffix = @(Split-Path -Leaf $current) + $suffix
        $current = $parent
    }
    return $null
}

function Test-SandboxLogon {
    param([Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][securestring]$Password)
    Initialize-SandboxNative
    return ([ClaudeSandbox.Native]::TestLogon($UserName, $Password) -eq 0)
}

function Enable-SandboxPrivileges {
    Initialize-SandboxNative
    foreach ($name in 'SeBackupPrivilege', 'SeRestorePrivilege', 'SeTakeOwnershipPrivilege') {
        if (-not [ClaudeSandbox.Native]::EnablePrivilege($name)) {
            Write-SandboxMessage -Level Warn -Message "Could not enable $name."
        }
    }
}

function Invoke-SandboxQuietProcess {
    <#
    .SYNOPSIS
    Runs a tool and returns only its exit code. Output is discarded because it may be localized.
    Activity shows a live seconds counter for calls that can block for a long time.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 0,
        [string]$Activity
    )
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(1000)) {
            if ($Activity -and -not $script:QuietProgress) {
                Write-Progress -Activity $Activity -Status ('Still running, {0:hh\:mm\:ss} elapsed' -f $clock.Elapsed)
            }
            if ($TimeoutSeconds -gt 0 -and $clock.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                $process.Kill()
                return -1
            }
        }
        $process.WaitForExit()
        if ($Activity -and -not $script:QuietProgress) { Write-Progress -Activity $Activity -Completed }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Get-SandboxSystemTool {
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path $env:SystemRoot "System32\$Name")
}

function Invoke-SandboxIcacls {
    # Every call carries /L and never /T: icacls /T walks through junctions.
    # Never /C either: with it icacls returns exit code 0 even when access is denied, so a failed lock looks fine.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Operation, [string]$Activity)
    $arguments = @($Path, '/L') + $Operation + @('/Q')
    $exitCode = Invoke-SandboxQuietProcess -FilePath (Get-SandboxSystemTool 'icacls.exe') -ArgumentList $arguments -Activity $Activity
    if ($exitCode -eq 0) { $script:AclChangeCount = [int]$script:AclChangeCount + 1 }
    return $exitCode
}

function Invoke-SandboxUserProcess {
    <#
    .SYNOPSIS
    Starts a process as the target user with its own profile and environment.
    The environment dictionary is left untouched on purpose, otherwise the caller's variables are inherited.
    #>
    param(
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 300,
        [switch]$CaptureOutput
    )
    if (-not $WorkingDirectory) { $WorkingDirectory = Join-Path $env:SystemRoot 'System32' }
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.LoadUserProfile = $true
    $info.UserName = ($Credential.UserName -split '\\')[-1]
    $info.Domain = $env:COMPUTERNAME
    $info.Password = $Credential.Password
    $info.WorkingDirectory = $WorkingDirectory
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($info)
    try {
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $process.BeginErrorReadLine()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            return @{ ExitCode = -1; Output = $null }
        }
        $process.WaitForExit()
        $output = $null
        if ($CaptureOutput) { $output = $outputTask.GetAwaiter().GetResult() }
        return @{ ExitCode = $process.ExitCode; Output = $output }
    } finally { $process.Dispose() }
}

function Invoke-SandboxProbe {
    <#
    .SYNOPSIS
    Runs Invoke-ClaudeSandboxProbe.ps1 as the target user. Tests go through a file because
    CreateProcessWithLogonW limits the command line to 1024 characters.
    #>
    param(
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][hashtable]$Layout,
        [AllowEmptyCollection()][object[]]$Tests = @(),
        [string]$ScriptRoot,
        [int]$TimeoutSeconds = 300
    )
    $id = [guid]::NewGuid().ToString('N')
    $testsPath = Join-Path $Layout.Probe "$id.json"
    Set-Content -LiteralPath $testsPath -Value (ConvertTo-Json -InputObject @($Tests) -Depth 5) -Encoding utf8
    try {
        $probeScript = Join-Path $Layout.Probe 'Invoke-ClaudeSandboxProbe.ps1'
        $result = Invoke-SandboxUserProcess -Credential $Credential -FilePath (Join-Path $PwshPath 'pwsh.exe') -CaptureOutput -TimeoutSeconds $TimeoutSeconds -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $probeScript, '-TestsPath', $testsPath
        )
        if ($result.ExitCode -ne 0 -or -not $result.Output) { throw "The probe process as the target user ended with exit code $($result.ExitCode)." }
        return ($result.Output | ConvertFrom-Json -AsHashtable)
    } finally {
        Remove-Item -LiteralPath $testsPath -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------
# State, configuration and locks
# ---------------------------------------------------------------------------------------------

function Read-SandboxJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
}

function Write-SandboxJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    Set-Content -LiteralPath $temp -Value (ConvertTo-Json -InputObject $Value -Depth 8) -Encoding utf8
    [IO.File]::Move($temp, $Path, $true)
}

function Enter-SandboxLock {
    <#
    .SYNOPSIS
    Takes an exclusive lock file. The open handle is what counts, it is released even after a crash.
    Lock order is always Mode, Volume, State. Returns $null when the timeout expires.
    #>
    param([Parameter(Mandatory)][hashtable]$Layout, [Parameter(Mandatory)][string]$Name, [int]$TimeoutSeconds = 0)
    $safe = ($Name -replace '[^A-Za-z0-9]', '_')
    $path = Join-Path $Layout.LockDir "$safe.lock"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $null }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Exit-SandboxLock {
    param([IO.FileStream]$Lock)
    if ($Lock) { $Lock.Dispose() }
}

function Update-SandboxState {
    # Read, change and write under the short state lock, so a late writer cannot overwrite a newer result.
    param([Parameter(Mandatory)][hashtable]$Layout, [Parameter(Mandatory)][scriptblock]$Change)
    $lock = Enter-SandboxLock -Layout $Layout -Name 'state' -TimeoutSeconds 60
    if (-not $lock) { throw 'Could not lock state.json within 60 seconds.' }
    try {
        $state = Read-SandboxJson -Path $Layout.StatePath
        if (-not $state) { $state = @{ Volumes = @{}; Messages = @(); Heartbeat = @{}; Running = @{} } }
        foreach ($key in 'Volumes', 'Heartbeat', 'Running') { if (-not $state.ContainsKey($key)) { $state[$key] = @{} } }
        if (-not $state.ContainsKey('Messages')) { $state['Messages'] = @() }
        & $Change $state
        Write-SandboxJson -Path $Layout.StatePath -Value $state
    } finally { Exit-SandboxLock -Lock $lock }
}

function Set-SandboxHeartbeat {
    param([Parameter(Mandatory)][hashtable]$Layout, [Parameter(Mandatory)][string]$Mode, [bool]$Running = $true)
    Update-SandboxState -Layout $Layout -Change {
        param($state)
        $state.Heartbeat[$Mode] = [DateTime]::UtcNow.ToString('o')
        $state.Running[$Mode] = $Running
    }
}

function Add-SandboxStateMessage {
    param([Parameter(Mandatory)][hashtable]$Layout, [Parameter(Mandatory)][string]$Message)
    Update-SandboxState -Layout $Layout -Change {
        param($state)
        if (@($state.Messages) -notcontains $Message) { $state['Messages'] = @($state.Messages) + $Message }
    }
}

function New-SandboxProtectedFolder {
    <#
    .SYNOPSIS
    Creates a folder with its final ACL in one step, so it never inherits write access for Users.
    #>
    param([Parameter(Mandatory)][string]$Path, [bool]$UsersCanRead = $true)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner([Security.Principal.SecurityIdentifier]$script:AdministratorsSid)
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($sid in $script:AdministratorsSid, $script:SystemSid) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid, 'FullControl', $inherit, 'None', 'Allow'))
    }
    if ($UsersCanRead) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$script:UsersSid, 'ReadAndExecute', $inherit, 'None', 'Allow'))
    }
    if (Test-Path -LiteralPath $Path) { return }
    $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $Path)
}

function Get-SandboxFolderProblems {
    # A pre-existing %ProgramData%\ClaudeSandbox is only accepted if no non-admin could have prepared it.
    param([Parameter(Mandatory)][string]$Path, [string[]]$WriterSids, [string]$ExecutorSid)
    $problems = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    # Files written from an elevated process can be owned by the executing admin account itself.
    $trusted = @($script:AdministratorsSid, $script:SystemSid, 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', $ExecutorSid)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @([IO.DirectoryInfo]::new($current).EnumerateFileSystemInfos()) + @(Get-Item -LiteralPath $current -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $problems.Add("Reparse point: $($item.FullName)"); continue }
            $acl = Get-Acl -LiteralPath $item.FullName
            $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($trusted -notcontains $owner) { $problems.Add("Owner is not an administrator: $($item.FullName)") }
            if (Test-SandboxSidsCanWrite -Path $item.FullName -Sids $WriterSids) { $problems.Add("Writable by non-admins: $($item.FullName)") }
            if ($item -is [IO.DirectoryInfo] -and $item.FullName -ne $current) { $pending.Push($item.FullName) }
        }
    }
    return @($problems | Select-Object -Unique)
}

# ---------------------------------------------------------------------------------------------
# ACL and system functions (pwsh 7 only)
# ---------------------------------------------------------------------------------------------

function Test-SandboxSidsCanWrite {
    <#
    .SYNOPSIS
    SID based, never translates names: Translate throws on AppContainer entries.
    An unreadable ACL throws as well, it must never count as safe.
    -Ancestor only counts rights that allow replacing the child (delete child, DACL, owner, generic).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Sids, [switch]$Ancestor)
    $bits = 0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
    if ($Ancestor) { $bits = 0x40 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000 }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($Sids -contains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $true }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($Sids -notcontains $rule.IdentityReference.Value) { continue }
        if (([int]$rule.FileSystemRights) -band $bits) { return $true }
    }
    return $false
}

function Test-SandboxLocationWritable {
    # True if one of the SIDs can change the folder or swap it through an ancestor.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Sids)
    if (Test-SandboxSidsCanWrite -Path $Path -Sids $Sids) { return $true }
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Force) {
        if (Test-SandboxSidsCanWrite -Path $file.FullName -Sids $Sids) { return $true }
    }
    $current = Split-Path -Parent $Path
    while ($current) {
        if (Test-SandboxSidsCanWrite -Path $current -Sids $Sids -Ancestor) { return $true }
        $next = Split-Path -Parent $current
        if ($next -eq $current) { break }
        $current = $next
    }
    return $false
}

function Get-SandboxTargetSids {
    # Fixed writers plus SID and groups of an existing target user, available before the first logon.
    param([string]$UserName)
    $sids = [Collections.Generic.List[string]]::new()
    foreach ($sid in $script:FixedWriterSids) { $sids.Add($sid) }
    if (-not $UserName) { return @($sids) }
    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if (-not $user) { return @($sids) }
    $sids.Add($user.SID.Value)
    foreach ($group in Get-SandboxUserGroups -UserSid $user.SID.Value) { $sids.Add($group.SID) }
    return @($sids | Select-Object -Unique)
}

function Get-SandboxUserGroups {
    # Get-LocalGroupMember fails on orphaned SIDs, the ADSI fallback still reads such a group.
    param([Parameter(Mandatory)][string]$UserSid)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($group in Get-LocalGroup) {
        $isMember = $false
        try {
            $isMember = @(Get-LocalGroupMember -SID $group.SID.Value -ErrorAction Stop | Where-Object { $_.SID.Value -eq $UserSid }).Count -gt 0
        } catch {
            try {
                $adsi = [ADSI]"WinNT://./$($group.Name),group"
                foreach ($member in @($adsi.Invoke('Members'))) {
                    $bytes = $member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null)
                    if ([Security.Principal.SecurityIdentifier]::new([byte[]]$bytes, 0).Value -eq $UserSid) { $isMember = $true; break }
                }
            } catch {
                throw "Membership of group $($group.SID.Value) could not be read."
            }
        }
        if ($isMember) { $result.Add(@{ SID = $group.SID.Value; Name = $group.Name }) }
    }
    return @($result)
}

function Get-SandboxSystemInfo {
    <#
    .SYNOPSIS
    Determines all Windows folders at run time. ExecutorSid and TargetSid come from config.json in tasks,
    because SYSTEM has neither profile nor the caller's environment.
    #>
    param([string]$ExecutorProfile, [string]$TargetProfile)
    $systemDrive = $env:SystemDrive
    $programFolders = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, ${env:ProgramFiles(Arm)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique
    $listKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $list = Get-ItemProperty -LiteralPath $listKey
    $profileRoot = [Environment]::ExpandEnvironmentVariables($list.ProfilesDirectory)
    $publicProfile = if ($list.Public) { [Environment]::ExpandEnvironmentVariables($list.Public) } else { Join-Path $profileRoot 'Public' }
    $defaultProfile = if ($list.Default) { [Environment]::ExpandEnvironmentVariables($list.Default) } else { Join-Path $profileRoot 'Default' }

    $userProfiles = [Collections.Generic.List[string]]::new()
    foreach ($entry in Get-ChildItem -LiteralPath $listKey) {
        # S-1-5-18, -19 and -20 point into the Windows folder and must never get a deny.
        if ($entry.PSChildName -notmatch '^S-1-(5-21|12-1)-') { continue }
        $image = (Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($image) { $userProfiles.Add([Environment]::ExpandEnvironmentVariables($image).TrimEnd('\')) }
    }
    $others = @($userProfiles | Where-Object {
        -not (Test-SandboxSamePath -Left $_ -Right $TargetProfile) -and -not (Test-SandboxSamePath -Left $_ -Right $ExecutorProfile)
    })
    $windowsFolders = @($env:SystemRoot) + @($programFolders) + @($env:ProgramData)
    $untouched = @($windowsFolders | Where-Object { Test-SandboxPathWithin -Path $_ -Base $systemDrive } | Select-Object -Unique)
    return @{
        SystemDrive     = $systemDrive
        SystemRoot      = $env:SystemRoot
        ProgramFolders  = @($programFolders)
        ProgramData     = $env:ProgramData
        ProfileRoot     = $profileRoot
        PublicProfile   = $publicProfile
        DefaultProfile  = $defaultProfile
        UserProfiles    = @($userProfiles)
        OtherProfiles   = @($others)
        ExecutorProfile = $ExecutorProfile
        TargetProfile   = $TargetProfile
        WindowsFolders  = @($windowsFolders | Select-Object -Unique)
        Untouched       = $untouched
        OwnFolders      = @((Join-Path $env:ProgramData 'ClaudeSandbox')) + @($(if ($ExecutorProfile) { Join-Path $ExecutorProfile 'AppData\Local\ClaudeSandbox' }))
    }
}

function Get-SandboxVolumes {
    <#
    .SYNOPSIS
    Win32_Volume reconciled with Win32_LogicalDisk. Volumes without mount point (EFI, recovery) are skipped,
    a drive letter without volume entry counts as Locked and gets its own key.
    #>
    $systemRoot = ($env:SystemDrive.TrimEnd('\') + '\')
    $result = [Collections.Generic.List[object]]::new()
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($volume in Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 3') {
        if ($volume.Name -eq $volume.DeviceID) { continue }
        $null = $known.Add($volume.Name)
        $fileSystem = [string]$volume.FileSystem
        $status = 'Available'
        if (-not $fileSystem -or -not $volume.Capacity) { $status = 'Locked' }
        elseif ($fileSystem -notin 'NTFS', 'ReFS') { $status = 'NoAcls' }
        $result.Add(@{ Key = $volume.DeviceID; MountPath = $volume.Name; FileSystem = $fileSystem; Status = $status; IsSystem = ($volume.Name -eq $systemRoot) })
    }
    foreach ($disk in Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3') {
        $mount = $disk.DeviceID + '\'
        if ($known.Contains($mount)) { continue }
        $result.Add(@{ Key = "letter:$($disk.DeviceID)"; MountPath = $mount; FileSystem = ''; Status = 'Locked'; IsSystem = $false })
    }
    return @($result)
}

function Resolve-SandboxVolumeSelection {
    # Translates -Volumes (mount paths or letters) into stable keys. No selection means all volumes.
    param([AllowEmptyCollection()][string[]]$Requested = @(), [Parameter(Mandatory)][object[]]$Volumes)
    if ($Requested.Count -eq 0) { return $null }
    $keys = foreach ($item in $Requested) {
        $wanted = $item.TrimEnd('\') + '\'
        $match = $Volumes | Where-Object { Test-SandboxSamePath -Left $_.MountPath -Right $wanted -or $_.Key -eq $item } | Select-Object -First 1
        if (-not $match) { throw "Volume '$item' was not found." }
        $match.Key
    }
    return @($keys)
}

function Get-SandboxVolumeOfPath {
    # Longest mount path wins, so a volume mounted into a folder is found correctly.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Volumes)
    return ($Volumes | Where-Object { Test-SandboxPathWithin -Path $Path -Base $_.MountPath } |
        Sort-Object { $_.MountPath.Length } -Descending | Select-Object -First 1)
}

function Get-SandboxToolchains {
    # File system and registry only, safe to run as SYSTEM: nothing is started.
    $found = [Collections.Generic.List[string]]::new()
    $dotnet = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\dotnet\Setup\InstalledVersions\x64' -ErrorAction SilentlyContinue
    if ($dotnet -and $dotnet.InstallLocation) { $found.Add($dotnet.InstallLocation.TrimEnd('\')) }
    $git = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\GitForWindows' -ErrorAction SilentlyContinue
    if ($git -and $git.InstallPath) { $found.Add($git.InstallPath.TrimEnd('\')) }
    $pwsh = Get-SandboxMachinePwsh
    if ($pwsh) { $found.Add($pwsh) }
    foreach ($installation in Get-SandboxVisualStudioPaths) { $found.Add($installation) }
    return @($found | Select-Object -Unique)
}

function Get-SandboxVisualStudioPaths {
    $instances = Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances'
    if (-not (Test-Path -LiteralPath $instances)) { return @() }
    $paths = foreach ($file in Get-ChildItem -LiteralPath $instances -Filter 'state.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue) {
        # A writable source could inject paths, it is ignored instead of trusted.
        if (Test-SandboxSidsCanWrite -Path $file.FullName -Sids $script:FixedWriterSids) { continue }
        try { (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).installationPath } catch { }
    }
    return @($paths | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
}

function Get-SandboxModel {
    # Turns config.json into the grants, parent paths and exemptions of the permission model.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][object[]]$Volumes)
    $info = Get-SandboxSystemInfo -ExecutorProfile $Config.ExecutorProfile -TargetProfile $Config.TargetProfile
    $grants = [Collections.Generic.List[object]]::new()
    foreach ($path in @($info.WindowsFolders)) {
        if (-not $Config.Test -and -not (Test-SandboxPathWithin -Path $path -Base $info.SystemDrive)) {
            $grants.Add(@{ Path = $path; Rights = 'RX'; Kind = 'Windows' })
        }
    }
    if ($Config.TargetProfile -and -not (Test-SandboxPathWithin -Path $Config.TargetProfile -Base $info.SystemDrive)) {
        $grants.Add(@{ Path = $Config.TargetProfile; Rights = ''; Kind = 'OwnProfile' })
    }
    if ($Config.ClaudePath) { $grants.Add(@{ Path = $Config.ClaudePath; Rights = 'F'; Kind = 'Claude' }) }
    if ($Config.GitPath) { $grants.Add(@{ Path = $Config.GitPath; Rights = 'M'; Kind = 'Git' }) }
    foreach ($path in @($Config.WritePaths) | Where-Object { $_ }) { $grants.Add(@{ Path = $path; Rights = 'M'; Kind = 'Write' }) }
    foreach ($path in @($Config.AllowPaths) + @($Config.Toolchains) | Where-Object { $_ } | Select-Object -Unique) {
        $grants.Add(@{ Path = $path; Rights = 'RX'; Kind = 'Allow' })
    }
    $roots = @($Volumes | ForEach-Object { $_.MountPath })
    $plan = Get-SandboxPathPlan -Grants @($grants) -Untouched $info.Untouched -SystemDrive $info.SystemDrive -OwnProfile $Config.TargetProfile -ProfileRoot $info.ProfileRoot -VolumeRoots $roots

    $exempt = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($action in $plan.Actions) { if ($action.Action -ne 'None') { $null = $exempt.Add($action.Path.TrimEnd('\')) } }
    if ($Config.TargetProfile) { $null = $exempt.Add($Config.TargetProfile.TrimEnd('\')) }
    $parents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($parent in $plan.Parents) { $null = $parents.Add($parent.TrimEnd('\')) }
    return @{ Info = $info; Actions = $plan.Actions; Parents = $parents; Exempt = $exempt }
}

function Get-SandboxRuleState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $Sid })
    return @{
        Rules          = $rules
        ExplicitDeny   = @($rules | Where-Object { $_.AccessControlType -eq 'Deny' })
        ExplicitAllow  = @($rules | Where-Object { $_.AccessControlType -eq 'Allow' })
    }
}

function Test-SandboxInheritOnlyDeny {
    # Deny FullControl for children only: (OI)(CI)(IO)(F).
    param([object[]]$DenyRules)
    foreach ($rule in $DenyRules) {
        $inheritOnly = $rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly
        $full = (([int]$rule.FileSystemRights) -band 0x1F01FF) -eq 0x1F01FF
        $both = ($rule.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit) -and ($rule.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ObjectInherit)
        if ($inheritOnly -and $full -and $both) { return $true }
    }
    return $false
}

function Set-SandboxContainerRules {
    <#
    .SYNOPSIS
    Applies the rules for a volume root or a parent path: inheritable deny first, list-denying ACE last,
    otherwise the account loses the right to enumerate children while the deny propagates.
    Returns $true if all icacls calls succeeded.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid, [string]$Activity)
    $state = Get-SandboxRuleState -Path $Path -Sid $Sid
    $hasInheritDeny = Test-SandboxInheritOnlyDeny -DenyRules $state.ExplicitDeny
    $hasSelfAllow = @($state.ExplicitAllow | Where-Object { ([int]$_.FileSystemRights -band 0x80) -and $_.InheritanceFlags -eq 'None' }).Count -gt 0
    $hasSelfDeny = @($state.ExplicitDeny | Where-Object { ([int]$_.FileSystemRights -band 0x1) -and ([int]$_.FileSystemRights -band 0x80) -eq 0 -and $_.InheritanceFlags -eq 'None' }).Count -gt 0
    $fullSelfDeny = @($state.ExplicitDeny | Where-Object { ([int]$_.FileSystemRights -band 0x80) -and -not ($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) }).Count -gt 0
    if ($hasInheritDeny -and $hasSelfAllow -and $hasSelfDeny -and -not $fullSelfDeny) { return $true }

    $ok = $true
    if ($state.ExplicitDeny.Count -gt 0) { $ok = (Invoke-SandboxIcacls -Path $Path -Operation @('/remove:d', "*$Sid") -Activity $Activity) -eq 0 -and $ok }
    if ($state.ExplicitAllow.Count -gt 0) { $ok = (Invoke-SandboxIcacls -Path $Path -Operation @('/remove:g', "*$Sid") -Activity $Activity) -eq 0 -and $ok }
    $ok = (Invoke-SandboxIcacls -Path $Path -Operation @('/deny', "*${Sid}:(OI)(CI)(IO)(F)") -Activity $Activity) -eq 0 -and $ok
    $ok = (Invoke-SandboxIcacls -Path $Path -Operation @('/grant', "*${Sid}:(RA,X,S)") -Activity $Activity) -eq 0 -and $ok
    $ok = (Invoke-SandboxIcacls -Path $Path -Operation @('/deny', "*${Sid}:$script:SparedDeny") -Activity $Activity) -eq 0 -and $ok
    return $ok
}

function Test-SandboxContainerRules {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid)
    $state = Get-SandboxRuleState -Path $Path -Sid $Sid
    return (Test-SandboxInheritOnlyDeny -DenyRules $state.ExplicitDeny)
}

function Set-SandboxSystemRootRule {
    # The system drive root stays listable, only creating files and folders is denied.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid)
    if (Test-SandboxSystemRootRule -Path $Path -Sid $Sid) { return $true }
    return ((Invoke-SandboxIcacls -Path $Path -Operation @('/deny', "*${Sid}:(WD,AD)")) -eq 0)
}

function Test-SandboxSystemRootRule {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid)
    $state = Get-SandboxRuleState -Path $Path -Sid $Sid
    return (@($state.ExplicitDeny | Where-Object { ([int]$_.FileSystemRights -band 0x6) -eq 0x6 }).Count -gt 0)
}

function Set-SandboxGrant {
    # Sets the allow only if it is missing: re-applying would propagate again for no reason.
    param([Parameter(Mandatory)][hashtable]$Action, [Parameter(Mandatory)][string]$Sid)
    if ($Action.Action -ne 'Allow' -or -not (Test-Path -LiteralPath $Action.Path)) { return $true }
    $state = Get-SandboxRuleState -Path $Action.Path -Sid $Sid
    $bits = @{ F = 0x1F01FF; M = 0x1301BF; RX = 0x1200A9 }[$Action.Rights]
    $present = @($state.ExplicitAllow | Where-Object {
        ((([int]$_.FileSystemRights) -band $bits) -eq $bits) -and
        ($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit) -and
        ($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ObjectInherit)
    }).Count -gt 0
    $ok = $true
    if ($state.ExplicitDeny.Count -gt 0) { $ok = (Invoke-SandboxIcacls -Path $Action.Path -Operation @('/remove:d', "*$Sid")) -eq 0 }
    if ($present) { return $ok }
    return ((Invoke-SandboxIcacls -Path $Action.Path -Operation @('/grant', "*${Sid}:(OI)(CI)($($Action.Rights))") -Activity "Granting access on $($Action.Path)") -eq 0) -and $ok
}

function Set-SandboxGrantsForVolume {
    # Grants and parent rules before Phase 1, otherwise a release on the volume would stay locked.
    param([Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][hashtable]$Volume, [Parameter(Mandatory)][object[]]$Volumes, [Parameter(Mandatory)][string]$Sid)
    $ok = $true
    foreach ($action in $Model.Actions) {
        if ($action.Action -eq 'None') { continue }
        $owner = Get-SandboxVolumeOfPath -Path $action.Path -Volumes $Volumes
        if (-not $owner -or $owner.Key -ne $Volume.Key) { continue }
        if (-not (Set-SandboxGrant -Action $action -Sid $Sid)) { $ok = $false }
    }
    foreach ($parent in $Model.Parents) {
        $owner = Get-SandboxVolumeOfPath -Path $parent -Volumes $Volumes
        if (-not $owner -or $owner.Key -ne $Volume.Key -or -not (Test-Path -LiteralPath $parent)) { continue }
        if (-not (Set-SandboxContainerRules -Path $parent -Sid $Sid -Activity "Setting parent rules on $parent")) { $ok = $false }
    }
    return $ok
}

function Get-SandboxSystemDriveTargets {
    <#
    .SYNOPSIS
    Everything on the system drive that gets a full deny: non-Windows top level items, foreign and
    orphaned profiles. Reparse points are skipped, a deny on a junction would be useless.
    #>
    param([Parameter(Mandatory)][hashtable]$Model)
    $info = $Model.Info
    $root = $info.SystemDrive.TrimEnd('\') + '\'
    $targets = [Collections.Generic.List[object]]::new()
    $keepNames = [Collections.Generic.HashSet[string]]::new([string[]]$script:WindowsOwnNames, [StringComparer]::OrdinalIgnoreCase)
    $keepFiles = [Collections.Generic.HashSet[string]]::new([string[]]$script:WindowsOwnFiles, [StringComparer]::OrdinalIgnoreCase)
    foreach ($item in [IO.DirectoryInfo]::new($root).EnumerateFileSystemInfos()) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $full = $item.FullName.TrimEnd('\')
        if ($item -is [IO.FileInfo]) {
            if (-not $keepFiles.Contains($item.Name)) { $targets.Add(@{ Path = $full; IsDirectory = $false }) }
            continue
        }
        if ($keepNames.Contains($item.Name)) { continue }
        if (@($info.Untouched | Where-Object { Test-SandboxSamePath -Left $_ -Right $full }).Count -gt 0) { continue }
        if (Test-SandboxSamePath -Left $full -Right $info.ProfileRoot) { continue }
        if ($Model.Exempt.Contains($full) -or $Model.Parents.Contains($full)) { continue }
        $targets.Add(@{ Path = $full; IsDirectory = $true })
    }
    if (Test-SandboxPathWithin -Path $info.ProfileRoot -Base $root) {
        foreach ($item in [IO.DirectoryInfo]::new($info.ProfileRoot).EnumerateDirectories()) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $full = $item.FullName.TrimEnd('\')
            if (Test-SandboxSamePath -Left $full -Right $info.TargetProfile) { continue }
            if (Test-SandboxSamePath -Left $full -Right $info.PublicProfile) { continue }
            if (Test-SandboxSamePath -Left $full -Right $info.DefaultProfile) { continue }
            if ($Model.Exempt.Contains($full) -or $Model.Parents.Contains($full)) { continue }
            $targets.Add(@{ Path = $full; IsDirectory = $true })
        }
    }
    return @($targets)
}

function Set-SandboxDeny {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$IsDirectory, [Parameter(Mandatory)][string]$Sid, [string]$Activity)
    $right = if ($IsDirectory) { "*${Sid}:(OI)(CI)(F)" } else { "*${Sid}:(F)" }
    return ((Invoke-SandboxIcacls -Path $Path -Operation @('/deny', $right) -Activity $Activity) -eq 0)
}

function Test-SandboxHasDeny {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid)
    $state = Get-SandboxRuleState -Path $Path -Sid $Sid
    return (@($state.ExplicitDeny | Where-Object { ([int]$_.FileSystemRights -band 0x1) -and -not ($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) }).Count -gt 0)
}

function Invoke-SandboxScanItem {
    # Phase 2 for one object. Returns $true when the object needs no further handling.
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item, [Parameter(Mandatory)][hashtable]$Scan)
    $sections = [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner
    try {
        if ($Item -is [IO.DirectoryInfo]) { $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]$Item, $sections) }
        else { $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]$Item, $sections) }
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return
    } catch {
        $Scan.Unreadable++
        Add-Content -LiteralPath $Scan.UnreadableLog -Value $Item.FullName -Encoding utf8 -ErrorAction SilentlyContinue
        return
    }
    $sid = $Scan.Sid
    $path = $Item.FullName
    $writeOk = $true

    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $sid) {
        $writeOk = (Invoke-SandboxIcacls -Path $path -Operation @('/setowner', "*$script:AdministratorsSid")) -eq 0
        Add-Content -LiteralPath $Scan.OwnerLog -Value $path -Encoding utf8 -ErrorAction SilentlyContinue
    }

    $ownAllow = $false; $tokenAllow = $false; $hasDeny = $false; $explicitDeny = $false
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $ruleSid = $rule.IdentityReference.Value
        $inheritOnly = $rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly
        if ($rule.AccessControlType -eq 'Deny') {
            if ($ruleSid -eq $sid -and -not $inheritOnly -and (([int]$rule.FileSystemRights) -band 0x1)) {
                $hasDeny = $true
                if (-not $rule.IsInherited) { $explicitDeny = $true }
            }
            continue
        }
        if ($rule.IsInherited) { continue }
        if ($ruleSid -eq $sid) { $ownAllow = $true }
        if (-not $inheritOnly -and $Scan.TokenSids -contains $ruleSid) { $tokenAllow = $true }
    }
    if ($ownAllow) {
        $writeOk = ((Invoke-SandboxIcacls -Path $path -Operation @('/remove:g', "*$sid")) -eq 0) -and $writeOk
    }
    if (-not $explicitDeny -and ($acl.AreAccessRulesProtected -or $tokenAllow -or -not $hasDeny)) {
        $writeOk = (Set-SandboxDeny -Path $path -IsDirectory ($Item -is [IO.DirectoryInfo]) -Sid $sid) -and $writeOk
        $Scan.Denied++
    }
    if (-not $writeOk -and $Item.Exists) {
        $Item.Refresh()
        if ($Item.Exists) { $Scan.WriteErrors++ }
    }
}

function Invoke-SandboxTreeScan {
    <#
    .SYNOPSIS
    Phase 2. Walks directories and files with an explicit stack, never follows reparse points.
    Exempt paths are skipped entirely, parent paths are only descended.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string[]]$TokenSids,
        [Parameter(Mandatory)][hashtable]$Model,
        [Parameter(Mandatory)][string]$LogPrefix,
        [switch]$SkipVolumeSystemFolders,
        [scriptblock]$Heartbeat,
        [string]$Label = 'Scanning'
    )
    Enable-SandboxPrivileges
    $scan = @{
        Sid = $Sid; TokenSids = $TokenSids; Unreadable = 0; WriteErrors = 0; Denied = 0; Objects = 0
        UnreadableLog = "$LogPrefix.unreadable.log"; OwnerLog = "$LogPrefix.owner.log"
    }
    $options = [IO.EnumerationOptions]::new()
    $options.AttributesToSkip = [IO.FileAttributes]0
    $options.IgnoreInaccessible = $false
    $options.RecurseSubdirectories = $false
    $options.ReturnSpecialDirectories = $false
    $skip = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($SkipVolumeSystemFolders) {
        foreach ($root in $Roots) {
            $null = $skip.Add((Join-Path $root 'System Volume Information'))
            $null = $skip.Add((Join-Path $root '$RECYCLE.BIN'))
        }
    }
    $stack = [Collections.Generic.Stack[string]]::new()
    foreach ($root in $Roots) { $stack.Push($root) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastShown = 0
    $lastBeat = 0
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            foreach ($item in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos('*', $options)) {
                $scan.Objects++
                $full = $item.FullName.TrimEnd('\')
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($skip.Contains($full) -or $Model.Exempt.Contains($full)) { continue }
                $isParent = $Model.Parents.Contains($full)
                if (-not $isParent) { Invoke-SandboxScanItem -Item $item -Scan $scan }
                if ($item -is [IO.DirectoryInfo]) { $stack.Push($full) }

                $seconds = [int]$clock.Elapsed.TotalSeconds
                if ($seconds -ge $lastShown + 2) {
                    $lastShown = $seconds
                    if (-not $script:QuietProgress) {
                        Write-Progress -Activity $Label -Status ('{0:N0} objects checked, {1:hh\:mm\:ss} elapsed' -f $scan.Objects, $clock.Elapsed) -CurrentOperation $full
                    }
                }
                if ($Heartbeat -and $seconds -ge $lastBeat + 60) { $lastBeat = $seconds; & $Heartbeat }
            }
        } catch [IO.DirectoryNotFoundException] {
            # The folder vanished during the scan, that is not an error.
        } catch [IO.FileNotFoundException] {
        } catch {
            $scan.Unreadable++
            Add-Content -LiteralPath $scan.UnreadableLog -Value $directory -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }
    if (-not $script:QuietProgress) { Write-Progress -Activity $Label -Completed }
    return $scan
}

function Remove-SandboxSidAces {
    # Removes explicit entries of the SID in a tree without following reparse points.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid, [switch]$DenyOnly, [Collections.Generic.HashSet[string]]$Skip)
    $operation = if ($DenyOnly) { '/remove:d' } else { '/remove' }
    $options = [IO.EnumerationOptions]::new()
    $options.AttributesToSkip = [IO.FileAttributes]0
    $options.IgnoreInaccessible = $true
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $count = 0
    $lastShown = 0
    $clean = {
        param($target)
        $rules = @((Get-Acl -LiteralPath $target).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $Sid })
        if ($DenyOnly) { $rules = @($rules | Where-Object { $_.AccessControlType -eq 'Deny' }) }
        if ($rules.Count -gt 0) { $null = Invoke-SandboxIcacls -Path $target -Operation @($operation, "*$Sid") }
    }
    try { & $clean $Path } catch { }
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            foreach ($item in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos('*', $options)) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $full = $item.FullName.TrimEnd('\')
                if ($Skip -and $Skip.Contains($full)) { continue }
                $count++
                try { & $clean $full } catch { }
                if ($item -is [IO.DirectoryInfo]) { $stack.Push($full) }
                $seconds = [int]$clock.Elapsed.TotalSeconds
                if ($seconds -ge $lastShown + 2 -and -not $script:QuietProgress) {
                    $lastShown = $seconds
                    Write-Progress -Activity "Cleaning entries below $Path" -Status ('{0:N0} objects checked' -f $count) -CurrentOperation $full
                }
            }
        } catch { }
    }
    if (-not $script:QuietProgress) { Write-Progress -Activity "Cleaning entries below $Path" -Completed }
}

function Set-SandboxVolumeProtection {
    <#
    .SYNOPSIS
    Grants plus Phase 1 for one volume. Returns the deny targets on the system drive (for Phase 2).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Model,
        [Parameter(Mandatory)][hashtable]$Volume,
        [Parameter(Mandatory)][object[]]$Volumes,
        [Parameter(Mandatory)][hashtable]$Layout
    )
    $sid = $Config.TargetSid
    $root = $Volume.MountPath
    $ok = $true
    try {
        $backup = Join-Path $Layout.LogDir ("acl-backup-{0:yyyyMMdd-HHmmss}.txt" -f [DateTime]::UtcNow)
        Add-Content -LiteralPath $backup -Value "$root`t$((Get-Acl -LiteralPath $root).Sddl)" -Encoding utf8
    } catch { Write-SandboxMessage -Level Warn -Message "The ACL of $root could not be saved." }

    if (-not (Set-SandboxGrantsForVolume -Model $Model -Volume $Volume -Volumes $Volumes -Sid $sid)) { $ok = $false }
    $targets = @()
    if ($Volume.IsSystem) {
        if (-not (Set-SandboxSystemRootRule -Path $root -Sid $sid)) { $ok = $false }
        $targets = @(Get-SandboxSystemDriveTargets -Model $Model)
        $index = 0
        foreach ($target in $targets) {
            $index++
            if (Test-SandboxHasDeny -Path $target.Path -Sid $sid) { continue }
            if (-not (Set-SandboxDeny -Path $target.Path -IsDirectory $target.IsDirectory -Sid $sid -Activity "Locking $($target.Path) ($index of $($targets.Count))")) { $ok = $false }
        }
    } else {
        if (-not (Set-SandboxContainerRules -Path $root -Sid $sid -Activity "Setting the deny on $root and propagating it, this can take a long time")) { $ok = $false }
    }
    return @{ Ok = $ok; Targets = $targets }
}

function Invoke-SandboxVolumeScan {
    # Phase 2 for one volume and the matching status. Dropped objects never count as errors.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Model,
        [Parameter(Mandatory)][hashtable]$Volume,
        [Parameter(Mandatory)][hashtable]$Layout,
        [object[]]$Targets = @(),
        [scriptblock]$Heartbeat
    )
    $prefix = Join-Path $Layout.LogDir ('scan-' + ($Volume.Key -replace '[^A-Za-z0-9]', '_'))
    $sid = $Config.TargetSid
    $tokens = @($Config.TokenSids)
    if ($Volume.IsSystem) {
        $dirs = @($Targets | Where-Object { $_.IsDirectory } | ForEach-Object { $_.Path })
        if ($dirs.Count -eq 0) { return @{ Status = 'Protected'; Unreadable = 0; WriteErrors = 0; Objects = 0 } }
        $scan = Invoke-SandboxTreeScan -Roots $dirs -Sid $sid -TokenSids $tokens -Model $Model -LogPrefix $prefix -Heartbeat $Heartbeat -Label "Checking locked folders on $($Volume.MountPath)"
    } else {
        $scan = Invoke-SandboxTreeScan -Roots @($Volume.MountPath) -Sid $sid -TokenSids $tokens -Model $Model -LogPrefix $prefix -SkipVolumeSystemFolders -Heartbeat $Heartbeat -Label "Checking every object on $($Volume.MountPath)"
    }
    $status = 'Protected'
    if ($scan.WriteErrors -gt 0) { $status = 'Incomplete' }
    elseif ($scan.Unreadable -gt 0) { $status = 'ProtectedWithExceptions' }
    return @{ Status = $status; Unreadable = $scan.Unreadable; WriteErrors = $scan.WriteErrors; Objects = $scan.Objects }
}

function Get-SandboxSkippedScanStatus {
    # -SkipAclScan keeps a clean result of an earlier check. Without one the volume really is unverified.
    param([hashtable]$Entry, [bool]$ProtectionOk)
    if (-not $ProtectionOk) { return 'Incomplete' }
    if ($Entry -and $Entry.LastScanStatus -in 'Protected', 'ProtectedWithExceptions') { return $Entry.LastScanStatus }
    return 'Unverified'
}

function Invoke-SandboxPathCheck {
    # Phase 2 for one folder that lost its release, including the folder itself. Returns the number of write errors.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][hashtable]$Model, [Parameter(Mandatory)][hashtable]$Layout)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $prefix = Join-Path $Layout.LogDir ('path-' + [guid]::NewGuid().ToString('N'))
    $scan = Invoke-SandboxTreeScan -Roots @($Path) -Sid $Config.TargetSid -TokenSids @($Config.TokenSids) -Model $Model -LogPrefix $prefix -Label "Checking every object below $Path"
    $single = @{ Sid = $Config.TargetSid; TokenSids = @($Config.TokenSids); Unreadable = 0; WriteErrors = 0; Denied = 0; Objects = 0; UnreadableLog = "$prefix.unreadable.log"; OwnerLog = "$prefix.owner.log" }
    # With a release left below it the folder is a parent and already has its rules. A full deny would cut that release off.
    if (-not $Model.Parents.Contains($Path.TrimEnd('\'))) { Invoke-SandboxScanItem -Item (Get-Item -LiteralPath $Path -Force) -Scan $single }
    return ($scan.WriteErrors + $single.WriteErrors)
}

function Set-SandboxVolumeStatus {
    # Locked never overwrites the last scan result, that is kept separately.
    param([Parameter(Mandatory)][hashtable]$Layout, [Parameter(Mandatory)][hashtable]$Volume, [Parameter(Mandatory)][string]$Status, [hashtable]$Scan, [bool]$ScanPending = $false)
    Update-SandboxState -Layout $Layout -Change {
        param($state)
        $entry = $state.Volumes[$Volume.Key]
        if (-not $entry) { $entry = @{ ScanFailures = 0 } }
        $entry['MountPath'] = $Volume.MountPath
        $entry['Status'] = $Status
        $entry['ScanPending'] = $ScanPending
        if ($Scan) {
            $entry['LastScanStatus'] = $Status
            $entry['LastScanUtc'] = [DateTime]::UtcNow.ToString('o')
            $entry['UnreadableCount'] = $Scan.Unreadable
            if ($Status -eq 'Incomplete') { $entry['ScanFailures'] = [int]$entry['ScanFailures'] + 1 } else { $entry['ScanFailures'] = 0 }
        }
        $state.Volumes[$Volume.Key] = $entry
    }
}

# ---------------------------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------------------------

function Get-SandboxClaudeBlockPaths {
    <#
    .SYNOPSIS
    All Claude binaries of the executing user. Standard paths are blocked even if the file does not exist yet.
    Version files have no extension, so nothing here filters on *.exe. Works as SYSTEM: no ~, no Get-Command.
    #>
    param([Parameter(Mandatory)][string]$ExecutorProfile, [string]$UserPathValue)
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add((Join-Path $ExecutorProfile '.local\bin\claude.exe'))
    $choco = Join-Path $env:ProgramData 'chocolatey'
    $paths.Add((Join-Path $choco 'bin\claude.exe'))

    $versions = Join-Path $ExecutorProfile '.local\share\claude\versions'
    if (Test-Path -LiteralPath $versions -ErrorAction SilentlyContinue) {
        foreach ($file in Get-ChildItem -LiteralPath $versions -File -Force -ErrorAction SilentlyContinue) { $paths.Add($file.FullName) }
    }
    $searches = @(
        @{ Root = (Join-Path $choco 'lib'); Folder = '*claude*'; File = 'claude*.exe' },
        @{ Root = (Join-Path $ExecutorProfile '.vscode\extensions'); Folder = 'anthropic.claude-code-*'; File = 'claude*.exe' },
        @{ Root = (Join-Path $ExecutorProfile 'AppData\Roaming\npm\node_modules\@anthropic-ai'); Folder = 'claude-code*'; File = 'claude*.exe' },
        @{ Root = (Join-Path $ExecutorProfile 'AppData\Local\Microsoft\WinGet\Packages'); Folder = 'Anthropic.ClaudeCode*'; File = 'claude*.exe' }
    )
    foreach ($search in $searches) {
        if (-not (Test-Path -LiteralPath $search.Root -ErrorAction SilentlyContinue)) { continue }
        foreach ($folder in Get-ChildItem -LiteralPath $search.Root -Directory -Filter $search.Folder -ErrorAction SilentlyContinue) {
            foreach ($file in Get-ChildItem -LiteralPath $folder.FullName -File -Recurse -Depth 5 -Filter $search.File -ErrorAction SilentlyContinue) { $paths.Add($file.FullName) }
        }
    }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($entry in (@($machinePath, $UserPathValue) -join ';') -split ';') {
        if (-not $entry) { continue }
        $expanded = $entry -ireplace '%USERPROFILE%', $ExecutorProfile.Replace('$', '$$')
        $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
        try {
            $candidate = Join-Path $expanded 'claude.exe'
            if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) { $paths.Add($candidate) }
        } catch { }
    }
    return @($paths | Select-Object -Unique)
}

function Get-SandboxUserPathFromHive {
    # As SYSTEM the value is only readable while the hive is loaded, which is why the task runs at logon.
    param([Parameter(Mandatory)][string]$Sid)
    $key = [Microsoft.Win32.Registry]::Users.OpenSubKey("$Sid\Environment")
    if (-not $key) { return $null }
    try { return $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Dispose() }
}

function New-SandboxFirewallRule {
    param([Parameter(Mandatory)][string]$Program, [Parameter(Mandatory)][string]$ExecutorSid, [string]$Group = $script:FirewallGroup)
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Program.ToLowerInvariant()))).Replace('-', '').Substring(0, 12)
    $null = New-NetFirewallRule -Name "$Group-$hash" -DisplayName "Claude sandbox: block $hash" -Group $Group -Direction Outbound -Action Block -Profile Any -Program $Program -LocalUser "D:(A;;CC;;;$ExecutorSid)" -ErrorAction Stop
}

function Sync-SandboxFirewallRules {
    # Adds missing rules and removes rules of version files that no longer exist. Returns how many of each.
    param([Parameter(Mandatory)][string]$ExecutorSid, [Parameter(Mandatory)][string[]]$Programs)
    $wanted = [Collections.Generic.HashSet[string]]::new([string[]]$Programs, [StringComparer]::OrdinalIgnoreCase)
    $existing = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $added = 0
    $removed = 0
    foreach ($rule in Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue) {
        $program = (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule).Program
        if ($wanted.Contains($program)) { $null = $existing.Add($program) }
        else {
            Remove-NetFirewallRule -InputObject $rule -ErrorAction SilentlyContinue
            $removed++
        }
    }
    foreach ($program in $Programs) {
        if (-not $existing.Contains($program)) {
            New-SandboxFirewallRule -Program $program -ExecutorSid $ExecutorSid
            $added++
        }
    }
    return @{ Added = $added; Removed = $removed; Kept = $existing.Count }
}

function Test-SandboxFirewallEnabled {
    # A third-party firewall usually disables these profiles, then the sandbox reports the block as not set.
    $profiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    return ($profiles.Count -gt 0 -and @($profiles | Where-Object { $_.Enabled -ne 'True' }).Count -eq 0)
}

function Invoke-SandboxCurlAsExecutor {
    param([Parameter(Mandatory)][string]$Curl, [Parameter(Mandatory)][string]$Url)
    return (Invoke-SandboxQuietProcess -FilePath $Curl -ArgumentList @('-s', '-o', 'NUL', '-m', '15', $Url) -TimeoutSeconds 30)
}

function Test-SandboxFirewallScoping {
    <#
    .SYNOPSIS
    Function test: does a block rule with -LocalUser hit only the executing user?
    Returns Passed, NotPossibleNoNetwork or Failed. The test rule is removed in every case.
    #>
    param([Parameter(Mandatory)][pscredential]$Credential, [Parameter(Mandatory)][string]$ExecutorSid, [Parameter(Mandatory)][hashtable]$Layout)
    $url = 'https://api.anthropic.com'
    $group = "$($script:FirewallGroup)-Test"
    Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Layout.FwTest)) { New-SandboxProtectedFolder -Path $Layout.FwTest }
    $curl = Join-Path $Layout.FwTest 'claude-sandbox-fwtest.exe'
    Copy-Item -LiteralPath (Get-SandboxSystemTool 'curl.exe') -Destination $curl -Force
    $asUser = { (Invoke-SandboxUserProcess -Credential $Credential -FilePath $curl -ArgumentList @('-s', '-o', 'NUL', '-m', '15', $url) -TimeoutSeconds 30).ExitCode }
    try {
        if ((Invoke-SandboxCurlAsExecutor -Curl $curl -Url $url) -ne 0 -or (& $asUser) -ne 0) { return 'NotPossibleNoNetwork' }
        New-SandboxFirewallRule -Program $curl -ExecutorSid $ExecutorSid -Group $group
        Start-Sleep -Seconds 2
        $executorBlocked = (Invoke-SandboxCurlAsExecutor -Curl $curl -Url $url) -ne 0
        $targetPasses = (& $asUser) -eq 0
        if ($executorBlocked -and $targetPasses) { return 'Passed' }
        return 'Failed'
    } finally {
        Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $curl -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------
# Scheduled tasks and removal helpers
# ---------------------------------------------------------------------------------------------

function Get-SandboxTaskAction {
    param([Parameter(Mandatory)][string]$PwshPath, [Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][hashtable]$Layout, [string]$ConfigPath)
    $script = Join-Path $Layout.Root 'Update-ClaudeSandbox.ps1'
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Mode $Mode"
    if ($ConfigPath) { $arguments += " -ConfigPath `"$ConfigPath`"" }
    return (New-ScheduledTaskAction -Execute (Join-Path $PwshPath 'pwsh.exe') -Argument $arguments -WorkingDirectory $env:SystemRoot)
}

function Register-SandboxTasks {
    param([Parameter(Mandatory)][string]$PwshPath, [Parameter(Mandatory)][hashtable]$Layout)
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest -LogonType ServiceAccount
    $common = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; MultipleInstances = 'IgnoreNew'; StartWhenAvailable = $true }

    $checkTriggers = @(
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 15))
    )
    $checkSettings = New-ScheduledTaskSettingsSet @common -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $null = Register-ScheduledTask -TaskName 'ClaudeSandbox-Check' -Action (Get-SandboxTaskAction -PwshPath $PwshPath -Mode Check -Layout $Layout) -Trigger $checkTriggers -Principal $principal -Settings $checkSettings -Force

    # Time limit zero on purpose: Phase 1 and 2 can run for hours on large volumes.
    $rootSettings = New-ScheduledTaskSettingsSet @common -ExecutionTimeLimit ([TimeSpan]::Zero)
    $null = Register-ScheduledTask -TaskName 'ClaudeSandbox-Root' -Action (Get-SandboxTaskAction -PwshPath $PwshPath -Mode Root -Layout $Layout) -Principal $principal -Settings $rootSettings -Force

    $scanSettings = New-ScheduledTaskSettingsSet @common -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 7
    $scanTrigger = New-ScheduledTaskTrigger -Daily -At '03:30'
    $null = Register-ScheduledTask -TaskName 'ClaudeSandbox-Scan' -Action (Get-SandboxTaskAction -PwshPath $PwshPath -Mode Scan -Layout $Layout) -Trigger $scanTrigger -Principal $principal -Settings $scanSettings -Force
}

function Stop-SandboxTasks {
    param([switch]$Unregister)
    foreach ($name in @($script:TaskNames) + $script:TestTaskName) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue }
        if ($Unregister) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Get-SandboxUserProcesses {
    param([Parameter(Mandatory)][string]$Sid)
    $found = foreach ($process in Get-CimInstance -ClassName Win32_Process) {
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
            if ($owner.ReturnValue -eq 0 -and $owner.Sid -eq $Sid) { $process }
        } catch { }
    }
    return @($found)
}

function Get-SandboxInteractiveOwners {
    # Owners of explorer.exe in this session, the account a desktop link and firewall rule must belong to.
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $found = foreach ($process in Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'") {
        if ($process.SessionId -ne $session) { continue }
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
            if ($owner.ReturnValue -eq 0) { $owner.Sid }
        } catch { }
    }
    return @($found | Select-Object -Unique)
}

function Invoke-SandboxWithUserHive {
    <#
    .SYNOPSIS
    Runs a script block with an open, writable key of the target user's registry hive, loading the hive if
    needed. Returns $false if that keeps failing.
    The block gets a RegistryKey, never a name: Windows unloads the hive shortly after the user's last process
    ended, and a name-based create below HKEY_USERS then fails with ERROR_INVALID_PARAMETER. The open handle
    keeps the hive in place, and the retry covers the moment it disappears. The block must be idempotent.
    #>
    param([Parameter(Mandatory)][string]$Sid, [Parameter(Mandatory)][string]$ProfilePath, [Parameter(Mandatory)][scriptblock]$Action, [int]$Attempts = 6, [int]$DelaySeconds = 5)
    $mount = "ClaudeSandbox_$($Sid -replace '-', '_')"
    $hive = Join-Path $ProfilePath 'NTUSER.DAT'
    $reg = Get-SandboxSystemTool 'reg.exe'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds $DelaySeconds }
        $root = $null
        $mounted = $false
        try {
            $root = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid, $true)
            if (-not $root) {
                if ((Invoke-SandboxQuietProcess -FilePath $reg -ArgumentList @('load', "HKU\$mount", $hive)) -ne 0) { continue }
                $mounted = $true
                $root = [Microsoft.Win32.Registry]::Users.OpenSubKey($mount, $true)
                if (-not $root) { continue }
            }
            $null = & $Action $root
            return $true
        } catch {
            Write-SandboxMessage -LogOnly -Level Warn -Message "Registry attempt $attempt of ${Attempts}: $($_.Exception.GetBaseException().GetType().Name)"
        } finally {
            if ($root) { $root.Dispose() }
            if ($mounted) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                $null = Invoke-SandboxQuietProcess -FilePath $reg -ArgumentList @('unload', "HKU\$mount")
            }
        }
    }
    return $false
}

function Set-SandboxUserPathEntries {
    # Appends entries to the target user's PATH and keeps the value expandable. Returns the entries it added.
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Root, [Parameter(Mandatory)][string[]]$Entries)
    $key = $Root.CreateSubKey('Environment')
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = [Collections.Generic.List[string]]::new()
        foreach ($part in $current -split ';') { if ($part) { $parts.Add($part) } }
        $added = [Collections.Generic.List[string]]::new()
        foreach ($entry in $Entries) {
            if (@($parts | Where-Object { Test-SandboxSamePath -Left $_ -Right $entry }).Count -eq 0) {
                $parts.Add($entry)
                $added.Add($entry)
            }
        }
        if ($added.Count -gt 0) { $key.SetValue('Path', ($parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
        return @($added)
    } finally { $key.Dispose() }
}

function Get-SandboxTerminalRegisterCommand {
    # Runs as the target user: exit 0 means Windows Terminal is registered for this account, 3 means it failed.
    return ("if(Get-AppxPackage -Name Microsoft.WindowsTerminal){exit 0};" +
        "try{Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.WindowsTerminal_8wekyb3d8bbwe -ErrorAction Stop}catch{exit 3};" +
        "if(Get-AppxPackage -Name Microsoft.WindowsTerminal){exit 0};exit 3")
}

function Register-SandboxTerminal {
    <#
    .SYNOPSIS
    Makes an installed Windows Terminal usable for the target user. Packages are registered per account,
    usually at the first interactive sign-in. Returns Available, NotInstalled or Failed.
    The Appx cmdlets run in Windows PowerShell, where they are native. Only exit codes are read.
    #>
    param([Parameter(Mandatory)][pscredential]$Credential)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $installed = Invoke-SandboxQuietProcess -FilePath $powershell -TimeoutSeconds 120 -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command',
        'if(Get-AppxPackage -AllUsers -Name Microsoft.WindowsTerminal){exit 0};exit 1'
    )
    if ($installed -ne 0) { return 'NotInstalled' }
    $result = Invoke-SandboxUserProcess -Credential $Credential -FilePath $powershell -TimeoutSeconds 300 -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', (Get-SandboxTerminalRegisterCommand)
    )
    if ($result.ExitCode -eq 0) { return 'Available' }
    return 'Failed'
}

function Get-SandboxTaskNames {
    return (@($script:TaskNames) + $script:TestTaskName)
}

function Get-SandboxFirewallGroup {
    return $script:FirewallGroup
}

Export-ModuleMember -Function *
