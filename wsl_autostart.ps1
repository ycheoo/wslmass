# WSL2 keepalive supervised by the NSSM service WSL_AUTOSTART.
# The final foreground command must remain blocking; see README.md.

param(
    # Comma- or semicolon-separated PHYSICALDRIVE numbers. Quote the
    # value: unquoted, a stray space truncates the list silently.
    [string]$PhysicalDrives = ''
)

# Both must run before the first write; Console.Out caches its encoding.
$env:WSL_UTF8 = 1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# The backup script appends here too, hence the mutex. No BOM: it would
# land on the first line and break an anchored grep.
$logFile = "$env:USERPROFILE\wsl\logs\wsl.log"
$logEncoding = New-Object System.Text.UTF8Encoding($false)
$logMutex = New-Object System.Threading.Mutex($false, 'Global\WSL_MANAGE_LOG')

New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] [AUTOSTART] {2}' -f
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ssK'), $Level, $Message
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
    Write-Output $line
}

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

# Mount errors are logged but remain non-fatal by design.
if ($driveList.Count -eq 0) {
    Write-Log "No physical drives requested."
} else {
    Write-Log ("Physical drives requested: {0}" -f ($driveList -join ', '))
}

foreach ($d in $driveList) {
    Write-Log "Attaching \\.\PHYSICALDRIVE$d --bare"
    foreach ($line in (wsl --mount "\\.\PHYSICALDRIVE$d" --bare 2>&1)) {
        Write-Log "wsl.exe: $($line.ToString().Trim())"
    }
}

# Diagnostic only: a non-running systemd does not stop startup.
$probeScript = @(
    'echo distro=$WSL_DISTRO_NAME'
    'echo kernel=$(uname -r)'
    'echo systemd=$(systemctl is-system-running 2>/dev/null)'
) -join '; '

$probe = wsl -- sh -c $probeScript 2>&1
Write-Log ("Distro probe: {0}" -f
    (($probe | ForEach-Object { $_.ToString().Trim() }) -join ' | '))

# An explicit sleep, not a bare `wsl`: NSSM restarts on every exit, so
# the workload must not end on its own.
Write-Log "=== starting keepalive: wsl -- sleep infinity ==="
$startedAt = Get-Date
wsl -- sleep infinity 2>&1 |
    ForEach-Object { Write-Log "wsl.exe: $($_.ToString().Trim())" }
$uptime = (Get-Date) - $startedAt

# Reaching here means the keepalive died; NSSM restarts the service.
Write-Log ("keepalive exited after {0}, NSSM restarts the service" -f
    $uptime.ToString('d\.hh\:mm\:ss')) 'WARN'
