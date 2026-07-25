#Requires -Version 5.1
<#
    Keeps Nova Bridge alive by polling /health and calling start-bridge.ps1
    when it is down. Also starts kick-listener.ps1 (default :8788) so the
    Nova app can restart the bridge even when :8787 is hung or dead.

    Intended to run as a hidden, long-lived Task Scheduler job
    (see install-bridge-watchdog.ps1).

    Does not require admin. Runs as the logged-in user so gh/git keyring auth
    still works when the bridge is restarted.
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 30,
    [int]$HealthTimeoutSeconds = 3,
    [int]$RestartCooldownSeconds = 45
)

$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$logDir = Join-Path $root "logs"
$startScript = Join-Path $scriptDir "start-bridge.ps1"
$kickScript = Join-Path $scriptDir "kick-listener.ps1"
$pidFile = Join-Path $logDir "watchdog.pid"
$kickPidFile = Join-Path $logDir "kick.pid"
$logFile = Join-Path $logDir "watchdog.log"
$kickFlag = Join-Path $logDir "bridge.kick"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-WatchLog([string]$Message) {
    $line = "{0:u} {1}" -f (Get-Date).ToUniversalTime(), $Message
    Add-Content -Path $logFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
}

function Get-EnvValue([string]$Key) {
    $envFile = Join-Path $root ".env"
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in Get-Content $envFile) {
        if ($line -match ("^\s*" + [regex]::Escape($Key) + "\s*=\s*(.*)$")) {
            $value = $Matches[1].Trim()
            if (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            ) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return $null
}

function Get-BridgePort {
    $fromEnv = Get-EnvValue "PORT"
    if ($fromEnv -match '^\d+$') { return [int]$fromEnv }
    return 8787
}

function Get-KickPort {
    $fromEnv = Get-EnvValue "NOVA_BRIDGE_KICK_PORT"
    if ($fromEnv -match '^\d+$') { return [int]$fromEnv }
    return 8788
}

function Test-BridgeHealthy([int]$Port) {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec $HealthTimeoutSeconds
        return ($health.ok -eq $true -and $health.service -eq "nova-bridge")
    } catch {
        return $false
    }
}

function Restart-BridgeNow([string]$Reason) {
    Write-WatchLog "Restart requested ($Reason) via start-bridge.ps1"
    try {
        $startArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$startScript`""
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $startArgs -Wait -PassThru -WindowStyle Hidden
        $exit = $proc.ExitCode
        if ($exit -eq 0 -and (Test-BridgeHealthy -Port (Get-BridgePort))) {
            Write-WatchLog "Bridge restarted successfully ($Reason)."
            return $true
        }
        Write-WatchLog "Restart finished with exit=$exit but health still failing ($Reason)."
        return $false
    } catch {
        Write-WatchLog "Restart threw ($Reason): $($_.Exception.Message)"
        return $false
    }
}

function Stop-KickListener {
    if (Test-Path $kickPidFile) {
        $old = Get-Content $kickPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($old -match '^\d+$') {
            Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $kickPidFile -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -match 'kick-listener\.ps1') } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Start-KickListenerProcess([int]$KickPort, [string]$Token) {
    if (-not (Test-Path $kickScript)) {
        Write-WatchLog "kick-listener.ps1 missing; app kick disabled."
        return
    }
    Stop-KickListener
    $env:NOVA_BRIDGE_KICK_TOKEN = $Token
    $argList = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$kickScript`"",
        "-KickPort", "$KickPort",
        "-FlagPath", "`"$kickFlag`"",
        "-LogPath", "`"$logFile`""
    )
    $proc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $argList `
        -WindowStyle Hidden `
        -PassThru
    $proc.Id | Out-File -FilePath $kickPidFile -Encoding ascii -Force
    Write-WatchLog "Kick listener started (PID $($proc.Id)) on :$KickPort"
}

if (-not (Test-Path $startScript)) {
    Write-WatchLog "FATAL: start-bridge.ps1 missing at $startScript"
    exit 1
}

# Single-instance guard: replace a stale watchdog, refuse a live one.
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -match '^\d+$') {
        $existing = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
        if ($existing -and $existing.Id -ne $PID) {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue).CommandLine
            if ($cmd -and ($cmd -match 'watchdog-bridge\.ps1')) {
                Write-WatchLog "Another watchdog already running (PID $oldPid); exiting."
                exit 0
            }
            Write-WatchLog "Stale watchdog.pid pointed at PID $oldPid (not watchdog); replacing."
            Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
        }
    }
}
$PID | Out-File -FilePath $pidFile -Encoding ascii -Force

$port = Get-BridgePort
$kickPort = Get-KickPort
$token = Get-EnvValue "NOVA_BRIDGE_TOKEN"
if (-not $token) { $token = "" }

Remove-Item $kickFlag -Force -ErrorAction SilentlyContinue
Start-KickListenerProcess -KickPort $kickPort -Token $token

$lastRestartAt = [datetime]::MinValue
Write-WatchLog "Watchdog started (PID $PID, port $port, kick :$kickPort, interval ${IntervalSeconds}s)."

try {
    while ($true) {
        # Keep kick listener alive if it crashed.
        $kickAlive = $false
        if (Test-Path $kickPidFile) {
            $kp = Get-Content $kickPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($kp -match '^\d+$' -and (Get-Process -Id ([int]$kp) -ErrorAction SilentlyContinue)) {
                $kickAlive = $true
            }
        }
        if (-not $kickAlive) {
            Write-WatchLog "Kick listener missing; relaunching."
            Start-KickListenerProcess -KickPort $kickPort -Token $token
        }

        $kickRequested = Test-Path $kickFlag
        if ($kickRequested) {
            Remove-Item $kickFlag -Force -ErrorAction SilentlyContinue
            $lastRestartAt = Get-Date
            Restart-BridgeNow -Reason "app-kick"
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        if (Test-BridgeHealthy -Port $port) {
            # Sleep in short slices so an app kick is noticed quickly.
            $left = $IntervalSeconds
            while ($left -gt 0) {
                if (Test-Path $kickFlag) { break }
                $slice = [Math]::Min(2, $left)
                Start-Sleep -Seconds $slice
                $left -= $slice
            }
            continue
        }

        $sinceRestart = (Get-Date) - $lastRestartAt
        if ($sinceRestart.TotalSeconds -lt $RestartCooldownSeconds) {
            $left = $RestartCooldownSeconds - [int]$sinceRestart.TotalSeconds
            Write-WatchLog "Bridge unhealthy; cooldown ${left}s remaining."
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        Write-WatchLog "Bridge unhealthy on :$port - restarting via start-bridge.ps1"
        $lastRestartAt = Get-Date
        Restart-BridgeNow -Reason "health-fail"
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $saved = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ((Test-Path $pidFile) -and ($saved -eq "$PID")) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Stop-KickListener
    Write-WatchLog "Watchdog stopped (PID $PID)."
}
