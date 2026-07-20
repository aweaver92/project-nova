#Requires -Version 5.1
<#
    Keeps Nova Bridge alive by polling /health and calling start-bridge.ps1
    when it is down. Intended to run as a hidden, long-lived Task Scheduler job
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
$pidFile = Join-Path $logDir "watchdog.pid"
$logFile = Join-Path $logDir "watchdog.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-WatchLog([string]$Message) {
    $line = "{0:u} {1}" -f (Get-Date).ToUniversalTime(), $Message
    Add-Content -Path $logFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
}

function Get-BridgePort {
    $envFile = Join-Path $root ".env"
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*PORT\s*=\s*(\d+)') { return [int]$Matches[1] }
        }
    }
    return 8787
}

function Test-BridgeHealthy([int]$Port) {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec $HealthTimeoutSeconds
        return ($health.ok -eq $true -and $health.service -eq "nova-bridge")
    } catch {
        return $false
    }
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
            Write-WatchLog "Another watchdog already running (PID $oldPid); exiting."
            exit 0
        }
    }
}
$PID | Out-File -FilePath $pidFile -Encoding ascii -Force

$port = Get-BridgePort
$lastRestartAt = [datetime]::MinValue
Write-WatchLog "Watchdog started (PID $PID, port $port, interval ${IntervalSeconds}s)."

try {
    while ($true) {
        if (Test-BridgeHealthy -Port $port) {
            Start-Sleep -Seconds $IntervalSeconds
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
        try {
            # Quote -File path so spaces in the repo folder do not break PowerShell.
            $startArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$startScript`""
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $startArgs -Wait -PassThru -WindowStyle Hidden
            $exit = $proc.ExitCode
            if ($exit -eq 0 -and (Test-BridgeHealthy -Port $port)) {
                Write-WatchLog "Bridge restarted successfully."
            } else {
                Write-WatchLog "Restart finished with exit=$exit but health still failing."
            }
        } catch {
            Write-WatchLog "Restart threw: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $saved = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ((Test-Path $pidFile) -and ($saved -eq "$PID")) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Write-WatchLog "Watchdog stopped (PID $PID)."
}
