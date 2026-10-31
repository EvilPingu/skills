# Shown at the start of the Claude terminal. Runs as the target user and only reads state.json.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$StatePath,
    [Parameter(ValueFromRemainingArguments)][string[]]$UnknownArguments
)

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
[Threading.Thread]::CurrentThread.CurrentCulture = $culture

if (-not $StatePath) { $StatePath = Join-Path $PSScriptRoot 'state.json' }

function Write-StatusWarning {
    param([string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

try {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        Write-StatusWarning 'The sandbox status is not available.'
        return
    }
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json

    foreach ($property in $state.Volumes.PSObject.Properties) {
        $volume = $property.Value
        switch ($volume.Status) {
            'Incomplete' { Write-StatusWarning "$($volume.MountPath): the permission check is incomplete." }
            'Unverified' { Write-StatusWarning "$($volume.MountPath): the permission check has not run yet." }
            'Locked' { Write-StatusWarning "$($volume.MountPath): the volume is locked or offline, its permissions could not be set." }
            'NoAcls' { Write-StatusWarning "$($volume.MountPath): the file system has no permissions, this volume is not protected." }
        }
    }
    if ($state.PartialVolumes) { Write-StatusWarning 'Only part of the volumes is protected (-Volumes).' }
    if ($state.FirewallStatus -and $state.FirewallStatus -ne 'Passed') {
        Write-StatusWarning "The firewall block for the executing user is not set ($($state.FirewallStatus))."
    }
    foreach ($longMode in 'Root', 'Scan') {
        $beat = $state.Heartbeat.$longMode
        if ($beat -and $state.Running.$longMode -and ([DateTime]::UtcNow - ([DateTime]$beat).ToUniversalTime()).TotalHours -gt 1) {
            Write-StatusWarning "The $longMode task has not reported progress for over an hour."
        }
    }
    foreach ($message in @($state.Messages)) { if ($message) { Write-StatusWarning $message } }
} catch {
    Write-StatusWarning "The sandbox status could not be read ($($_.Exception.GetType().Name))."
}
