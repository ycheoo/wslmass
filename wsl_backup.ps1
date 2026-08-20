# Compact and archive a WSL2 distro, then optionally upload it with rclone.
# See README.md for setup, scheduling, restore, and troubleshooting.

param(
    [string]$RcloneRemote,

    [switch]$SkipUpload,

    [string]$WslDistroName = $env:COMPUTERNAME.ToLower(),

    [string]$SuppressServices = 'WSL_AUTOSTART',

    [string]$ArchiveDirectory = "$env:USERPROFILE\wsl\backups",

    [string]$SevenZipPath = '7z.exe',

    [string]$RclonePath = 'rclone.exe',

    [string]$ArchiveVolumeSize = '1g',

    [int]$CompressionLevel = 3,

    [string]$RcloneUploadOptions = '--transfers 1 --timeout 999m',

    [ValidateRange(1, 3600)]
    [int]$ProgressIntervalSeconds = 60,

    [int]$DestinationWaitSeconds = 300
)

# Keep WSL output and the shared log in UTF-8.
$env:WSL_UTF8 = 1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$today        = Get-Date -Format 'yyyyMMdd'
$vhdxPath     = "$env:USERPROFILE\wsl\distros\$WslDistroName\$WslDistroName.vhdx"
$logFile      = "$env:USERPROFILE\wsl\logs\wsl.log"
# Each distro has its own dated staging directory.
$archiveDir   = "$ArchiveDirectory\$WslDistroName\$today"
$archiveStem  = "$archiveDir\${WslDistroName}_$today"
$archivePath  = "$archiveStem.7z"
$manifestPath = "$archiveStem.manifest.json"

$distroRemote = "$($RcloneRemote.TrimEnd('/'))/$WslDistroName"
$destination  = "$distroRemote/$today"
$incoming     = "$destination.incoming"

$logTag = 'BACKUP'
$logEncoding = New-Object System.Text.UTF8Encoding($false)
$logMutex = New-Object System.Threading.Mutex($false, 'Global\WSL_MANAGE_LOG')

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] [{2}] {3}' -f
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ssK'), $Level, $logTag, $Message
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
    Write-Host $line
}

# Logged sizes use binary MiB and GiB units.
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

# Add rclone output to the shared log and preserve its severity.
function Invoke-Rclone {
    param(
        [switch]$ExplainStalls,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    $levels = @{
        DEBUG = 'INFO'; INFO = 'INFO'; NOTICE = 'INFO'
        WARN = 'WARN'; WARNING = 'WARN'
        ERROR = 'ERROR'; CRITICAL = 'ERROR'
    }

    # Repeated unchanged statistics are reported as destination waits.
    $progress = $null
    $progressAt = $null
    & $RclonePath @Arguments 2>&1 |
        ForEach-Object {
            $text = $_.ToString().Trim() -replace '^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d ', ''
            $level = 'INFO'
            if ($text -match '^([A-Z]+) *: *(.*)$' -and $levels.ContainsKey($Matches[1])) {
                $level = $levels[$Matches[1]]
                $text = $Matches[2].Trim()
            }
            if (-not $text) {
                return
            }
            if ($ExplainStalls -and $text -match '^([\d.]+(?: ?\w+)? / [\d.]+ ?\w+, \d+%),') {
                $figure = $Matches[1]
                $xfr = ''
                if ($text -match '\((xfr#\d+/\d+)\)$') {
                    $xfr = ' ({0})' -f $Matches[1]
                }
                if ("$figure$xfr" -eq $progress) {
                    Write-Log ('waiting on the destination: {0} sent{1}, nothing moving for {2:N0}m' -f
                        $figure, $xfr, ((Get-Date) - $progressAt).TotalMinutes)
                    return
                }
                $progress = "$figure$xfr"
                $progressAt = Get-Date
            }
            Write-Log "rclone: $text" $level
        }
    return $LASTEXITCODE
}

# Wait for destinations that are served by the WSL distro being backed up.
function Wait-Destination {
    $started  = Get-Date
    $deadline = $started.AddSeconds($DestinationWaitSeconds)
    while ($true) {
        # Failed probes are expected and stay quiet until the deadline.
        & $RclonePath lsd $distroRemote --retries 1 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log ('{0} answered after {1:N0}s' -f
                $distroRemote, ((Get-Date) - $started).TotalSeconds)
            return
        }
        if ((Get-Date) -ge $deadline) {
            throw "$distroRemote unreachable after ${DestinationWaitSeconds}s."
        }
        Start-Sleep -Seconds 5
    }
}

# Remove an existing remote directory only after confirming it is reachable.
function Clear-Destination {
    param([Parameter(Mandatory = $true)][string]$Path)

    & $RclonePath lsf $Path --retries 1 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 3) {
        return
    }
    if ($exitCode -ne 0) {
        throw "rclone cannot tell whether $Path exists (exit $exitCode)."
    }
    Write-Log "Clearing $Path"
    $exitCode = Invoke-Rclone purge $Path
    if ($exitCode -ne 0) {
        throw "rclone purge failed for $Path (exit $exitCode)."
    }
}

# Find incomplete uploads left by earlier runs.
function Get-StaleIncoming {
    & $RclonePath lsf $distroRemote --dirs-only --retries 1 2>$null |
        ForEach-Object { $_.Trim().TrimEnd('/') } |
        Where-Object { $_ -like '*.incoming' } |
        ForEach-Object { "$distroRemote/$_" }
}

# Remove older local staging before creating today's archive.
function Remove-StaleStaging {
    $staging = @(Get-ChildItem -Path (Split-Path $archiveDir) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $today })
    foreach ($stale in $staging) {
        Write-Log "Removing $($stale.FullName), staged by a run that did not finish"
        try {
            Remove-Item -Path $stale.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Log "Could not remove $($stale.FullName): $_" 'WARN'
        }
    }
}

function Get-ArchiveVolume {
    Get-ChildItem -Path "$archivePath.*" -ErrorAction SilentlyContinue | Sort-Object Name
}

function Compress-Vhdx {
    Write-Log ('Compressing into {0} volumes at mx={1}, progress every {2}s' -f
        $ArchiveVolumeSize, $CompressionLevel, $ProgressIntervalSeconds)
    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
    Remove-Item -Path "$archiveStem.*" -Force -ErrorAction SilentlyContinue

    # Compression progress is reported from the volume files written to disk.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $SevenZipPath
    $startInfo.Arguments = 'a -t7z -mx={0} -v{1} -y "{2}" "{3}"' -f
        $CompressionLevel, $ArchiveVolumeSize, $archivePath, $vhdxPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $sevenZip = [System.Diagnostics.Process]::Start($startInfo)

    $sevenZipOut = $sevenZip.StandardOutput.ReadToEndAsync()
    $sevenZipErr = $sevenZip.StandardError.ReadToEndAsync()

    do {
        $exited = $sevenZip.WaitForExit($ProgressIntervalSeconds * 1000)
        $written = @(Get-ArchiveVolume)
        Write-Log ('progress: {0} volume(s), {1} written' -f
            $written.Count,
            (Format-Size ($written | Measure-Object -Property Length -Sum).Sum))
    } while (-not $exited)

    # Detailed 7-Zip output is added only when compression fails.
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

    $volumes = @(Get-ArchiveVolume)
    # Never sync an empty staging directory because it could clear the remote.
    if (-not $volumes) {
        throw '7-Zip reported success but wrote no volumes.'
    }

    # Report the completed local archive before services restart.
    if ($volumes.Count -eq 1) {
        Write-Log ('volume: {0}, {1}' -f $volumes[0].Name, (Format-Size $volumes[0].Length))
    } else {
        Write-Log ('volumes: {0}-{1}, {2} each, last {3}' -f
            $volumes[0].Name, ($volumes[-1].Name -replace '.*\.', ''),
            (Format-Size $volumes[0].Length), (Format-Size $volumes[-1].Length))
    }

    return $volumes
}

# The manifest makes missing or damaged volumes detectable during restore.
function Write-Manifest {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Volumes)

    Write-Log "Hashing $($Volumes.Count) volume(s) for the manifest"
    $parts = foreach ($volume in $Volumes) {
        [PSCustomObject]@{
            name   = $volume.Name
            bytes  = $volume.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -Path $volume.FullName -ErrorAction Stop).Hash
        }
    }
    $manifest = [PSCustomObject]@{
        distro        = $WslDistroName
        date          = $today
        createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
        volumeSize    = $ArchiveVolumeSize
        sevenZipLevel = $CompressionLevel
        parts         = @($parts)
        restoreHint   = "Verify every volume against this manifest, extract the VHDX from the .001 volume with 7z, then run: wsl --import-in-place $WslDistroName DIR\$WslDistroName.vhdx"
    } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($manifestPath, $manifest + [Environment]::NewLine, $logEncoding)
}

function Send-Archive {
    Wait-Destination

    # Upload to a temporary .incoming directory before replacing today's backup.
    Clear-Destination -Path $incoming

    Write-Log "Uploading $archiveDir to $incoming"
    # A rerun reuses volumes already present in the .incoming directory.
    $options = @($RcloneUploadOptions -split '\s+' | Where-Object { $_ })
    $exitCode = Invoke-Rclone -ExplainStalls sync $archiveDir $incoming @options `
        --stats "${ProgressIntervalSeconds}s" --stats-one-line --stats-log-level NOTICE
    if ($exitCode -ne 0) {
        throw "rclone sync exited with $exitCode. The local volumes are kept for a rerun."
    }

    # Replace today's backup only after the new upload is complete.
    Clear-Destination -Path $destination
    $exitCode = Invoke-Rclone move $incoming $destination --delete-empty-src-dirs
    if ($exitCode -ne 0) {
        throw "rclone move exited with $exitCode. The archive is complete at $incoming and only has to be renamed to $destination."
    }

    # Local cleanup failure is a warning because the remote archive is complete.
    try {
        Remove-Item -Path $archiveDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Log "Could not remove $($archiveDir): $_" 'WARN'
    }

    # Remove incomplete uploads left by older runs after this backup is safe.
    foreach ($stale in @(Get-StaleIncoming)) {
        Write-Log "Removing $stale, uploaded by a run that did not finish"
        if ((Invoke-Rclone purge $stale) -ne 0) {
            Write-Log "Could not remove $stale" 'WARN'
        }
    }
}

New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

Write-Log "=== wsl backup starting (host=$env:COMPUTERNAME distro=$WslDistroName pid=$PID) ==="
Write-Log "VHDX: $vhdxPath"
if ($SkipUpload) {
    Write-Log "Upload skipped, the archive stays in $archiveDir"
}

$serviceList = @($SuppressServices -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$stopped = @()
$failure = $null
$restartFailed = $false

try {
    # Check remote write access before stopping any services.
    if (-not $SkipUpload) {
        if ($RcloneRemote -notmatch ':') {
            throw "RcloneRemote must name a configured remote as remote:path: '$RcloneRemote'"
        }
        Write-Log "Checking $distroRemote"
        $exitCode = Invoke-Rclone mkdir $distroRemote
        if ($exitCode -ne 0) {
            throw "rclone cannot write to $distroRemote (exit $exitCode). Nothing has been stopped."
        }
    }

    Remove-StaleStaging

    # A trim failure is non-fatal; it only reduces how much space can be reclaimed.
    Write-Log 'Trimming free blocks (fstrim -v /)'
    wsl -d $WslDistroName -u root -- fstrim -v / 2>&1 |
        ForEach-Object { Write-Log "fstrim: $($_.ToString().Trim())" }

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

    # Shut down the whole WSL2 VM so the VHDX is no longer in use.
    Write-Log 'Shutting down the WSL2 VM (wsl --shutdown)'
    wsl --shutdown 2>&1 |
        ForEach-Object { Write-Log "wsl.exe: $($_.ToString().Trim())" }

    # Compact the detached VHDX using the free blocks reported by fstrim.
    $sizeBefore = (Get-VHD -Path $vhdxPath).FileSize
    Optimize-VHD -Path $vhdxPath -Mode Pretrimmed -ErrorAction Stop
    $sizeAfter = (Get-VHD -Path $vhdxPath).FileSize
    Write-Log ('Compacted: {0} -> {1}, reclaimed {2}' -f
        (Format-Size $sizeBefore), (Format-Size $sizeAfter),
        (Format-Size ($sizeBefore - $sizeAfter)))

    $volumes = Compress-Vhdx

    # Hash the volumes before services restart so the manifest matches this archive.
    Write-Manifest -Volumes $volumes
    $total = ($volumes | Measure-Object -Property Length -Sum).Sum

    if (-not $SkipUpload) {
        Write-Log "Waiting up to ${DestinationWaitSeconds}s for $distroRemote"
    }
} catch {
    $failure = $_
} finally {
    # Restore services in reverse stop order, including after a backup failure.
    [array]::Reverse($stopped)

    # Keep restart messages together before autostart writes to the shared log.
    foreach ($name in $stopped) {
        Write-Log "Starting service '$name'"
    }
    foreach ($name in $stopped) {
        try {
            Start-Service -Name $name -ErrorAction Stop
        } catch {
            Write-Log "MANUAL ACTION REQUIRED: run  Start-Service $name  -- $_" 'ERROR'
            $restartFailed = $true
        }
    }
}

# Upload after services restart, outside the WSL downtime window.
$landed = $archiveDir
if (-not $failure -and -not $SkipUpload) {
    try {
        Send-Archive
        $landed = $destination
    } catch {
        $failure = $_
    }
}

if ($failure) {
    Write-Log "$failure" 'ERROR'
    Write-Log '=== wsl backup failed ===' 'ERROR'
    exit 1
}

Write-Log ('=== wsl backup finished {0} volume(s), {1} at {2} ===' -f
    $volumes.Count, (Format-Size $total), $landed)

# Report task failure if any service stopped by this run is still down.
if ($restartFailed) {
    Write-Log '=== wsl backup finished with services down ===' 'ERROR'
    exit 1
}
