# Runs as the target user. Executes the tests from a JSON file and prints the results as JSON.
# Results rely on exception types and exit codes only, never on localized text.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestsPath)

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
[Threading.Thread]::CurrentThread.CurrentCulture = $culture
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'

function Get-ProbeResult {
    param([scriptblock]$Action)
    try { & $Action; return 'Allowed' }
    catch [UnauthorizedAccessException] { return 'Denied' }
    catch [IO.FileNotFoundException] { return 'Missing' }
    catch [IO.DirectoryNotFoundException] { return 'Missing' }
    catch { return $_.Exception.GetType().Name }
}

$results = foreach ($test in @(Get-Content -LiteralPath $TestsPath -Raw -Encoding utf8 | ConvertFrom-Json)) {
    $outcome = switch ($test.Op) {
        'WriteFile' {
            Get-ProbeResult {
                $file = Join-Path $test.Path (".probe-" + [guid]::NewGuid().ToString('N'))
                [IO.File]::WriteAllText($file, 'probe')
                [IO.File]::Delete($file)
            }
        }
        'CreateDirectory' {
            Get-ProbeResult {
                $folder = Join-Path $test.Path (".probe-" + [guid]::NewGuid().ToString('N'))
                $created = [IO.Directory]::CreateDirectory($folder)
                $created.Delete()
            }
        }
        'ReadFile' {
            Get-ProbeResult { $stream = [IO.File]::OpenRead($test.Path); $stream.Dispose() }
        }
        'ListDirectory' {
            Get-ProbeResult { foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($test.Path)) { break } }
        }
        'Run' {
            try {
                $arguments = @($test.Arguments)
                & $test.Path @arguments *> $null
                "Exit$LASTEXITCODE"
            } catch { 'NotStarted' }
        }
        default { 'UnknownOperation' }
    }
    @{ Name = $test.Name; Op = $test.Op; Path = $test.Path; Expect = $test.Expect; Outcome = $outcome }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$groups = @($identity.Groups | ForEach-Object Value | Where-Object { $_ -notmatch '^S-1-5-5-' -and $_ -notmatch '^S-1-16-' })
$claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
@{
    Sid        = $identity.User.Value
    Groups     = $groups
    Profile    = $env:USERPROFILE
    ClaudePath = $(if ($claude) { $claude.Source })
    Results    = @($results)
} | ConvertTo-Json -Depth 5 -Compress
