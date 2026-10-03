# Attach physical disks and keep the default WSL distro running under NSSM.
# A distro that never settles exits non-zero instead of being kept alive.
# See README.md for setup, parameters, logs, and troubleshooting.

param(
    [string]$PhysicalDrives = ''
)

# Keep WSL output and the shared log in UTF-8.
$env:WSL_UTF8 = 1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# The autostart and backup scripts share this log without interleaving lines.
$logFile = "$env:USERPROFILE\wsl\logs\wsl.log"
$logTag = 'AUTOSTART'
$logEncoding = New-Object System.Text.UTF8Encoding($false)
$logMutex = New-Object System.Threading.Mutex($false, 'Global\WSL_MANAGE_LOG')

New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

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
            # A holder died without releasing; the mutex is ours anyway.
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

# Bounded retry for a distro that does not settle. See README.md.
$retryDelaysSeconds = @(10, 30)
$maxStartAttempts = $retryDelaysSeconds.Count + 1
$giveUpHoldSeconds = 60

Write-Log "=== wsl autostart starting (host=$env:COMPUTERNAME user=$env:USERNAME pid=$PID) ==="

$driveList = @()
foreach ($token in ($PhysicalDrives -split '[,;]')) {
    $token = $token.Trim()
    if ($token.Length -eq 0) {
        continue
    }

    $driveNumber = 0
    $validDriveNumber = [int]::TryParse(
        $token,
        [System.Globalization.NumberStyles]::None,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$driveNumber
    )

    if (-not $validDriveNumber) {
        Write-Log "Invalid PhysicalDrives value '$token'. Use non-negative integers separated by commas or semicolons." 'ERROR'
        exit 1
    }

    if ($driveList -notcontains $driveNumber) {
        $driveList += $driveNumber
    }
}

# Disk attachment failures are logged and startup continues.
if ($driveList.Count -eq 0) {
    Write-Log "No physical drives requested."
} else {
    Write-Log ("Physical drives requested: {0}" -f ($driveList -join ', '))
}

# Returns whether any disk was already attached, which is a fact about the
# VM rather than the disk: it means the VM outlived the last start.
function Mount-PhysicalDrives {
    param([int[]]$Drives)

    $alreadyAttached = $false
    foreach ($d in $Drives) {
        Write-Log "Attaching \\.\PHYSICALDRIVE$d --bare"
        $mounted = wsl --mount "\\.\PHYSICALDRIVE$d" --bare 2>&1 |
            ForEach-Object { $_.ToString().Trim() }
        # A service restart can find the disk still attached; report that as normal.
        if ($mounted -match 'WSL_E_DISK_ALREADY_ATTACHED') {
            Write-Log "\\.\PHYSICALDRIVE$d is already attached"
            $alreadyAttached = $true
        } else {
            $mounted | ForEach-Object { Write-Log "wsl.exe: $_" }
        }
    }

    return $alreadyAttached
}

# Wait up to one minute for systemd to settle. A distro that is degraded or
# answers late still starts; one that never answers is fatal. See README.md.
$probeScript = @(
    'set -f'
    'echo distro=$WSL_DISTRO_NAME'
    'echo kernel=$(uname -r)'
    'end=$(( $(date +%s) + 60 ))'
    'settled=yes'
    'while :'
    'do s=$(systemctl is-system-running 2>&1)'
    'case $s in running|degraded|maintenance|stopping|offline) break ;; esac'
    '[ $(date +%s) -ge $end ] && { settled=no; break; }'
    'sleep 2'
    'done'
    'echo systemd=${s:-no-answer}'
    'echo settled=$settled'
) -join '; '

# Also what starts the distro: nothing before this does.
function Test-DistroSettled {
    $probe = wsl -e sh -c $probeScript 2>&1
    $probeLine = ($probe | ForEach-Object { $_.ToString().Trim() }) -join ' | '
    # Only a fully running systemd state is logged as healthy.
    $level = if ($probeLine -match 'systemd=running') { 'INFO' } else { 'WARN' }
    Write-Log "Distro probe: $probeLine" $level

    # Only settled=no is a failure; degraded means systemd answered.
    return ($probeLine -match 'settled=yes')
}

# Attach and probe as one unit: wsl --shutdown releases the bare disks along
# with the VM, so a retry that only probed would boot the distro without them.
$settled = $false
for ($attempt = 1; $attempt -le $maxStartAttempts; $attempt++) {
    if ($attempt -gt 1) {
        Write-Log ("Distro start attempt {0} of {1}" -f $attempt, $maxStartAttempts)
    }

    $vmWasLive = Mount-PhysicalDrives $driveList

    if (Test-DistroSettled) {
        $settled = $true
        break
    }

    if ($attempt -eq $maxStartAttempts) {
        break
    }

    # Restarting into the same live VM is what failed; clear it first.
    $why = if ($vmWasLive) {
        'the VM was still up from the last start'
    } else {
        'the VM was started fresh'
    }
    $delay = $retryDelaysSeconds[$attempt - 1]
    Write-Log ("Distro did not settle and {0}; clearing the VM with wsl --shutdown, retrying in {1}s" -f
        $why, $delay) 'WARN'
    wsl --shutdown 2>&1 | ForEach-Object { Write-Log "wsl.exe: $($_.ToString().Trim())" }
    Start-Sleep -Seconds $delay
}

if (-not $settled) {
    # Refuse to hold a keepalive over a distro with no systemd: NSSM and
    # Windows would both call that healthy. The hold throttles the restart,
    # which NSSM would otherwise make immediately. See README.md.
    Write-Log ("=== wsl autostart failed: no settled distro after {0} attempts, holding {1}s then exiting for NSSM to restart ===" -f
        $maxStartAttempts, $giveUpHoldSeconds) 'ERROR'
    Start-Sleep -Seconds $giveUpHoldSeconds
    exit 1
}

# Keep this foreground command blocking so NSSM can supervise WSL.
Write-Log "=== wsl autostart keepalive wsl -- sleep infinity ==="
$startedAt = Get-Date
wsl -- sleep infinity 2>&1 |
    ForEach-Object { Write-Log "wsl.exe: $($_.ToString().Trim())" }
$uptime = (Get-Date) - $startedAt

# Reaching this point means NSSM will restart the service.
Write-Log ("=== wsl autostart keepalive exited after {0}, NSSM restarts the service ===" -f
    $uptime.ToString('d\.hh\:mm\:ss')) 'WARN'
