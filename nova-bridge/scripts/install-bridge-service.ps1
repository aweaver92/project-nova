#Requires -Version 5.1
<#
    Registers the Nova Bridge to start automatically in the background at logon,
    with no terminal window, and starts it now.

    We use a Scheduled Task that runs as the current interactive user (not a
    SYSTEM service) on purpose: the bridge relies on the user's PATH, APPDATA,
    and the GitHub CLI credentials stored in the Windows keyring. A SYSTEM
    service would not see those and `gh`/git auth would break.

    The task also restarts the bridge if it ever crashes.

    Run from an ordinary (non-admin) PowerShell:
        powershell -ExecutionPolicy Bypass -File scripts\install-bridge-service.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = "NovaBridge"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $scriptDir "run-bridge-hidden.vbs"
if (-not (Test-Path $vbs)) { throw "Launcher not found: $vbs" }

$action = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument """$vbs"""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 3 `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

# Hide the task's own host window and keep it running indefinitely.
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
    -Description "Runs the Nova Bridge in the background so the Nova iOS app can reach it without a terminal." `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' (starts at logon)."

# Start it right now so no reboot/logout is needed.
Start-ScheduledTask -TaskName $TaskName
Write-Host "Started '$TaskName'. Waiting for health..."

# Poll health so install output confirms it actually came up.
$port = 8787
$envFile = Join-Path (Split-Path -Parent $scriptDir) ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*PORT\s*=\s*(\d+)') { $port = [int]$Matches[1]; break }
    }
}

$deadline = (Get-Date).AddSeconds(35)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3
        Write-Host "Nova Bridge is healthy: $($health | ConvertTo-Json -Compress)"
        Write-Host ""
        Write-Host "Done. The bridge now starts automatically at logon - no terminal needed."
        exit 0
    } catch {
        # keep polling
    }
}

Write-Warning "Task registered but health did not respond yet. Check nova-bridge\logs\bridge.err.log"
exit 1
