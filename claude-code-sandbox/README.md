# claude-code-sandbox

Runs Claude Code under a restricted Windows account (default name `claude-code`):

- No administrator rights, no other groups than Users.
- Access only to Windows folders, its own profile, a `claude` folder (full control), your Git folder (read and write) and detected toolchains (read). Other volumes and non-Windows folders on the system drive are locked, including the profiles of other accounts. Removable storage is blocked by policy.
- A desktop link opens a terminal as that account in the `claude` folder, without a password prompt.
- A firewall rule blocks Claude for **your own** account, so Claude only reaches the network from the restricted account.

Works on any Windows 10 or 11, with or without Claude, Git or PowerShell 7 installed. No drive letters or paths are assumed. Instructions for Claude: [SKILL.md](SKILL.md).

> **Status:** The scripts were checked for syntax, the non-admin paths and the logic that works without administrator rights. They were **never run with administrator rights**. Do the trial run below first.

## Before you start

1. End every process of the target user, including a Claude session that runs as this user. The script lists them and ends them only after you confirm.
2. Do the [trial run](#trial-run-on-a-vhdx).
3. If the repository is inside the folder that the target user can write to, the script offers to copy itself to `%ProgramData%\ClaudeSandbox\install\` and continue from there.

## Install

Open a normal terminal and run this. It uses absolute paths on purpose: a bare `pwsh` starts the first file found through PATH, and PATH may contain folders that others can write to. `-NoProfile` keeps your profile from running elevated.

With PowerShell 7 installed:

```powershell
Start-Process "$env:ProgramFiles\PowerShell\7\pwsh.exe" -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"<Repo>\claude-code-sandbox\scripts\Install-ClaudeSandbox.ps1"'
```

Without PowerShell 7, the script installs it with winget and restarts itself:

```powershell
Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"<Repo>\claude-code-sandbox\scripts\Install-ClaudeSandbox.ps1"'
```

The script asks for the volume of the `claude` folder and for your Git folder. All questions come before the long phases. Checking every object on a large volume can take hours, progress stays visible, and an interrupted run can simply be repeated. The window waits for Enter at the end and shows the exit code and log path.

For repeat runs and uninstalling, use the copy in `%ProgramData%\ClaudeSandbox\install\`.

| Parameter | Meaning |
|---|---|
| `-UserName` | Name of the target user, default `claude-code` |
| `-ClaudeDrive` | Volume of the `claude` folder, for example `D:` |
| `-GitPath` | Git folder. It may not exist yet |
| `-Volumes` | Only these volumes, separated by `;`. Saved, and the tasks respect it |
| `-AllowPath` | Extra read access, separated by `;` |
| `-RemoveAllowPath` | Takes back an `-AllowPath`, separated by `;` |
| `-SkipAclScan` | Skips checking every object, the status stays `Unverified` |
| `-AclTestOnly` | Trial run, see below |
| `-WhatIf` | Lists the steps only. This does not test any permission |

Lists use `;` because `pwsh -File` passes `a,b` as one string.

**Exit codes:** `0` all selected volumes are `Protected` or `ProtectedWithExceptions`. `1` `Incomplete`, `Unverified` or a failed self-test. `2` otherwise fine, but a volume is `Locked` or `NoAcls`, or the firewall block is not set.

After the run, double-click **Claude Terminal**, run `claude` and sign in. Sign in to GitHub on the first push.

The link opens Windows Terminal if it is available for the target user. Packages are registered per account, usually at the first interactive sign-in, so the installation registers an installed Windows Terminal for the target user and adds `wt` to its PATH. If Windows Terminal is not installed or cannot be registered, a plain console window opens instead. The script does not install Windows Terminal itself. Signing in once with the target account usually fixes a failed registration.

Show the stored password in your own terminal, not in Claude:

```powershell
& "$env:LOCALAPPDATA\ClaudeSandbox\Start-ClaudeTerminal.ps1" -ShowPassword
```

## Trial run on a VHDX

This changes only a small virtual disk and a test user. No scheduled task stays behind, and your real volumes, Git folder, firewall and desktop link are not touched.

All steps need an elevated terminal of your own signed-in administrator account. Open it without your profile:

```powershell
Start-Process "$env:ProgramFiles\PowerShell\7\pwsh.exe" -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass'
```

1. Create the disk. Paste this as a whole into PowerShell, it feeds the commands to `diskpart`. Use a free drive letter instead of `V` here and in the steps below:

   ```powershell
   if (Test-Path V:\) { throw 'V: is already in use. Pick another letter.' }
   $vhdx = Join-Path $env:TEMP 'sandbox-test.vhdx'
   $commands = Join-Path $env:TEMP 'sandbox-test-diskpart.txt'
   @("create vdisk file=`"$vhdx`" maximum=512 type=expandable", "select vdisk file=`"$vhdx`"", 'attach vdisk', 'create partition primary', 'format fs=ntfs quick', 'assign letter=V') | Set-Content -LiteralPath $commands -Encoding ascii
   & "$env:SystemRoot\System32\diskpart.exe" /s $commands
   Test-Path V:\
   ```

   The last line must print `True`.

2. Prepare test data. The junction target has to be on another volume than the VHDX:

   ```powershell
   New-Item -ItemType Directory V:\work\repos\git, V:\work\tools\bin, V:\work\outer\inner, V:\work\sibling, V:\noinherit, V:\adminblocked, C:\sandbox-junction-target | Out-Null
   icacls V:\work /grant '*S-1-5-32-545:(OI)(CI)(M)'
   icacls V:\noinherit /inheritance:r /grant '*S-1-5-11:(OI)(CI)(M)' '*S-1-5-32-544:(OI)(CI)(F)'
   Set-Content C:\sandbox-junction-target\file.txt 'x'
   New-Item -ItemType Junction -Path V:\work\repos\git\link -Target C:\sandbox-junction-target | Out-Null
   # Admins may not read this folder: shows whether SeBackupPrivilege works with the commands used.
   icacls V:\adminblocked /inheritance:r /grant '*S-1-5-18:(OI)(CI)(F)'
   ```

3. Run the trial. It also runs Check, Root and Scan once as SYSTEM:

   ```powershell
   & "$env:ProgramFiles\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "<Repo>\claude-code-sandbox\scripts\Install-ClaudeSandbox.ps1" -AclTestOnly -Volumes V: -UserName claude-sandbox-test -GitPath V:\work\repos\git -AllowPath "V:\work\tools\bin;V:\work\outer;V:\work\outer\inner"
   ```

   Expected: `git` writable, `bin`, `outer` and `inner` readable, `sibling` and `noinherit` locked, the ACL of the junction target unchanged, exit code `0`.

4. Remove it, run from `%ProgramData%\ClaudeSandbox\install\` if the script moved itself there:

   ```powershell
   & "$env:ProgramFiles\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "<Script folder>\Uninstall-ClaudeSandbox.ps1" -AclTestOnly -Volumes V: -UserName claude-sandbox-test
   ```

5. Delete the test data:

   ```powershell
   $vhdx = Join-Path $env:TEMP 'sandbox-test.vhdx'
   $commands = Join-Path $env:TEMP 'sandbox-test-diskpart.txt'
   @("select vdisk file=`"$vhdx`"", 'detach vdisk') | Set-Content -LiteralPath $commands -Encoding ascii
   & "$env:SystemRoot\System32\diskpart.exe" /s $commands
   Remove-Item -LiteralPath $vhdx, $commands, C:\sandbox-junction-target -Recurse -Force
   ```

## Security model

**Locks.** A deny on the volume root is not enough: an explicit allow on a subfolder beats an inherited deny, and folders without inheritance are never reached. So each volume goes through two phases: set the deny on the root, then check every object. An object gets its own deny if it does not inherit, has an explicit allow for a SID of the user's token, or lacks the inherited deny. Objects owned by the target user move to Administrators, because an owner can always change the ACL.

**Three classes:**

| Class | Scope | Rule |
|---|---|---|
| Untouched | Windows folders on the system drive and their content | No entries. The drive root only gets a deny on creating items |
| Profile root on the system drive | The folder itself is unchanged | Own profile free, other profiles locked |
| Releases | Claude, Git, toolchains and `-AllowPath` elsewhere, Windows folders on other volumes | Allow plus parent rules, which end at the first ancestor that is untouched, the own profile or itself a release |

**Parent paths** can be traversed but not listed. Node runs `lstat` on every path component, so this is required for Claude to work.

**Writable trees.** Inside the Git and `claude` folders, administrator and SYSTEM only ever change the top folder and only read below it. The target user could otherwise place a junction to the sandbox's own scripts and have them opened up for it. The scripts never use `icacls /T`. Subfolders without inheritance there are only reported.

**Password.** Random, 32 letters and digits, stored with DPAPI for your account in `%LOCALAPPDATA%\ClaudeSandbox\credential.xml`.

**Firewall.** Before any rule is added, a copy of `curl.exe` is tested under both accounts. Rules are only created if it is blocked for you and passes for the target user. Without that proof the status says so, and no rules exist. Rules cover Claude from the native installer, Chocolatey, npm, WinGet, the VS Code extension and PATH.

**Scheduled tasks, all as SYSTEM.** They start nothing through PATH.

| Task | When | Does |
|---|---|---|
| `ClaudeSandbox-Check` | At logon, every 15 minutes | Firewall rules for new Claude versions, detects unlocked volumes and new folders |
| `ClaudeSandbox-Root` | Started by Check | Phase 1 on those |
| `ClaudeSandbox-Scan` | Daily and when needed | Phase 2, at most daily for an `Incomplete` volume, three attempts |

## Volume status

| Status | Meaning |
|---|---|
| `Protected` | Every object was checked |
| `ProtectedWithExceptions` | Some objects stayed unreadable even with backup rights. The list is in an admin-only log |
| `Incomplete` | Interrupted, or permissions could not be written |
| `Unverified` | The check of every object has not run |
| `Locked` | Locked or offline, permissions could not be set |
| `NoAcls` | FAT or exFAT, cannot be protected |

The terminal shows warnings for everything except the first two.

## Git

The target user trusts your Git folder through `safe.directory`. Your own account does not: Git refuses repositories owned by the target user, and that is what stops hooks placed there. The script asks per repository, default No. Repositories created later need it by hand, only if you trust them:

```powershell
git config --global --add safe.directory E:/path/to/repo
```

Use the exact spelling of the path, with forward slashes.

## Uninstall

Run from `%ProgramData%\ClaudeSandbox\install\`:

```powershell
Start-Process "$env:ProgramFiles\PowerShell\7\pwsh.exe" -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$env:ProgramData\ClaudeSandbox\install\Uninstall-ClaudeSandbox.ps1`""
```

Tasks stop first, then entries of the target user, firewall rules, policy, link and the sandbox folders are removed. Deleting the user is a separate question, default No; if it stays, its password file stays too.

Not reverted: ownership moved to Administrators (the script saves the list as `ClaudeSandbox-ownership-*.log` in your profile). Subfolders without inheritance in the Git and `claude` folders keep their entries.

## Residual risks

- **Shared desktop.** The target user runs on your desktop. Windows separates windows by integrity level, not by user. It could probably send input to your windows, read the clipboard and take screenshots. This setup cannot solve that.
- **Shared repositories.** What the target user places in a repository, such as hooks or scripts, can run under your account when you work there.
- **The password.** Any process under your account can decrypt it. That is the price of starting without a prompt.
- **Network.** The target user keeps full network access, including LAN, localhost services and UNC paths. Shares it can reach are not covered by any of this.
- **Firewall gaps.** Not blocked for your account: the Claude desktop app and programs Claude starts, such as `git` or `curl`. New Claude versions stay unblocked until the next check, up to 15 minutes.
- **Unlocked volumes** stay open for up to 15 minutes plus the duration of Phase 1. A volume can also wait for the ones before it.
- **Deep changes.** An allow set later deep inside a protected tree is only found by a new installation run.
- **Script origin.** Installing from the repository takes over earlier manipulation of the scripts. The copy to `install\` only protects from then on.
- **Running processes** of the target user keep old groups and open handles until they end.
- **Shadow copies** keep old permissions and may be readable for normal users. The script lists them and deletes them only if you agree.
- **`System Volume Information` and `$RECYCLE.BIN`** keep only the deny from the root, their content is not checked one by one.
- **Removable storage** is blocked by a per-user policy, which Windows Home may not evaluate.

Sign-in to Claude and GitHub is done by you on the first start, inside the target account.
