# Freeze the WSL2 VM and compress its VHDX into multi-volume 7z files.

param(
    [string]$WslDistroName = $env:COMPUTERNAME.ToLower(),

    # Stop order; restarted in reverse. Include every service that can
    # relaunch or access WSL while the VHDX is frozen.
    [string]$SuppressServices = 'WSL_AUTOSTART',

    [string]$ArchiveDirectory = "$env:USERPROFILE\wsl\backups",

    [string]$SevenZipPath = '7z.exe',

    [string]$ArchiveVolumeSize = '2g',

    [int]$CompressionLevel = 3,

    [int]$ProgressIntervalSeconds = 60
)

# Both must run before the first write; Console.Out caches its encoding.
$env:WSL_UTF8 = 1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$today       = Get-Date -Format 'yyyyMMdd'
$vhdxPath    = "$env:USERPROFILE\wsl\distros\$WslDistroName\$WslDistroName.vhdx"
$logFile     = "$env:USERPROFILE\wsl\logs\wsl.log"
# One directory per run, so a run's volumes stay together.
$archiveDir  = "$ArchiveDirectory\$today"
$archivePath = "$archiveDir\${WslDistroName}_$today.7z"

$logEncoding = New-Object System.Text.UTF8Encoding($false)
$logMutex = New-Object System.Threading.Mutex($false, 'Global\WSL_MANAGE_LOG')

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] [BACKUP] {2}' -f
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ssK'), $Level, $Message
    $lockTaken = $false
    try {
        try {
            $lockTaken = $logMutex.WaitOne()
        } catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, $logEncoding)
    } finally {
        if ($lockTaken) {
            $logMutex.ReleaseMutex()
        }
    }
    Write-Output $line
}

# PowerShell's 1MB and 1GB are binary, hence MiB/GiB.
function Format-Size {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        '{0:N2} GiB' -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        '{0:N1} MiB' -f ($Bytes / 1MB)
    } else {
        '{0:N0} bytes' -f $Bytes
    }
}

New-Item -ItemType Directory -Force -Path $archiveDir, (Split-Path $logFile) | Out-Null

Write-Log "=== wsl backup starting (host=$env:COMPUTERNAME distro=$WslDistroName pid=$PID) ==="
Write-Log "VHDX: $vhdxPath"

# Reissues discards the kernel may have dropped. Advisory: failing here
# only costs reclaimable space.
Write-Log 'Trimming free blocks (fstrim -v /)'
wsl -d $WslDistroName -u root -- fstrim -v / 2>&1 |
    ForEach-Object { Write-Log "fstrim: $($_.ToString().Trim())" }

$serviceList = @($SuppressServices -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$stopped = @()
$failure = $null

try {
    foreach ($name in $serviceList) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Log "Service '$name' not found, skipping" 'WARN'
        } elseif ($service.Status -eq 'Stopped') {
            Write-Log "Service '$name' already stopped"
        } else {
            Write-Log "Stopping service '$name'"
            Stop-Service -Name $name -ErrorAction Stop
            $stopped += $name
        }
    }

    # Not --terminate: a bare-attached disk keeps the VM alive.
    Write-Log 'Shutting down the WSL2 VM (wsl --shutdown)'
    wsl --shutdown 2>&1 |
        ForEach-Object { Write-Log "wsl.exe: $($_.ToString().Trim())" }

    # The only mode that compacts a detached VHDX. Retrim reclaims
    # nothing yet reports success; Full and Quick need a read-only mount.
    $sizeBefore = (Get-VHD -Path $vhdxPath).FileSize
    Optimize-VHD -Path $vhdxPath -Mode Pretrimmed -ErrorAction Stop
    $sizeAfter = (Get-VHD -Path $vhdxPath).FileSize
    Write-Log ('Compacted: {0} -> {1}, reclaimed {2}' -f
        (Format-Size $sizeBefore), (Format-Size $sizeAfter),
        (Format-Size ($sizeBefore - $sizeAfter)))

    Write-Log ('Compressing into {0} volumes at mx={1}, progress every {2}s' -f
        $ArchiveVolumeSize, $CompressionLevel, $ProgressIntervalSeconds)
    Remove-Item -Path "$archivePath.*" -Force -ErrorAction SilentlyContinue
    # 7-Zip buffers stdout off a terminal, so progress comes from the
    # volumes on disk. Start-Process is unusable: ExitCode stays null
    # without -Wait, and -Wait would block the progress loop.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $SevenZipPath
    $startInfo.Arguments = 'a -t7z -mx={0} -v{1} -y "{2}" "{3}"' -f
        $CompressionLevel, $ArchiveVolumeSize, $archivePath, $vhdxPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $sevenZip = [System.Diagnostics.Process]::Start($startInfo)

    # Must be drained or the pipes fill and 7-Zip stalls mid-archive.
    $sevenZipOut = $sevenZip.StandardOutput.ReadToEndAsync()
    $sevenZipErr = $sevenZip.StandardError.ReadToEndAsync()

    # WaitForExit is false on timeout, true on exit. One more pass after
    # it exits, otherwise the final interval goes unreported.
    do {
        $exited = $sevenZip.WaitForExit($ProgressIntervalSeconds * 1000)
        $written = @(Get-ChildItem -Path "$archivePath.*" -ErrorAction SilentlyContinue)
        Write-Log ('progress: {0} volume(s), {1} written' -f
            $written.Count,
            (Format-Size ($written | Measure-Object -Property Length -Sum).Sum))
    } while (-not $exited)

    # Logged only on failure; on success it repeats what is already here.
    if ($sevenZip.ExitCode -ne 0) {
        ($sevenZipOut.Result, $sevenZipErr.Result) -join "`n" -split "`r?`n" |
            ForEach-Object {
                $text = $_.Trim()
                if ($text) {
                    Write-Log "7z: $text" 'WARN'
                }
            }
        throw "7-Zip exited with $($sevenZip.ExitCode). The VHDX itself is untouched."
    }

    # Before the services return, or autostart's own lines split this
    # block: Start-Service waits until the service starts logging.
    $volumes = @(Get-ChildItem -Path "$archivePath.*" | Sort-Object Name)
    $total = ($volumes | Measure-Object -Property Length -Sum).Sum

    # All volumes but the last are exactly -v bytes.
    if ($volumes.Count -eq 1) {
        Write-Log ('volume: {0}, {1}' -f $volumes[0].Name, (Format-Size $volumes[0].Length))
    } else {
        Write-Log ('volumes: {0}-{1}, {2} each, last {3}' -f
            $volumes[0].Name, ($volumes[-1].Name -replace '.*\.', ''),
            (Format-Size $volumes[0].Length), (Format-Size $volumes[-1].Length))
    }
    Write-Log ('=== wsl backup finished: {0} volume(s), {1} total ===' -f
        $volumes.Count, (Format-Size $total))
} catch {
    $failure = $_
} finally {
    # Restore the keepalive before its consumers, even after a failure.
    [array]::Reverse($stopped)

    # All the log lines first, then the calls, for the same reason.
    foreach ($name in $stopped) {
        Write-Log "Starting service '$name'"
    }
    foreach ($name in $stopped) {
        try {
            Start-Service -Name $name -ErrorAction Stop
        } catch {
            Write-Log "MANUAL ACTION REQUIRED: run  Start-Service $name  -- $_" 'ERROR'
        }
    }
}

if ($failure) {
    Write-Log "$failure" 'ERROR'
    Write-Log '=== wsl backup failed ===' 'ERROR'
    exit 1
}
