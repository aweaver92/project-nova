#Requires -Version 5.1
<#
    Stops the Nova Bridge and removes its scheduled task, so it no longer starts
    at logon. Run from an ordinary PowerShell:
        powershell -ExecutionPolicy Bypass -File scripts\uninstall-bridge-service.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = "NovaBridge"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
} else {
    Write-Host "No scheduled task named '$TaskName' found."
}

& (Join-Path $scriptDir "stop-bridge.ps1")
Write-Host "Nova Bridge stopped and disabled from starting at logon."
