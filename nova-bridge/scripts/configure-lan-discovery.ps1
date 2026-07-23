#Requires -Version 5.1
<#
    Adds narrowly scoped Windows Private-network firewall rules for Nova Bridge:
      - TCP bridge API (PORT from .env, default 8787)
      - UDP 5353 Bonjour/mDNS discovery

    The script self-elevates because changing firewall rules requires admin.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scriptPath = $MyInvocation.MyCommand.Path
$isAdmin = ([Security.Principal.WindowsPrincipal](
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Administrator permission is required to add Private-network firewall rules."
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $args -Wait -PassThru
    exit $process.ExitCode
}

$root = Split-Path -Parent (Split-Path -Parent $scriptPath)
$port = 8787
$kickPort = 8788
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*PORT\s*=\s*(\d+)') {
            $port = [int]$Matches[1]
        }
        if ($line -match '^\s*NOVA_BRIDGE_KICK_PORT\s*=\s*(\d+)') {
            $kickPort = [int]$Matches[1]
        }
    }
}

$rules = @(
    @{
        Name = "Nova Bridge API (Private LAN)"
        Protocol = "TCP"
        Port = $port
    },
    @{
        Name = "Nova Bridge Kick (Private LAN)"
        Protocol = "TCP"
        Port = $kickPort
    },
    @{
        Name = "Nova Bridge Bonjour (Private LAN)"
        Protocol = "UDP"
        Port = 5353
    }
)

foreach ($rule in $rules) {
    Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName $rule.Name `
        -Description "Allows Nova iPhone app to discover and reach Nova Bridge on trusted private networks." `
        -Direction Inbound `
        -Action Allow `
        -Profile Private `
        -Protocol $rule.Protocol `
        -LocalPort $rule.Port | Out-Null
    Write-Host "Allowed $($rule.Protocol) port $($rule.Port) on Private networks."
}

$profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
$active = @($profiles | Where-Object { $_.IPv4Connectivity -ne "Disconnected" })
if ($active | Where-Object { $_.NetworkCategory -eq "Public" }) {
    Write-Warning "An active network is Public. Nova rules intentionally apply only to Private networks."
    Write-Host "If this is your trusted home LAN, change it in Windows Settings -> Network & internet -> Properties -> Private."
}

Write-Host ""
Write-Host "Nova Bridge LAN discovery firewall setup complete."
