#Requires -Version 5.1
<#
    Publishes the Nova Bridge over HTTPS on your tailnet so the Nova iOS app can
    reach it from ANY network (not just your LAN). Tailscale keeps it private to
    devices logged into your account - no public exposure.

    What it does:
      1. Finds the Tailscale CLI.
      2. Verifies you're logged in (runs `tailscale up` if not).
      3. Reads PORT from ..\.env (default 8787).
      4. Runs `tailscale serve --bg <port>` so HTTPS 443 -> 127.0.0.1:<port>.
         The `--bg` config persists across reboots (tailscaled runs at boot).
      5. Prints the https://<machine>.<tailnet>.ts.net URL to paste into the app.

    Prereqs you enable once in the Tailscale admin console (all free):
      - Serve:  https://login.tailscale.com/f/serve
      - MagicDNS + HTTPS certificates: https://login.tailscale.com/admin/dns

    Run from an ordinary (non-admin) PowerShell:
        powershell -ExecutionPolicy Bypass -File scripts\setup-tailscale.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Get-TailscaleExe {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        (Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Tailscale\tailscale.exe")
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    throw "tailscale.exe not found. Install it: winget install --id Tailscale.Tailscale"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir

# Resolve the bridge port from .env (falls back to 8787).
$port = 8787
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*PORT\s*=\s*(\d+)') { $port = [int]$Matches[1]; break }
    }
}

$ts = Get-TailscaleExe
Write-Host "Using Tailscale: $ts"

# Ensure we're logged in.
$status = & $ts status 2>&1
if ($status -match 'Logged out') {
    Write-Host "Not logged in - starting login (a browser link will appear)..."
    & $ts up
}

# Grab the machine's MagicDNS name for the final URL.
$dnsName = (& $ts status --json 2>&1 | ConvertFrom-Json).Self.DNSName
if ($dnsName) { $dnsName = $dnsName.TrimEnd('.') }

Write-Host "Publishing bridge port $port over HTTPS..."
$serveOut = & $ts serve --bg $port 2>&1
Write-Host $serveOut

if ($serveOut -match 'Serve is not enabled') {
    Write-Warning "Serve is not enabled on your tailnet yet. Open the link above, enable it, then re-run this script."
    exit 1
}

Write-Host ""
Write-Host "Current serve config:"
& $ts serve status 2>&1

if ($dnsName) {
    $url = "https://$dnsName"
    Write-Host ""
    Write-Host "======================================================================"
    Write-Host " Bridge URL for the Nova app (Agents -> Claude - Nova Bridge -> URL):"
    Write-Host "   $url"
    Write-Host " Bridge token: the NOVA_BRIDGE_TOKEN value from nova-bridge\.env"
    Write-Host "======================================================================"
}
