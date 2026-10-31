# Copied to %LOCALAPPDATA%\ClaudeSandbox by the installer and started from the desktop link.
# It must not run from the repository: the target user can write there.
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$ShowPassword,
    [Parameter(ValueFromRemainingArguments)][string[]]$UnknownArguments
)

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
[Threading.Thread]::CurrentThread.CurrentCulture = $culture
$ErrorActionPreference = 'Stop'

$credentialPath = Join-Path $PSScriptRoot 'credential.xml'
$settingsPath = Join-Path $PSScriptRoot 'terminal.json'
$logPath = Join-Path $PSScriptRoot 'terminal.log'

function Write-TerminalLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $logPath -Value ('{0:u} {1}' -f [DateTime]::UtcNow, $Message) -Encoding utf8 } catch { }
}

function Show-TerminalError {
    # The starter runs hidden, a dialog is the only way to make a failure visible.
    param([string]$Message)
    Write-TerminalLog "Error: $Message"
    Add-Type -AssemblyName System.Windows.Forms
    $null = [System.Windows.Forms.MessageBox]::Show($Message, 'Claude Terminal', 'OK', 'Error')
}

function Get-TerminalBootstrapCommand {
    <#
    .SYNOPSIS
    Command for a hidden pwsh running as the target user. It opens Windows Terminal from that account,
    where the per-user app alias resolves, and falls back to a plain console if that fails.
    #>
    param([string]$PwshExe, [string]$ClaudePath, [string]$StatusScript)
    $literal = { param($value) "'" + $value.Replace("'", "''") + "'" }
    # wt treats a semicolon as a command separator, unless it is escaped.
    $wtSafe = { param($value) $value.Replace(';', '\;') }
    $shellArguments = "-NoLogo -NoExit -ExecutionPolicy Bypass -File `"$StatusScript`""
    $wtArguments = "-w new -d `"$(& $wtSafe $ClaudePath)`" `"$(& $wtSafe $PwshExe)`" -NoLogo -NoExit -ExecutionPolicy Bypass -File `"$(& $wtSafe $StatusScript)`""
    return ("`$w=Join-Path `$env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe';" +
        "try{Start-Process -FilePath `$w -ArgumentList $(& $literal $wtArguments) -ErrorAction Stop}" +
        "catch{Start-Process -FilePath $(& $literal $PwshExe) -WorkingDirectory $(& $literal $ClaudePath) -ArgumentList $(& $literal $shellArguments)}")
}

if ($UnknownArguments) {
    [Console]::Error.WriteLine("Unknown argument: $($UnknownArguments -join ' ')")
    exit 1
}

if ($ShowPassword) {
    if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) {
        [Console]::Error.WriteLine('Refused: -ShowPassword only works in an interactive terminal without redirection.')
        exit 1
    }
    [Console]::WriteLine('This shows the stored password in clear text.')
    [Console]::WriteLine('Close the Claude terminal first: it shares your desktop and could read your screen.')
    $answer = Read-Host 'Show the password? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { exit 0 }
    try {
        $credential = Import-Clixml -LiteralPath $credentialPath
        $plain = $credential.GetNetworkCredential().Password
    } catch {
        [Console]::Error.WriteLine('The stored password is missing or cannot be decrypted. Reset it with a new installation run.')
        exit 1
    }
    # Written directly to the console: never to the pipeline, a log or the clipboard.
    [Console]::WriteLine($plain)
    $plain = $null
    Write-TerminalLog 'Password was shown.'
    exit 0
}

try {
    $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $credentialPath)) { throw [IO.FileNotFoundException]::new('credential') }
    $credential = Import-Clixml -LiteralPath $credentialPath
} catch {
    Show-TerminalError 'The stored password is missing or cannot be decrypted. Reset it with a new installation run.'
    exit 1
}

if (-not (Test-Path -LiteralPath $settings.ClaudePath)) {
    Show-TerminalError "The Claude folder $($settings.ClaudePath) is not available. Its drive may be locked."
    exit 1
}
$service = Get-Service -Name seclogon -ErrorAction SilentlyContinue
if ($service -and $service.StartType -eq 'Disabled') {
    Show-TerminalError 'The Secondary Logon service is disabled. A new installation run enables it again.'
    exit 1
}

try {
    $pwshExe = Join-Path $settings.PwshPath 'pwsh.exe'
    $info = [Diagnostics.ProcessStartInfo]::new($pwshExe)
    $bootstrap = Get-TerminalBootstrapCommand -PwshExe $pwshExe -ClaudePath $settings.ClaudePath -StatusScript $settings.StatusScript
    # CreateProcessWithLogonW limits the command line to 1024 characters. Very long paths get the plain console.
    if ($bootstrap.Length -le 900) {
        foreach ($argument in '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $bootstrap) { $info.ArgumentList.Add($argument) }
        $info.CreateNoWindow = $true
    } else {
        foreach ($argument in '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $settings.StatusScript) { $info.ArgumentList.Add($argument) }
        $info.CreateNoWindow = $false
    }
    # The environment stays untouched, so USERPROFILE and PATH come from the target user.
    $info.UseShellExecute = $false
    $info.LoadUserProfile = $true
    $info.UserName = ($credential.UserName -split '\\')[-1]
    $info.Domain = $env:COMPUTERNAME
    $info.Password = $credential.Password
    $info.WorkingDirectory = $settings.ClaudePath
    $process = [Diagnostics.Process]::Start($info)
    Write-TerminalLog "Terminal started, process $($process.Id)."
} catch [ComponentModel.Win32Exception] {
    $code = $_.Exception.NativeErrorCode
    $hint = switch ($code) {
        1326 { 'The stored password is wrong. Reset it with a new installation run.' }
        1058 { 'The Secondary Logon service is disabled. A new installation run enables it again.' }
        1385 { 'The account may not log on interactively.' }
        267 { "The Claude folder $($settings.ClaudePath) is not accessible." }
        default { 'The terminal could not be started.' }
    }
    Show-TerminalError "$hint (Windows error $code)"
    exit 1
} catch {
    Show-TerminalError "The terminal could not be started ($($_.Exception.GetType().Name))."
    exit 1
}
