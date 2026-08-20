# wslmass

**WSL** **Ma**nagement **S**cript**s** — for running a WSL2 distro as an always-on server on Windows: one keeps the VM up and attaches dedicated physical disks to it, the other takes a consistent backup of the VHDX with controlled downtime.

- **`wsl_autostart.ps1`** runs under NSSM. It attaches bare physical disks, starts the default distro, and holds it open.
- **`wsl_backup.ps1`** runs from Task Scheduler. It stops the services that touch WSL, shuts the VM down, compacts the VHDX, compresses it into multi-volume 7z files and hands them to rclone.

Both append to one shared log, `%USERPROFILE%\wsl\logs\wsl.log`.

## Requirements

- Windows 10/11 with WSL2, and a distro with systemd enabled
- Windows PowerShell 5.1
- The Hyper-V PowerShell module, for `Get-VHD` and `Optimize-VHD`
- [NSSM](https://nssm.cc/), to supervise the keepalive
- [7-Zip](https://www.7-zip.org/), for the backup
- [rclone](https://rclone.org/) with a configured remote, for the upload

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

### Installing rclone

```powershell
winget install --id Rclone.Rclone -e --accept-source-agreements --accept-package-agreements
```

This one needs no `PATH` work. rclone is published as a portable zip package, so winget unpacks it and writes a symlink into `%LOCALAPPDATA%\Microsoft\WinGet\Links`, adding that directory to the user `PATH` if it is not there already — visible to sessions started afterwards:

```powershell
where.exe rclone.exe
rclone version
```

`--scope machine` puts the link in `%ProgramFiles%\WinGet\Links` and on the machine `PATH` instead. Either works as long as the scheduled task's account resolves it. That is also the account that has to own the rclone configuration, so install and run `rclone config` as that account; otherwise pass `-RclonePath "…\WinGet\Links\rclone.exe"` per run.

Without winget, download the zip from <https://rclone.org/downloads/> and unpack it anywhere: rclone is one static binary, no installer, no registry entries.

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
│   └── <distro>\
│       └── <yyyymmdd>\
└── scripts\
    ├── wsl_autostart.ps1
    └── wsl_backup.ps1
```

The distro directory and its VHDX both take the distro name, and `wsl_backup.ps1` derives the path from it. A distro named `server` lives at `%USERPROFILE%\wsl\distros\server\server.vhdx`.

`backups` stages one dated directory per distro per run and is removed once rclone has the archive, so it normally holds a whole archive only while a run is in flight or after one has failed. It can also remain after a successful upload if local cleanup fails; the next run removes either kind of leftover before it starts compressing. The destination has the same shape:

```text
<RcloneRemote>/
└── <distro>/
    └── <yyyymmdd>/
        ├── <distro>_<yyyymmdd>.7z.001
        ├── <distro>_<yyyymmdd>.7z.002
        └── <distro>_<yyyymmdd>.manifest.json
```

The distro level is not decoration. The upload syncs a directory and then deletes it wholesale, so two distros backed up on one machine on the same day have to stage separately: sharing a dated directory would make each run upload the other's volumes and then delete them.

A rerun on the same day reuses the same names — the volumes carry the date and nothing else — and rclone cannot tell two compressions apart. It compares sizes when the destination offers nothing better, and a WebDAV destination offers neither modification times nor hashes. Every volume but the last is exactly `-v` bytes, so leftovers from an earlier compression look unchanged and are kept: a rerun uploads the last volume and leaves the first one from the earlier compression in place.

So the upload goes beside the dated directory and is moved into place at the end:

```text
rclone sync   <staging>                     ->  <distro>/<yyyymmdd>.incoming
rclone purge  <distro>/<yyyymmdd>
rclone move   <distro>/<yyyymmdd>.incoming  ->  <distro>/<yyyymmdd>
```

`.incoming` is cleared before each upload, for the same reason the dated directory would need to be: an earlier attempt's leftovers would be skipped rather than replaced. Both clears first ask `rclone lsf` whether the directory is there, and only exit `3`, directory not found, is read as an answer: an unreachable destination exits `5`, and taking that for an empty directory would skip the clearing at the one moment there is something to clear. The purge and the move are metadata operations, so the date is without a complete archive only between those two lines rather than for the length of an upload — which matters as soon as uploads fail sometimes. They did here often enough that an earlier version purged a good archive and then failed to replace it, before the cause was found in the destination's own configuration.

The upload itself is a plain `rclone sync`. Whatever an attempt lands stays landed and is skipped on the next one, so the attempts accumulate rather than restart, which is what lets an unreliable destination converge. `--ignore-times` would also answer the size comparison and is the one flag `RcloneUploadOptions` must not carry: it would make every attempt re-send everything and take that away.

The flags are a parameter rather than a decision the script makes. The default is `--transfers 1 --timeout 999m`: one file at a time, and rclone's five-minute idle timeout effectively disabled, since a destination that stores each volume before answering goes minutes without sending anything and would otherwise be cut off mid-transfer. Retries stay at rclone's default of three. `--stats`, `--stats-one-line` and `--stats-log-level` are not part of it: the `waiting on the destination` reporting parses those lines, so their interval comes from `ProgressIntervalSeconds` and their shape is fixed.

That skipping makes `ArchiveVolumeSize` a cost setting more than a reliability one. The unit of loss is one volume: a slice that misses its deadline costs the whole volume again, because rclone re-sends the file. What the volume size does not change is how often that happens, since the archive is cut into the same number of slices however it is divided into volumes — halving the volume halves the price of a failure without making one less likely. Observed before the slice size was found: the same run failed the same way at `1g` and at `512m`. Smaller volumes still buy a cheaper retry and finer progress; `1g` trades that against a directory of hundreds of files.

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
  -File "C:\Users\<username>\wsl\scripts\wsl_backup.ps1" `
  -RcloneRemote "dav:backups/wsl"
```

| Parameter | Default | Description |
| --- | --- | --- |
| `RcloneRemote` | none | Upload destination as `remote:path`; required unless `-SkipUpload` |
| `SkipUpload` | off | Compress and hash only, leaving the archive in `ArchiveDirectory` |
| `WslDistroName` | Lowercase computer name | Distro name, also the VHDX path |
| `SuppressServices` | `WSL_AUTOSTART` | Services to stop, in stop order; comma- or semicolon-separated |
| `ArchiveDirectory` | `%USERPROFILE%\wsl\backups` | Parent of the dated run directories |
| `SevenZipPath` | `7z.exe` | Path to the 7-Zip executable |
| `RclonePath` | `rclone.exe` | Path to the rclone executable |
| `ArchiveVolumeSize` | `1g` | Volume size passed to `-v` |
| `CompressionLevel` | `3` | 7-Zip `-mx` level |
| `RcloneUploadOptions` | `--transfers 1 --timeout 999m` | Flags passed to the upload's `rclone sync`, split on whitespace |
| `ProgressIntervalSeconds` | `60` | How often to report bytes written, and rclone's `--stats` interval; 1 to 3600 |
| `DestinationWaitSeconds` | `300` | How long the upload waits for the destination to answer |

`SuppressServices` must name every service that can reach into WSL, not just the keepalive. Anything holding the distro open — an rclone mount served through it, for instance — will restart the VM mid-backup and the VHDX will never be released. Services are stopped in the given order and restarted in reverse, so put `WSL_AUTOSTART` last to bring it back first.

### The rclone remote

The script knows nothing about the protocol or the credentials. It passes `remote:path` to rclone and reads the exit code, so any backend rclone speaks works as a destination. Configure it once per machine:

```powershell
rclone config          # n) New remote -> pick a backend -> answer its prompts
rclone lsd dav:backups/wsl
```

`rclone.conf` lives under `%USERPROFILE%\AppData\Roaming\rclone`, so the scheduled task has to run as the account that created it — which it already has to, being the account that registered the distro.

Passwords in `rclone.conf` are obscured rather than encrypted, and `rclone config show` prints them back in the clear. Do not put a config password on the file either: an unattended run has no one to type it, and rclone waits at the prompt until the task's time limit kills it. Give the remote's account write access to the backup path and nothing else.

The destination may be served by the distro being backed up, which on a slow link is often the fastest option. It is down for the whole compression step, but the upload only starts once the services are back, and the script waits for the destination to answer first.

Bear in mind that a server inside the distro does not remove a slow link, it moves it: the fast hop is rclone to that server, which then has to reach whatever is behind it, from inside a request rclone is waiting on. Such a destination also fails in ways that do not describe themselves — one answered `405 Method Not Allowed` to uploads it had simply been unable to finish. Read its own log before believing the status code. In that case the log named a slice upload missing its deadline, and both halves of that were the destination's own settings rather than anything about the link: every slice got the same 60 seconds, while a separate switch decided whether a slice was 4 MiB or eight times that. Setting it removed the failures entirely. A destination that does the real work inside the request has tuning of its own, and it is worth reading before concluding the link is at fault.

That wait is doing real work. rclone's `--retries` does not cover a destination it cannot reach: a WebDAV backend reads metadata while the file system object is constructed, before the operation the retries apply to, so rclone exits immediately however many are asked for. Measured on one machine, the upload started 8 seconds after `Start-Service` returned and the distro first answered 6 seconds later — enough to fail the whole run.

### What it does

1. `rclone mkdir` the distro's remote directory
2. Remove the staging directories of earlier runs, this run's own excepted
3. `fstrim` the distro's root filesystem
4. Stop the listed services
5. `wsl --shutdown`
6. `Optimize-VHD -Mode Pretrimmed`
7. Compress the VHDX into 7z volumes
8. Hash the volumes into a manifest next to them
9. Restart the services from a `finally` block
10. Wait for the destination to answer
11. `rclone sync` the whole directory into `<yyyymmdd>.incoming`
12. Replace the dated directory with it, by purge and move
13. Delete the local directory
14. Remove any `<yyyymmdd>.incoming` an earlier run abandoned

`-SkipUpload` drops steps 1 and 10 to 14. Everything that touches the VHDX is unchanged — the same downtime, the same compaction, the same volumes, and the manifest of step 8 written beside them — and the run ends with the archive in its dated directory under `ArchiveDirectory`, which the finishing line names in place of the remote. `RcloneRemote` is not used, so no remote need be configured to run this way.

Step 2 still runs, so consecutive `-SkipUpload` runs do not pile up: each clears the dated directories before it and leaves the one it just made. `ArchiveDirectory` holds the latest archive and nothing older, the same bound as when the upload is on.

Step 1 comes before anything is stopped, so a wrong remote, an expired password or a server that is down costs no downtime at all. It creates rather than lists because write access is what the upload needs, and `rclone mkdir` on an existing directory succeeds. It creates the distro's directory rather than this run's, so a failure later leaves no empty dated directory behind — `rclone sync` creates that one itself.

Step 2 is what keeps the local disk bounded, and where it sits is the whole of it. What it removes are the dated directories of runs whose upload never finished; each holds an archive of an older VHDX than the one about to be compressed, and that VHDX is still on disk, so they are the only copy of nothing. This run's own directory is left alone — that one may still be worth finishing by hand. Sweeping here rather than after the upload is what makes the bound hold: the space those directories hold is the space the compression is about to need, and a run that fails for want of it never reaches the upload, so a sweep placed there would never run again either.

Step 5 must be a full shutdown rather than `wsl --terminate`: a bare-attached physical disk keeps the VM alive, and with it the lock on the VHDX.

Step 6 is the only step that shrinks the file. WSL mounts the root ext4 with `discard`, so blocks are released to the virtual disk as files are deleted, but the VHDX is not sparse and its length never drops on its own. `fstrim` in step 3 is a reconciliation pass: online discard is issued asynchronously after the journal commits, and the kernel abandons it without retry on shutdown, on allocation failure and on `ENOSPC`.

Step 8 is inside the downtime on purpose. Measured across thirteen runs, it costs 6 to 11 seconds against a compression of two minutes, and buys an archive and the manifest describing it produced under one freeze, in a `[BACKUP]` block the autostart service's own startup lines do not run through.

Steps 10 to 14 run with the services already back, so the distro is down for the compression and the hashing only and not for the upload, which is the longer half on a slow link. Step 10 is what makes a destination inside the distro workable: the services returning does not mean the distro has finished booting, let alone that whatever serves the destination has started.

Step 13 happens only after rclone exits zero, having compared every transferred file against its source. A staging directory usually means the upload did not finish, in which case the sync can be repeated by hand without recompressing anything. It can also remain after a successful upload if local cleanup fails; that case is logged as a warning and the remote dated directory is already complete. The next run clears either kind of leftover in step 2.

Step 14 clears the `.incoming` directories that earlier failed runs left up there. The point is less the disk it frees than what it guarantees: a dated directory on the destination is always a whole archive, never a half-finished upload under a similar name. Anything reading the destination later, a retention pass included, can take that for granted. A purge failure is logged rather than thrown because the backup is already safe; if the directory listing itself fails, it yields nothing to sweep and also leaves the successful run alone.

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
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -RcloneRemote `"dav:backups/wsl`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 4:00

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -MultipleInstances IgnoreNew `
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

`-ExecutionTimeLimit` has to stay above the real runtime or Windows kills the task, now mid-compression or mid-upload. Eight hours leaves room for the longest run observed here: 29 minutes to compress and hash 37.25 GiB, followed by 4 hours 21 minutes of upload, 4 hours 51 minutes in all. Time one manual run before settling on a value of your own; compression scales with the VHDX and `CompressionLevel`, while the upload scales with the archive and the link. A kill during the upload is the milder of the two — the services are already back — but it leaves a half-written directory on the server that the next run replaces.

`-MultipleInstances IgnoreNew` makes the one-run-at-a-time policy explicit: if this same task is triggered while its previous run is still active, Task Scheduler ignores the new trigger. This is already the Task Scheduler default, but stating it here prevents a later settings change from letting two runs share the same dated staging and destination directories. It applies to this registered task only, not to a separate task or a direct invocation of the script.

`-RunLevel Highest` is required. The battery settings matter more than they look: without them Windows may skip the task or kill it mid-run, and a killed run leaves the services stopped.

`-User` with `-Password` rather than a `-Principal` with `-LogonType S4U`. S4U needs no stored password and may well be enough now that rclone authenticates with its own credentials, but it has not been tested here, and an S4U token grants no network credentials at all — the kind of thing that fails only at upload time. The cost of the tested arrangement is that changing the Windows password afterwards makes the task fail to start with `0x8007052E`, silently — the script never runs, so nothing appears in the log. Re-register the task after any password change. An account with no password at all cannot use this logon type.

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
2026-08-08 19:23:07+09:00 [INFO] [BACKUP] volumes: server_20260808.7z.001-003, 1.00 GiB each, last 92.4 MiB
2026-08-08 19:23:07+09:00 [INFO] [BACKUP] Starting service 'WSL_AUTOSTART'
2026-08-08 19:23:09+09:00 [INFO] [AUTOSTART] === wsl autostart starting (host=HOST user=user pid=13864) ===
2026-08-08 19:23:31+09:00 [INFO] [AUTOSTART] Distro probe: distro=server | kernel=6.6.87.2-microsoft-standard-WSL2 | systemd=running | settled=yes
2026-08-08 19:24:02+09:00 [INFO] [BACKUP] Uploading C:\Users\user\wsl\backups\server\20260808 to dav:backups/wsl/server/20260808.incoming
2026-08-08 19:25:02+09:00 [INFO] [BACKUP] rclone: 1.021 GiB / 2.090 GiB, 49%, 17.428 MiB/s, ETA 1m2s (xfr#0/4)
2026-08-08 19:28:02+09:00 [INFO] [BACKUP] waiting on the destination: 2.090 GiB / 2.090 GiB, 100% sent (xfr#2/4), nothing moving for 2m
2026-08-08 19:31:55+09:00 [INFO] [BACKUP] === wsl backup finished 3 volume(s), 2.09 GiB at dav:backups/wsl/server/20260808 ===
```

Both scripts write here, serialised by a named mutex, so the two tags interleave when the backup restarts the service: `Start-Service` blocks until the service is running, and the service logs its own startup while it waits.

The distro probe waits up to 60 seconds for systemd to leave a transitional state. `settled=yes` means it reached a terminal state within that window; `settled=no` means the line carries the last status, or `no-answer`, after the deadline. Only `systemd=running` is logged at `INFO`; every other result is a warning.

`waiting on the destination` is not a stall to worry about. rclone counts a byte as transferred once it has gone into the request, so against a destination that writes the data on to storage of its own before answering, the transfer finishes long before the upload does — and rclone, having nothing left to send, reports a rate that decays to `0 B/s`. The script recognises a figure that has not moved since the previous interval and says so, with how long it has been that way, rather than repeating a stopped meter. What rclone writes goes into the log as written, minus its own timestamp and level: the timestamp because the log line carries one already, the level because it belongs in the log line's level field, where an rclone error reads as `[ERROR]` and can be grepped as one. The comparison includes rclone's `xfr#` counter when it prints one, and that counter is the honest meter: the percentage counts bytes handed to a request, `xfr#` counts files the far end has taken, so `100%, (xfr#2/4)` means two files are actually stored. Either moving counts as progress. Its denominator is rclone's running count of files still in scope rather than the archive's file count — it shrinks on a failure and grows back when a retry re-queues one. `--transfers 1` is the default for the same reason: one file at a time, the percentage advances as files actually arrive instead of reaching 100% while most of them are still being written at the far end.

rclone emits its retry summary at `ERROR` level after an earlier attempt failed, even when a later attempt recovers it, so a successful run can contain a line such as `[ERROR] rclone: Attempt 2/3 succeeded`. rclone still exits zero after the recovery. Judge the run by its final `wsl backup finished` or `wsl backup failed` banner and by the scheduled task's `LastTaskResult`, not by the presence of any one `[ERROR]` line.

The one reading that settles whether such a wait is work or a hang is not in this log at all. Watch the interface counters inside the distro:

```bash
cat /sys/class/net/eth0/statistics/tx_bytes   # again ten seconds later
```

Growing means the destination is still sending the archive onwards. That check goes around the whole toolchain and is worth more than anything the log can say.

```bash
grep '\[BACKUP\]'   wsl.log
grep 'WSL_E_'       wsl.log
```

Reading it from Windows PowerShell needs `-Encoding UTF8`. `Get-Content` decodes a file without a BOM using the ANSI code page, which garbles non-ASCII text; the log is written without a BOM on purpose, since one would sit on the first line and break an anchored `grep`.

```powershell
Get-Content C:\Users\<username>\wsl\logs\wsl.log -Encoding UTF8 -Tail 20
```

`systemd=starting | settled=no` means the distro was still in that transitional state after the full minute, while `systemd=no-answer | settled=no` means `systemctl` never returned a status. A message from `wsl.exe` before the labelled fields is a separate problem, such as the systemd user session failing to start, even if the fields after it eventually settle.

A run that was killed rather than failed ends at `Shutting down the WSL2 VM`, with no `Compacted`, no `ERROR` and no `Starting service` after it. The `finally` block never ran, so `WSL_AUTOSTART` is still stopped — start it by hand.

The log is not rotated and survives script upgrades. Older blocks can therefore retain retired probe or banner formats; the examples above describe the current scripts.

## Restore

1. Download every volume and the manifest from one dated directory
2. Check each volume's size and SHA-256 against the manifest
3. Extract the VHDX from `.7z.001` with 7-Zip
4. Place it in its destination directory and import it:

```powershell
wsl --import-in-place <DistributionName> <Directory>\<distro>.vhdx
```

The manifest carries the hashes, the volume sizes and a `restoreHint` with this command spelled out for the distro it came from:

```json
{
  "distro": "server",
  "date": "20260808",
  "createdUtc": "2026-08-08T10:23:41.5120000Z",
  "volumeSize": "1g",
  "sevenZipLevel": 3,
  "parts": [
    { "name": "server_20260808.7z.001", "bytes": 1073741824, "sha256": "..." },
    { "name": "server_20260808.7z.002", "bytes": 1073741824, "sha256": "..." },
    { "name": "server_20260808.7z.003", "bytes": 96912384, "sha256": "..." }
  ],
  "restoreHint": "..."
}
```

Import under a name of its own, into a directory of its own: `--import-in-place` takes ownership of the VHDX where it lies rather than copying it, so `wsl --unregister` on the throwaway name deletes that copy along with the registration.

Do this on a machine that is not hosting the live distro, or expect to restart the live one afterwards. Every WSL2 distro on a machine runs in the same VM, and a faithful copy carries the original's `fstab`, its filesystem UUIDs and its `machine-id`: booted beside its original it is not an isolated thing. Measured once, where the restore test cost the live distro its data mount — the copy's VHDX was attached and its root mounted, and three seconds later the live distro stopped the mount unit for a bare-attached disk it had been holding since the previous evening. No detach, no device-mapper removal, no I/O error: the mount was stopped rather than lost, and it stayed gone until the host was rebooted. What connects the two is not established; that they are three seconds apart with nothing else in between is.

The copy stops at `initializing` while a mount it cannot satisfy is pending, and nothing fails while it waits: `systemctl list-jobs` shows `sysinit.target` and everything behind it queued on the mount, while `list-units --state=failed` stays empty. Attaching the disk before importing, or taking the line out of the copy's `fstab`, avoids that wait.

`nofail` on the live distro turns the same hang into a boot that comes up without the mount, but whatever needed the disk then starts without it — on the machine measured here, a file server with a storage on that disk would have come up empty. `nofail` together with `RequiresMountsFor=` on the units that need the mount gets both.

Two checks establish that the copy is the original rather than merely bootable: `/etc/machine-id` matches the distro it came from, and the newest files under the user's home stop at the freeze.

Test this in an isolated directory from time to time. A successful backup log is not proof that the archive restores. Measured once, end to end, on a 2.15 GiB archive: the download needed three attempts, all volumes then matched the manifest byte for byte, 7-Zip extracted a VHDX of exactly the size the run's own `Compacted:` line had reported, and it imported and booted.

## Known limitations

- The dependencies are listed under [Requirements](#requirements) and the scripts do not re-check them at runtime. A machine missing 7-Zip or the Hyper-V module therefore gets as far as freezing WSL before it fails. The failure is clean — the `finally` block restores the services — but the downtime is wasted.
- Nothing removes old backups from the destination. Each run adds a dated directory and they accumulate; `rclone delete --min-age` on the parent path is the obvious way to add rotation.
- A failed upload is not retried beyond rclone's own retries, three by default and settable through `RcloneUploadOptions`. The staged directory is left alone, so the sync and the move after it can be repeated by hand, but re-running the script recompresses the VHDX and takes the downtime again. Finish it by hand before the next run, or not at all: that run clears the staged directory before it compresses anything.
- Nothing checks that the drive can hold the archive before the compression starts. A streak of failed uploads no longer accumulates staged archives — each run clears the ones before it — but a drive without room for one still fills up partway through a compression, after the downtime has already been taken.
- Verification only goes as far as the backend does. rclone always compares sizes, and hashes only where the remote reports them, which WebDAV does not. The SHA-256 in the manifest covers the rest, and nothing checks it until a restore.
- `wsl --mount` failures are logged and otherwise ignored, deliberately: missing elevation and a disk Windows will not release both exit `-1`, and neither is fixed by restarting the service. The reason is in the log, from `wsl.exe` itself. An already attached disk exits `-1` as well without being a failure — restarting the service leaves the VM up and the disk attached — so that case is logged as one plain line naming the drive, and carries no error code.
- 7-Zip's output only reaches the log when it fails, and it arrives at exit rather than during the run, because 7-Zip fully buffers stdout when it is not writing to a terminal.

## License

MIT. See [LICENSE](LICENSE).
