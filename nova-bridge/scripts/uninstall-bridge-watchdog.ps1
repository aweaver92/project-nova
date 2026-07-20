#Requires -Version 5.1
<#
    Stops and removes the NovaBridgeWatchdog scheduled task, and kills any
    running watchdog process recorded in logs\watchdog.pid.
#>
[CmdletBinding()]
param(
    [string]$TaskName = "NovaBridgeWatchdog"
)

$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$pidFile = Join-Path $root "logs\watchdog.pid"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
} else {
    Write-Host "No scheduled task named '$TaskName'."
}

if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -match '^\d+$') {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped watchdog PID $oldPid."
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
