# wslmass

**WSL** **Ma**nagement **S**cript**s** — for running a WSL2 distro as an always-on server on Windows: one keeps the VM up and attaches dedicated physical disks to it, the other takes a consistent backup of the VHDX with controlled downtime.

- **`wsl_autostart.ps1`** runs under NSSM. It attaches bare physical disks, starts the default distro, and holds it open.
- **`wsl_backup.ps1`** runs from Task Scheduler. It stops the services that touch WSL, shuts the VM down, compacts the VHDX and compresses it into multi-volume 7z files.

Both append to one shared log, `%USERPROFILE%\wsl\logs\wsl.log`.

## Requirements

- Windows 10/11 with WSL2, and a distro with systemd enabled
- Windows PowerShell 5.1
- The Hyper-V PowerShell module, for `Get-VHD` and `Optimize-VHD`
- [NSSM](https://nssm.cc/), to supervise the keepalive
- [7-Zip](https://www.7-zip.org/), for the backup

The Windows-provided `tar.exe` is not a substitute for 7-Zip: it cannot write multi-volume archives.

WSL distros are registered per Windows user, so the service and the scheduled task must both run as the account that registered the distro. That account also needs to attach physical disks, manage services and operate on VHDX files, which is why both run elevated.

### Installing 7-Zip

The installer does not add itself to `PATH`, and neither does `winget`, so `7z.exe` will not resolve afterwards:

```powershell
winget install --id 7zip.7zip -e --accept-source-agreements --accept-package-agreements
```

Add the directory to the machine `PATH` from an elevated session. `TrimEnd(';')` matters, because the stored value often already ends in a semicolon and appending another leaves an empty entry:

```powershell
$path = [Environment]::GetEnvironmentVariable('PATH', 'Machine').TrimEnd(';')
[Environment]::SetEnvironmentVariable('PATH', "$path;C:\Program Files\7-Zip", 'Machine')
```

Only processes started afterwards inherit the change, so open a new session before checking with `where.exe 7z.exe`. Alternatively leave `PATH` alone and pass `-SevenZipPath "C:\Program Files\7-Zip\7z.exe"` per run.

`winget` itself ships with the Microsoft Store's App Installer package and is absent from LTSC editions by design. There, download 7-Zip directly, or copy an existing installation: it is statically linked and needs no registry entries, so `7z.exe` and `7z.dll` run from anywhere.

## Layout

Both scripts assume this tree under `%USERPROFILE%\wsl`:

```text
%USERPROFILE%\wsl\
├── distros\
│   └── <distro>\
│       └── <distro>.vhdx
├── logs\
│   └── wsl.log
├── backups\
│   └── <yyyymmdd>\
└── scripts\
    ├── wsl_autostart.ps1
    └── wsl_backup.ps1
```

The distro directory and its VHDX both take the distro name, and `wsl_backup.ps1` derives the path from it. A distro named `server` lives at `%USERPROFILE%\wsl\distros\server\server.vhdx`.

### Installing the scripts

`logs` and `backups` are created on first run, so only `scripts` has to exist:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\wsl\scripts"
Copy-Item wsl_autostart.ps1, wsl_backup.ps1 -Destination "$env:USERPROFILE\wsl\scripts"
```

`distros` is not created for you: the VHDX has to be there already, which for a new distro means importing it there rather than moving it afterwards.

```powershell
wsl --import <DistributionName> "$env:USERPROFILE\wsl\distros\<distro>" <rootfs>.tar
```

An existing distro can be relocated with `wsl --export` followed by `wsl --unregister` and the same `wsl --import`.

## Autostart

NSSM supervises the script, which attaches the requested disks, starts the distro, and then runs a single `sleep infinity` inside it. PowerShell stays in the foreground for as long as that keepalive lives; when it exits, the script exits and NSSM restarts it.

The explicit `sleep infinity` matters. A bare `wsl` depends on the default shell staying open, and any short-lived command would exit immediately and send NSSM into a restart loop.

### Choosing the distro

There is no distro parameter: the script starts whichever distro WSL considers the default, so the choice is made once on the machine.

```powershell
wsl --list --verbose
wsl --set-default <DistributionName>
```

Pin it explicitly on any machine with more than one distro registered. Installing Docker Desktop or importing another distro can change the default without touching the service, and the keepalive would then hold the wrong distro open.

### Finding drive numbers

```powershell
Get-CimInstance -Query "SELECT * FROM Win32_DiskDrive" |
    Select-Object Index, Model, SerialNumber, Size, DeviceID
```

The `Index` column is the number to use: index `1` is `\\.\PHYSICALDRIVE1`, passed as `-PhysicalDrives "1"`. Check the model, serial and size before configuring anything — attaching the wrong disk takes it away from Windows.

### Installing the service

Every `nssm set` writes to `HKLM` and needs an elevated session.

```powershell
$nssm   = "C:\Users\<username>\nssm.exe"
$ps     = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$script = "C:\Users\<username>\wsl\scripts\wsl_autostart.ps1"

& $nssm install WSL_AUTOSTART $ps
& $nssm set WSL_AUTOSTART AppParameters "-NoProfile -ExecutionPolicy Bypass -F `"$script`""
& $nssm set WSL_AUTOSTART AppDirectory "C:\Windows\System32\WindowsPowerShell\v1.0"
& $nssm set WSL_AUTOSTART DisplayName WSL_AUTOSTART
& $nssm set WSL_AUTOSTART Start SERVICE_AUTO_START
& $nssm set WSL_AUTOSTART AppExit Default Restart
```

`AppExit Default Restart` is already the NSSM default and the design depends on it: the script blocks for as long as the workload lives, so every exit means the keepalive died.

`-NoProfile` keeps the service independent of `Microsoft.PowerShell_profile.ps1`, which would otherwise be executed on every start and could change behaviour silently.

`-ExecutionPolicy Bypass` is needed because Windows client editions default to `Restricted`. Without it PowerShell refuses to load the script and exits immediately, NSSM restarts it on that exit, and the loop leaves nothing in the log — the script never gets far enough to open it.

Run it as the account that registered the distro. Do not use `LocalSystem` — distro registrations are per user:

```powershell
$cred = Get-Credential -UserName ".\<username>" -Message "WSL_AUTOSTART service account"
& $nssm set WSL_AUTOSTART ObjectName $cred.UserName $cred.GetNetworkCredential().Password
```

Do not point `AppStdout` or `AppStderr` at the shared log. The script writes there itself, and NSSM would become a second, uncoordinated writer.

### Attaching disks

No disks are attached by default. To attach disk 1, or disks 0 and 1:

```powershell
& $nssm set WSL_AUTOSTART AppParameters "-NoProfile -ExecutionPolicy Bypass -F `"$script`" -PhysicalDrives `"1`""
& $nssm set WSL_AUTOSTART AppParameters "-NoProfile -ExecutionPolicy Bypass -F `"$script`" -PhysicalDrives `"0,1`""
```

`PhysicalDrives` takes one comma- or semicolon-separated string. Whitespace is trimmed, duplicates are dropped, and non-integer values are rejected.

**Quote the value.** Under `powershell.exe -File` the argument arrives as one literal string, so a space inside an unquoted value truncates it: `-PhysicalDrives 0, 1` reaches the script as `0,` and attaches only disk 0. From an interactive session the same unquoted value is parsed as a PowerShell array and joined into `0 1`, which fails validation.

## Backup

The script needs an elevated session, or a scheduled task set to run with highest privileges — `Stop-Service` and `Optimize-VHD` both refuse otherwise. Without elevation the run stops at the first `Stop-Service`, before anything has been stopped or shut down, so there is nothing to clean up.

**Start it from the Windows side, never from a shell inside WSL.** `wsl --shutdown` destroys the VM that shell lives in, taking the `powershell.exe` underneath it along, so the script dies partway and its `finally` block never restores the services. Closing the window mid-run does the same; `Ctrl+C` does not, since `finally` still runs.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\<username>\wsl\scripts\wsl_backup.ps1"
```

| Parameter | Default | Description |
| --- | --- | --- |
| `WslDistroName` | Lowercase computer name | Distro name, also the VHDX path |
| `SuppressServices` | `WSL_AUTOSTART` | Services to stop, in stop order; comma- or semicolon-separated |
| `ArchiveDirectory` | `%USERPROFILE%\wsl\backups` | Parent of the dated run directories |
| `SevenZipPath` | `7z.exe` | Path to the 7-Zip executable |
| `ArchiveVolumeSize` | `2g` | Volume size passed to `-v` |
| `CompressionLevel` | `3` | 7-Zip `-mx` level |
| `ProgressIntervalSeconds` | `60` | How often to report bytes written |

`SuppressServices` must name every service that can reach into WSL, not just the keepalive. Anything holding the distro open — an rclone mount served through it, for instance — will restart the VM mid-backup and the VHDX will never be released. Services are stopped in the given order and restarted in reverse, so put `WSL_AUTOSTART` last to bring it back first.

### What it does

1. `fstrim` the distro's root filesystem
2. Stop the listed services
3. `wsl --shutdown`
4. `Optimize-VHD -Mode Pretrimmed`
5. Compress the VHDX into 7z volumes
6. Restart the services from a `finally` block

Step 3 must be a full shutdown rather than `wsl --terminate`: a bare-attached physical disk keeps the VM alive, and with it the lock on the VHDX.

Step 4 is the only step that shrinks the file. WSL mounts the root ext4 with `discard`, so blocks are released to the virtual disk as files are deleted, but the VHDX is not sparse and its length never drops on its own. `fstrim` in step 1 is a reconciliation pass: online discard is issued asynchronously after the journal commits, and the kernel abandons it without retry on shutdown, on allocation failure and on `ENOSPC`.

`Pretrimmed` is the only compaction mode that works here, and picking another is silent rather than noisy:

| Mode | On a detached VHDX |
| --- | --- |
| `Pretrimmed` | Reclaims blocks released by `discard` or `fstrim` |
| `Retrim` | Issues retrims, reclaims nothing, **returns success** |
| `Full` / `Quick` | Need a read-only mount; degrade to `Prezeroed` / `Pretrimmed` |
| `Prezeroed` | Expects zeroed free space, which neither `discard` nor `fstrim` produces |

Measured on a 9.2 GiB VHDX immediately after `fstrim`: `Retrim` reclaimed 0 bytes, then `Pretrimmed` reclaimed 2.4 GiB. A script using `Retrim` looks like it is working while the archive grows with every run.

### Scheduled task

Register from an elevated session:

```powershell
$script = 'C:\Users\<username>\wsl\scripts\wsl_backup.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 4:00

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$cred = Get-Credential -UserName "$env:COMPUTERNAME\$env:USERNAME" `
    -Message 'WSL_BACKUP scheduled task account'

Register-ScheduledTask -TaskName 'WSL_BACKUP' `
    -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName `
    -Password $cred.GetNetworkCredential().Password `
    -RunLevel Highest
```

Pick the interval from how long the machine can be down and how much disk the archives are allowed to take, since each run costs both. Weekly is a starting point, not a recommendation:

```powershell
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Thursday -At 4:00
$trigger = New-ScheduledTaskTrigger -Daily -At 4:00
```

`-ExecutionTimeLimit` has to stay above the real runtime or Windows kills the task mid-compression. Time one manual run before settling on a value: it scales with the size of the VHDX and with `CompressionLevel`, and it grows as the distro fills up.

`-RunLevel Highest` is required. The battery settings matter more than they look: without them Windows may skip the task or kill it mid-run, and a killed run leaves the services stopped.

Changing the Windows password afterwards makes the task fail to start with `0x8007052E`, silently — the script never runs, so nothing appears in the log. Re-register the task after any password change.

Verify with one manual run rather than waiting for the schedule, which exercises the path, the password and the privileges together:

```powershell
Start-ScheduledTask WSL_BACKUP
Get-ScheduledTask WSL_BACKUP | Get-ScheduledTaskInfo
```

`LastTaskResult` of `0` means the script exited successfully; confirm the run itself in the log.

## Stopping and starting WSL by hand

There is no script for this. The sequence is short, and the middle step is the one that cannot be skipped:

```powershell
Stop-Service RCLONE -ErrorAction SilentlyContinue   # consumers first
Stop-Service WSL_AUTOSTART
wsl --shutdown

Start-Service WSL_AUTOSTART
Start-Service RCLONE -ErrorAction SilentlyContinue
```

Stopping the service alone only kills the keepalive. The VM keeps running because a bare-attached disk holds it open, the disk stays attached, and starting the service again produces `WSL_E_DISK_ALREADY_ATTACHED` — and sometimes a distro that cannot bring up its systemd user session, which only a full shutdown clears.

`wsl --shutdown` releases bare-attached disks on its own, so no separate `wsl --unmount` is needed. The disk goes from `Offline` back to `Online` on the Windows side, which is also how to confirm the shutdown finished:

```powershell
Get-Disk 1 | Select-Object Number, FriendlyName, OperationalStatus
```

## Reading the log

```text
2026-08-08 19:20:36+09:00 [INFO] [BACKUP] === wsl backup starting (host=HOST distro=server pid=17584) ===
2026-08-08 19:20:38+09:00 [INFO] [BACKUP] Stopping service 'WSL_AUTOSTART'
2026-08-08 19:20:41+09:00 [INFO] [BACKUP] Compacted: 7.11 GiB -> 6.86 GiB, reclaimed 263.0 MiB
2026-08-08 19:21:41+09:00 [INFO] [BACKUP] progress: 1 volume(s), 976.2 MiB written
2026-08-08 19:23:07+09:00 [INFO] [BACKUP] === wsl backup finished: 2 volume(s), 2.09 GiB total ===
2026-08-08 19:23:07+09:00 [INFO] [BACKUP] Starting service 'WSL_AUTOSTART'
2026-08-08 19:23:09+09:00 [INFO] [AUTOSTART] === wsl autostart starting (host=HOST user=user pid=13864) ===
2026-08-08 19:23:31+09:00 [INFO] [AUTOSTART] Distro probe: distro=server | kernel=6.6.87.2-microsoft-standard-WSL2 | systemd=running
```

Both scripts write here, serialised by a named mutex, so the two tags interleave when the backup restarts the service: `Start-Service` blocks until the service is running, and the service logs its own startup while it waits.

```bash
grep '\[BACKUP\]'   wsl.log
grep 'WSL_E_'       wsl.log
```

Reading it from Windows PowerShell needs `-Encoding UTF8`. `Get-Content` decodes a file without a BOM using the ANSI code page, which garbles non-ASCII text; the log is written without a BOM on purpose, since one would sit on the first line and break an anchored `grep`.

```powershell
Get-Content C:\Users\<username>\wsl\logs\wsl.log -Encoding UTF8 -Tail 20
```

`systemd=starting` in a probe line is a timing artifact, not a failure — the probe returns as soon as the distro answers, which can be before systemd finishes coming up. Round trips of 11 to 49 seconds have been observed on the same machine. Two values do mean trouble: `systemd=unknown`, meaning the distro answered but `systemctl` could not, and a message from `wsl.exe` about the systemd user session failing to start.

A run that was killed rather than failed ends at `Shutting down the WSL2 VM`, with no `Compacted`, no `ERROR` and no `Starting service` after it. The `finally` block never ran, so `WSL_AUTOSTART` is still stopped — start it by hand.

The log is not rotated.

## Restore

1. Download every volume from one dated directory
2. Extract the VHDX from `.7z.001` with 7-Zip
3. Place it in its destination directory and import it:

```powershell
wsl --import-in-place <DistributionName> <Directory>\<distro>.vhdx
```

Test this in an isolated directory from time to time. A successful backup log is not proof that the archive restores.

## Known limitations

- The dependencies are listed under [Requirements](#requirements) and the scripts do not re-check them at runtime. A machine missing 7-Zip or the Hyper-V module therefore gets as far as freezing WSL before it fails. The failure is clean — the `finally` block restores the services — but the downtime is wasted.
- Nothing removes old archives. Each run writes a new dated directory and they accumulate.
- `wsl --mount` failures are logged and otherwise ignored, deliberately: an already attached disk, missing elevation and a disk Windows will not release all exit `-1`, and none is fixed by restarting the service. The reason is in the log, from `wsl.exe` itself.
- 7-Zip's output only reaches the log when it fails, and it arrives at exit rather than during the run, because 7-Zip fully buffers stdout when it is not writing to a terminal.

## License

MIT. See [LICENSE](LICENSE).
