#Requires -Version 5.1
<#
    Registers a logon scheduled task that keeps Nova Bridge alive by polling
    /health and restarting it when it dies.

    Runs as the current interactive user (not SYSTEM) so restarted bridges still
    see PATH / APPDATA / gh keyring credentials.

    Run from an ordinary (non-admin) PowerShell:
        powershell -ExecutionPolicy Bypass -File scripts\install-bridge-watchdog.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = "NovaBridgeWatchdog"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $scriptDir "run-watchdog-hidden.vbs"
$watchdog = Join-Path $scriptDir "watchdog-bridge.ps1"
if (-not (Test-Path $vbs)) { throw "Launcher not found: $vbs" }
if (-not (Test-Path $watchdog)) { throw "Watchdog not found: $watchdog" }

# Stop any prior watchdog task / process before re-registering.
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

$root = Split-Path -Parent $scriptDir
$pidFile = Join-Path $root "logs\watchdog.pid"
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -match '^\d+$') {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

$action = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument """$vbs"""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 999 `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$settings.Hidden = $true
$settings.DisallowStartIfOnBatteries = $false

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Polls Nova Bridge /health and restarts it when the process dies." `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' (starts at logon)."

Start-ScheduledTask -TaskName $TaskName
Write-Host "Started '$TaskName'."
Write-Host "Logs: $(Join-Path $root 'logs\watchdog.log')"
Write-Host ""
Write-Host "The watchdog polls every 30s and runs start-bridge.ps1 when /health fails."
