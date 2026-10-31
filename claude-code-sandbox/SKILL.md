---
name: claude-code-sandbox
description: Set up, check or remove a restricted Windows account that runs Claude Code - no admin rights, access only to Windows folders, its profile, a claude folder and the Git folder, a desktop link without password prompt, and a firewall block for Claude in the executing account. Use when the user wants to install, repair, extend (-AllowPath) or uninstall this sandbox on Windows.
---

# Claude Code sandbox for Windows

`<Skill>` is the folder of this file. Details, security model and residual risks: [README.md](README.md).

## What Claude does and does not do

- **Never run these scripts yourself to change the system.** They need administrator rights and change permissions on every volume. Give the user the exact command for their own elevated terminal, from the README.
- **Never call `Start-ClaudeTerminal.ps1 -ShowPassword` yourself.** It refuses redirected output. Only name the command for the user's own terminal: `& "$env:LOCALAPPDATA\ClaudeSandbox\Start-ClaudeTerminal.ps1" -ShowPassword`.
- If Claude itself runs as the sandbox user, that session must end before an installation run. The script asks to end all processes of the target user.
- Recommend the VHDX trial run from the README before the first real run.

## Files

| Path | Purpose |
|---|---|
| `scripts/Install-ClaudeSandbox.ps1` | Installation, repeat runs, `-AllowPath`, `-RemoveAllowPath`, `-AclTestOnly` |
| `scripts/Uninstall-ClaudeSandbox.ps1` | Removal, also of a trial run with `-AclTestOnly` |
| `scripts/Update-ClaudeSandbox.ps1` | Scheduled follow-up as SYSTEM, modes `Check`, `Root`, `Scan` |
| `scripts/Start-ClaudeTerminal.ps1` | Starter behind the desktop link, copied to `%LOCALAPPDATA%\ClaudeSandbox` |
| `scripts/Show-ClaudeStatus.ps1` | Warnings at the start of the terminal |
| `scripts/Invoke-ClaudeSandboxProbe.ps1` | Tests that run as the target user |
| `scripts/ClaudeSandbox.psm1` | Shared logic |

## Exit codes of the installation

- `0`: all selected volumes are `Protected` or `ProtectedWithExceptions`.
- `1`: `Incomplete`, `Unverified`, or a failed self-test.
- `2`: otherwise fine, but a volume is `Locked` or `NoAcls`, or the firewall block is not set.

## Editing the scripts

- All output, names and comments stay in English. Never read text from external tools, only exit codes, SIDs and objects.
- Never use `icacls /T` or `GetFiles` with `AllDirectories`: both walk through junctions. Every `icacls` call goes through `Invoke-SandboxIcacls`.
- Never start anything through PATH from an elevated or SYSTEM process.
- Keep every file parsable in Windows PowerShell 5.1 and saved as UTF-8 with BOM.
- PowerShell variables are case-insensitive: a local `$volumes` overwrites the parameter `$Volumes`.
