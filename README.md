# wslmass

**WSL** **Ma**nagement **S**cript**s** — for running a WSL2 distro as an always-on server on Windows: one keeps the VM up and attaches dedicated physical disks to it, the other takes a consistent backup of the VHDX with controlled downtime.

- **`wsl_autostart.ps1`** runs under NSSM. It attaches bare physical disks, starts the default distro, and holds it open — or exits non-zero rather than hold open a distro whose systemd never came up.
- **`wsl_backup.ps1`** runs from Task Scheduler. It stops the services that touch WSL, shuts the VM down, compacts the VHDX, compresses it into multi-volume 7z files and hands them to rclone.

Both append to one shared log, `%USERPROFILE%\wsl\logs\wsl.log`.

## Requirements

- Windows 10/11 with WSL2, and a distro with systemd enabled
- Windows PowerShell 5.1 and the Hyper-V PowerShell module
- [NSSM](https://nssm.cc/), [7-Zip](https://www.7-zip.org/) and [rclone](https://rclone.org/) with a configured remote

```powershell
winget install --id 7zip.7zip -e --accept-source-agreements --accept-package-agreements
winget install --id Rclone.Rclone -e --accept-source-agreements --accept-package-agreements
```

7-Zip is not added to `PATH`; add `C:\Program Files\7-Zip` yourself or pass `-SevenZipPath` per run. Run `rclone config` as the account the scheduled task will use, since that account has to own the configuration.

Distros are registered per Windows user, so the service and the task must both run as the account that registered the distro, elevated.

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

The distro directory and its VHDX take the distro name: a distro named `server` lives at `distros\server\server.vhdx`. `wsl --import` always names the file `ext4.vhdx`, so a distro that starts from a tar gets there in five steps, in this order:

1. `wsl --import` it into a temporary directory
2. `wsl --shutdown`
3. Move its `ext4.vhdx` to `distros\server\server.vhdx`
4. `wsl --import-in-place server` that path
5. `wsl --unregister` the temporary name

`logs` and `backups` are created on first run:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\wsl\scripts"
Copy-Item wsl_autostart.ps1, wsl_backup.ps1 -Destination "$env:USERPROFILE\wsl\scripts"
```

On the destination each run becomes `<RcloneRemote>/<distro>/<yyyymmdd>/`, holding the 7z volumes and a manifest with their sizes and SHA-256 hashes. It is uploaded as `<yyyymmdd>.incoming` and renamed into place only after the upload has finished, so a half-finished upload never sits under the dated name; a `move` that fails partway is reported, and the manifest is what establishes completeness.

## Autostart

The script attaches the requested disks, starts the default distro and probes it, then runs `sleep infinity` inside it so NSSM has a process to supervise. If systemd never answers the probe, it runs `wsl --shutdown` and starts over, three attempts in all, and then exits 1 for NSSM to restart it.

The script starts whichever distro is WSL's default; pin it on any machine with more than one:

```powershell
wsl --set-default <DistributionName>
```

Find drive numbers before configuring anything, since attaching the wrong disk takes it away from Windows. The `Index` column is the number to use:

```powershell
Get-CimInstance -Query "SELECT * FROM Win32_DiskDrive" |
    Select-Object Index, Model, SerialNumber, Size, DeviceID
```

Install the service from an elevated session. `-PhysicalDrives` takes one comma-separated string and must be quoted, or `-File` truncates it at the first space:

```powershell
$nssm   = "C:\Users\<username>\nssm.exe"
$ps     = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$script = "C:\Users\<username>\wsl\scripts\wsl_autostart.ps1"

& $nssm install WSL_AUTOSTART $ps
& $nssm set WSL_AUTOSTART AppParameters "-NoProfile -ExecutionPolicy Bypass -F `"$script`" -PhysicalDrives `"1`""
& $nssm set WSL_AUTOSTART AppDirectory "C:\Windows\System32\WindowsPowerShell\v1.0"
& $nssm set WSL_AUTOSTART Start SERVICE_AUTO_START
& $nssm set WSL_AUTOSTART AppExit Default Restart

$cred = Get-Credential -UserName ".\<username>" -Message "WSL_AUTOSTART service account"
& $nssm set WSL_AUTOSTART ObjectName $cred.UserName $cred.GetNetworkCredential().Password
```

Do not use `LocalSystem`, and do not point `AppStdout` or `AppStderr` at the shared log: the script writes there itself.

## Backup

Run it elevated, and **from the Windows side, never from a shell inside WSL**: `wsl --shutdown` would kill that shell and the script with it, leaving the services stopped.

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

`SuppressServices` must name every service that can reach into WSL, not just the keepalive, or the VM restarts mid-backup and the VHDX is never released. Services stop in the given order and restart in reverse, so put `WSL_AUTOSTART` last.

Any backend rclone speaks works as a destination; the script only passes `remote:path` and reads the exit code. Do not put a config password on `rclone.conf`, since an unattended run has no one to type it. The destination may be served by the distro being backed up: the upload starts only once the services are back and the destination answers.

What a run does:

1. `rclone mkdir` the distro's remote directory, so a bad remote costs no downtime
2. Remove the staging directories of earlier runs
3. `fstrim` the distro's root filesystem
4. Stop the listed services and `wsl --shutdown`
5. `Optimize-VHD -Mode Pretrimmed`
6. Compress the VHDX into 7z volumes and hash them into a manifest
7. Restart the services from a `finally` block
8. Wait for the destination, upload, and move the dated directory into place
9. Delete the local directory

The distro is down for steps 4 to 7 only. `-SkipUpload` drops steps 1, 8 and 9 and needs no remote.

Register the task from an elevated session:

```powershell
$script = 'C:\Users\<username>\wsl\scripts\wsl_backup.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -RcloneRemote `"dav:backups/wsl`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 4:00

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$cred = Get-Credential -UserName "$env:COMPUTERNAME\$env:USERNAME" `
    -Message 'WSL_BACKUP scheduled task account'

Register-ScheduledTask -TaskName 'WSL_BACKUP' `
    -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName `
    -Password $cred.GetNetworkCredential().Password `
    -RunLevel Highest
```

Each run costs downtime and disk, so pick the interval accordingly. `-ExecutionTimeLimit` must exceed the real runtime or Windows kills the task mid-run; time one manual run first. `-StartWhenAvailable` is omitted on purpose, since a caught-up trigger would shut WSL down at an unexpected time. Changing the Windows password afterwards makes the task fail to start silently with `0x8007052E`; re-register it.

Verify with one manual run; `LastTaskResult` of `0` means the script exited successfully:

```powershell
Start-ScheduledTask WSL_BACKUP
Get-ScheduledTask WSL_BACKUP | Get-ScheduledTaskInfo
```

## Stopping and starting WSL by hand

Stopping the service alone only kills the keepalive; a bare-attached disk keeps the VM running. Shut it down in between:

```powershell
Stop-Service WSL_AUTOSTART
wsl --shutdown
Start-Service WSL_AUTOSTART
```

## Reading the log

```text
2026-08-08 19:20:36+09:00 [INFO] [BACKUP] === wsl backup starting (host=HOST distro=server pid=17584) ===
2026-08-08 19:20:41+09:00 [INFO] [BACKUP] Compacted: 7.11 GiB -> 6.86 GiB, reclaimed 263.0 MiB
2026-08-08 19:23:07+09:00 [INFO] [BACKUP] volumes: server_20260808.7z.001-003, 1.00 GiB each, last 92.4 MiB
2026-08-08 19:23:31+09:00 [INFO] [AUTOSTART] Distro probe: distro=server | kernel=6.6.87.2-microsoft-standard-WSL2 | systemd=running | settled=yes
2026-08-08 19:28:02+09:00 [INFO] [BACKUP] waiting on the destination: 2.090 GiB / 2.090 GiB, 100% sent (xfr#2/4), nothing moving for 2m
2026-08-08 19:31:55+09:00 [INFO] [BACKUP] === wsl backup finished 3 volume(s), 2.09 GiB at dav:backups/wsl/server/20260808 ===
```

- `settled=no` in the probe line means systemd never answered; the retry and `wsl --shutdown` that follow are the script working as designed.
- `waiting on the destination` means the figures have not moved since the last interval, which is normal against a destination that stores each volume before answering, and also what a hang looks like. The line cannot tell them apart; `cat /sys/class/net/eth0/statistics/tx_bytes` inside the distro, twice ten seconds apart, can. `xfr#` counts files the far end has actually taken.
- rclone logs its retry summary at `ERROR` even when a later attempt succeeds. Judge a run by its final `wsl backup finished` or `wsl backup failed` banner and by `LastTaskResult`.
- A run that ends at `Shutting down the WSL2 VM` with nothing after it was killed, and `WSL_AUTOSTART` is still stopped — start it by hand.

The file has no BOM, so from PowerShell read it with `Get-Content -Encoding UTF8`.

## Restore

Download every volume and the manifest from one dated directory, check sizes and SHA-256 against the manifest, extract the VHDX from `.7z.001` with 7-Zip, and import it under a name and directory of its own:

```powershell
wsl --import-in-place <DistributionName> <Directory>\<distro>.vhdx
```

Do this on a machine that is not hosting the live distro. A faithful copy carries the original's `fstab`, filesystem UUIDs and `machine-id`, and it is not isolated from its original. Once, three seconds after such a copy booted, the live distro's data mount was stopped and stayed gone until a reboot; the mechanism is not established, the timing is. The copy also stops at `initializing` while a mount it cannot satisfy is pending; attach the disk first or drop the line from the copy's `fstab`.

Test this from time to time. A successful backup log is not proof that the archive restores.

## Known limitations

- Dependencies are not re-checked at runtime, so a machine missing 7-Zip or the Hyper-V module freezes WSL before it fails.
- Nothing watches a mount after the distro has started, and nothing removes old backups from the destination.
- A failed upload is not retried beyond rclone's own retries. The staged directory is left for repeating by hand; the next run clears it before compressing.
- Nothing checks that the drive can hold the archive before the compression starts.
- rclone verifies hashes only where the remote reports them, which WebDAV does not; the manifest's SHA-256 is checked only at restore.
- `wsl --mount` failures are logged and otherwise ignored, since neither missing elevation nor a disk Windows will not release is fixed by a restart.

## License

MIT. See [LICENSE](LICENSE).
