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
| `-SkipAclScan` | Skips checking every object on a repeat run and keeps the last result, see below |
| `-AclTestOnly` | Trial run, see below |
| `-WhatIf` | Lists the steps only. This does not test any permission |

**Repeat run without the long check.** `-SkipAclScan` still sets grants, locks and everything else, it only skips checking every object. A volume keeps the status of its last check, and the exit code stays `0` if that was clean. Use it when only something like a new version or a changed setting has to be applied.

- A volume without an earlier check becomes `Unverified`, exit code `1`.
- A folder that just lost its release is always checked, because it may still hold files of the target user.
- An allow set later deep inside a locked tree stays undetected until a run without this switch. The first run and repeat runs after larger changes should not use it.

Lists use `;` because `pwsh -File` passes `a,b` as one string.

**Exit codes:** `0` all selected volumes are `Protected` or `ProtectedWithExceptions`. `1` `Incomplete`, `Unverified` or a failed self-test. `2` otherwise fine, but a volume is `Locked` or `NoAcls`, or the firewall block is not set.

After the run, double-click **Claude Terminal**, run `claude` and sign in. Sign in to GitHub on the first push.

The link opens Windows Terminal if it is available for the target user. Packages are registered per account, usually at the first interactive sign-in, so the installation registers an installed Windows Terminal for the target user and adds `wt` to its PATH. If Windows Terminal is not installed or cannot be registered, a plain console window opens instead. The script does not install Windows Terminal itself. Signing in once with the target account usually fixes a failed registration.

Show the stored password in your own terminal, not in Claude:

```powershell
& "$env:LOCALAPPDATA\ClaudeSandbox\Start-ClaudeTerminal.ps1" -ShowPassword
```

## Updates

Install, Grant and Uninstall compare a hash over all scripts with the public repository and with what is installed. There is no version number to maintain, every change counts. Line endings and a BOM are ignored, so a Windows clone matches the repository. The files from `https://github.com/EvilPingu/skills` are only hashed. Nothing from them is run, because that would be fetched code with administrator rights. Without network that part of the check is skipped silently.

| Situation | What happens |
|---|---|
| The scripts differ from the repository | A warning with the steps below, the script continues. They may be older or have local changes |
| The scripts match the repository, the installation differs | A note. An installation run brings everything up to date |
| The scripts differ from both, or the repository cannot be reached and the installation differs | A warning and a question, default No. A hash cannot tell which is newer, and older scripts do not know newer settings, such as later releases, and could lose them |

To update, in a normal terminal:

```powershell
git -C "<Repo>" pull
```

Without a clone: `git clone https://github.com/EvilPingu/skills.git`. Then start `Install-ClaudeSandbox.ps1` from the clone as shown under [Install](#install), not from `%ProgramData%\ClaudeSandbox\install\`, which holds the old scripts. Your settings and releases are kept, and the script offers to copy the new ones to the install folder. Add `-SkipAclScan` if only the scripts changed. Installations from before this check show their hash as `unknown` until the next run.

## Release more folders later

`Grant-ClaudeSandboxPath.ps1` adds or removes single folders without a full installation run. It applies at once, also in an open Claude terminal, and tests the result as the target user. Run it elevated from the account that did the installation. From the repository it offers to update `%ProgramData%\ClaudeSandbox\install\` first, which also brings the scheduled tasks up to date.

```powershell
Start-Process "$env:ProgramFiles\PowerShell\7\pwsh.exe" -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"<Repo>\claude-code-sandbox\scripts\Grant-ClaudeSandboxPath.ps1"'
```

Without parameters it shows the current releases and asks for the folder and the access.

**Examples.** Open an elevated terminal without your profile, as shown in the [trial run](#trial-run-on-a-vhdx), and set the script path once. The folder names are examples:

```powershell
$grant = "$env:ProgramData\ClaudeSandbox\install\Grant-ClaudeSandboxPath.ps1"
```

The copy in `install\` only has the script after a first start from the repository, or after an installation run with this version. The window waits for Enter after each call.

Show what is released:

```powershell
& $grant -List
```

Let Claude read a tools folder:

```powershell
& $grant -Path 'D:\Tools' -Access Read
```

Let Claude work in two project folders. Several folders are separated by `;`:

```powershell
& $grant -Path 'D:\Projects\app;D:\Projects\web' -Access Write
```

Change a read release to read and write, or back. Name the same folder again:

```powershell
& $grant -Path 'D:\Tools' -Access Write
& $grant -Path 'D:\Tools' -Access Read
```

Let Claude read everything below a parent of your Git folder, for example `E:\work` with the Git folder `E:\work\git`. The Git folder stays writable:

```powershell
& $grant -Path 'E:\work' -Access Read
```

Replace two releases with their common parent. The script lists both and asks before they become part of it:

```powershell
& $grant -Path 'D:\Projects' -Access Write
```

Lock a folder again. A release inside it stays reachable:

```powershell
& $grant -Path 'D:\Tools' -Remove
```

Lock one subfolder of a release, for example `D:\Projects\private`. Remove the outer release first, then release the folders next to it:

```powershell
& $grant -Path 'D:\Projects' -Remove
& $grant -Path 'D:\Projects\app;D:\Projects\web' -Access Write
```

Preview a change without applying it:

```powershell
& $grant -Path 'D:\Tools' -Access Write -WhatIf
```

The same checks as in the installation apply: no volume roots, no Windows folders, no profiles of other accounts, and `Write` not below `AppData` in your own profile. A folder inside your own profile needs a confirmation. `-Access Write` makes a folder a writable tree like the Git folder: administrator and SYSTEM do not change anything below its top folder afterwards. `-Remove` takes back such a release and locks the folder again, including a check of every object in it. It only works for folders released this way, or with `-AllowPath`. The Git and `claude` folders change with a new installation run.

**Folders that contain or sit inside other releases:**

| Case | Result |
|---|---|
| `Read` on a parent of the Git folder or another release | Allowed. The whole tree becomes readable, the folders inside keep their rights |
| `Write` on a parent of a read or write release | Allowed after a confirmation. The folders inside become part of it and lose their own entry |
| `Write` on a parent of the Git or `claude` folder | Refused. The target user could swap those folders. Use `Read`, or release the folders next to them |
| `-Remove` on a parent | The parent is locked again, a release inside stays reachable and the parent can be traversed but not listed |
| `-Remove` on a folder inside a release that stays | Refused, it would stay reachable through the outer release. Single subfolders of a release cannot be locked |

To lock a subfolder of a release: remove the outer release, then release the folders you want next to the locked one.

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
