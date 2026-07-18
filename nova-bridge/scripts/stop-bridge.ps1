#Requires -Version 5.1
<#
    Stops any running Nova Bridge instance (matched by its server.ts command
    line, plus the recorded PID file as a fallback).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$pidFile = Join-Path $root "logs\bridge.pid"

$stopped = 0

$procs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'src[\\/]server\.ts' }
foreach ($p in $procs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host "Stopped bridge PID $($p.ProcessId)"
        $stopped++
    } catch {
        Write-Warning "Could not stop PID $($p.ProcessId): $($_.Exception.Message)"
    }
}

if (Test-Path $pidFile) {
    $savedPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($savedPid -and ($savedPid -match '^\d+$')) {
        $existing = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue
        if ($existing) {
            try {
                Stop-Process -Id ([int]$savedPid) -Force -ErrorAction Stop
                Write-Host "Stopped bridge PID $savedPid (from pid file)"
                $stopped++
            } catch {
                Write-Warning "Could not stop PID $savedPid"
            }
        }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

if ($stopped -eq 0) {
    Write-Host "No running Nova Bridge process found."
}
