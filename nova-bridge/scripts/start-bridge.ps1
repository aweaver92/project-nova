#Requires -Version 5.1
<#
    Starts the Nova Bridge as a detached, windowless background process and waits
    for /health to come up. Safe to run repeatedly: any stale bridge instance is
    stopped first so we never end up with duplicate listeners on the port.

    Runs as the logged-in user (inheriting PATH, APPDATA, and the GitHub CLI
    credentials in the Windows keyring) so `gh`/`git`/Cursor behave exactly as
    they do in an interactive terminal.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Get-BridgePort {
    $envFile = Join-Path $root ".env"
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*PORT\s*=\s*(\d+)') { return [int]$Matches[1] }
        }
    }
    return 8787
}

function Get-NpmPath {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:ProgramFiles "nodejs\npm.cmd"
    if (Test-Path $candidate) { return $candidate }
    throw "npm.cmd not found. Install Node.js or add it to PATH."
}

function Ensure-NodeOnPath {
    $nodeDir = Join-Path $env:ProgramFiles "nodejs"
    if ((Test-Path (Join-Path $nodeDir "node.exe")) -and ($env:Path -notlike "*$nodeDir*")) {
        $env:Path = "$nodeDir;$env:Path"
    }
}

function Ensure-BridgeDependencies {
    $tsxCli = Join-Path $root "node_modules\tsx\dist\cli.mjs"
    $express = Join-Path $root "node_modules\express\package.json"
    if ((Test-Path $tsxCli) -and (Test-Path $express)) { return }
    Write-Host "Installing nova-bridge dependencies (node_modules incomplete)…"
    Push-Location $root
    try {
        & (Get-NpmPath) install --no-fund --no-audit
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path $tsxCli)) {
        throw "tsx still missing after npm install. Check nova-bridge/package.json."
    }
}

# Kill any existing bridge node processes (matched by their server.ts command
# line) so restarts are clean and the port is never double-bound.
function Stop-StaleBridge {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
        Where-Object { $_.CommandLine -and ($_.CommandLine -match 'src[\\/]server\.ts' -or $_.CommandLine -match 'tsx.*server\.ts') }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped stale bridge PID $($p.ProcessId)"
        } catch {
            Write-Warning "Could not stop PID $($p.ProcessId): $($_.Exception.Message)"
        }
    }
}

Ensure-NodeOnPath
$port = Get-BridgePort
$npm = Get-NpmPath
Ensure-BridgeDependencies

Stop-StaleBridge
Start-Sleep -Milliseconds 500

$outLog = Join-Path $logDir "bridge.out.log"
$errLog = Join-Path $logDir "bridge.err.log"

# Start-Process does not always inherit this session's PATH; force Node onto the
# child environment so `npm run start` can resolve local tsx.
$process = Start-Process -FilePath $npm `
    -ArgumentList "run", "start" `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog `
    -PassThru

$process.Id | Out-File -FilePath (Join-Path $logDir "bridge.pid") -Encoding ascii

Write-Host "Launched Nova Bridge (PID $($process.Id)) on port $port"

$healthUrl = "http://127.0.0.1:$port/health"
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if ($process.HasExited) {
        Write-Warning "Bridge process exited early (code $($process.ExitCode)). Recent errors:"
        if (Test-Path $errLog) { Get-Content $errLog -Tail 20 }
        exit 1
    }
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
        Write-Host "Healthy: $($health | ConvertTo-Json -Compress)"
        $publicWiFi = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object {
                $_.NetworkCategory -eq "Public" -and
                ($_.InterfaceAlias -match "Wi-?Fi|Wireless")
            } |
            Select-Object -First 1
        if ($publicWiFi) {
            Write-Warning "Wi-Fi '$($publicWiFi.Name)' is Public; iPhone LAN discovery may be blocked."
            Write-Host "For a trusted home network, set it to Private, then run:"
            Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\configure-lan-discovery.ps1"
        }
        exit 0
    } catch {
        # not up yet; keep polling
    }
}

Write-Warning "Bridge did not report healthy within 30s. Check $errLog"
exit 1
