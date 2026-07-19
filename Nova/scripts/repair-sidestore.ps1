#Requires -Version 5.1
<#
.SYNOPSIS
  Recover SideStore after "could not determine this device's UDID" (error 1006).

.DESCRIPTION
  Router / Wi-Fi resets commonly break SideStore's LocalDevVPN (StosVPN) tunnel
  and leave a stale pairing file. minimuxer then times out fetching the UDID.

  This script cannot rewrite the pairing file for you (iloader must do that),
  but it:
    1. Diagnoses Wi-Fi / VPN / Apple mobile device services on the PC
    2. Walks the official SideStore 1006 recovery checklist in order
    3. Reminds you of the post-router-restart order that usually clears it

.PARAMETER SkipDiagnostics
  Skip PC-side checks and print only the phone/iloader recovery steps.

.EXAMPLE
  .\scripts\repair-sidestore.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Continue"

function Write-Step([int]$n, [string]$msg) {
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $n, $msg) -ForegroundColor Cyan
}

function Write-Ok([string]$msg) { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Bad([string]$msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }
function Write-Info([string]$msg) { Write-Host "      $msg" }

Write-Host ""
Write-Host "SideStore UDID recovery (error 1006)" -ForegroundColor White
Write-Host "Router restarts often kill LocalDevVPN / StosVPN and stale pairing."
Write-Host "SideStore then cannot read this phone's UDID until both are healthy."
Write-Host ""

if (-not $SkipDiagnostics) {
    Write-Step 0 "PC diagnostics"

    # Wi-Fi / link
    try {
        $wifi = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq "Up" -and ($_.InterfaceDescription -match "Wi-?Fi|Wireless|802\.11" -or $_.Name -match "Wi-?Fi") } |
            Select-Object -First 1
        if ($wifi) {
            Write-Ok ("Wi-Fi up: {0} ({1})" -f $wifi.Name, $wifi.LinkSpeed)
        } else {
            $anyUp = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | Select-Object -First 3
            if ($anyUp) {
                Write-Ok ("Network up: {0}" -f (($anyUp | ForEach-Object { $_.Name }) -join ", "))
                Write-Info "Phone + PC must share the same LAN (or StosVPN tunnel)."
            } else {
                Write-Bad "No active network adapter. Reconnect Wi-Fi before continuing."
            }
        }
    } catch {
        Write-Bad "Could not query adapters: $($_.Exception.Message)"
    }

    # SideStore / StosVPN / WireGuard-style tunnel adapters (names vary)
    try {
        $vpnish = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "Stos|SideStore|LocalDev|WireGuard|Wintun|tun" -or
            $_.InterfaceDescription -match "Stos|SideStore|LocalDev|WireGuard|Wintun|tun"
        }
        if ($vpnish) {
            foreach ($a in $vpnish) {
                $mark = if ($a.Status -eq "Up") { "OK" } else { "!!" }
                $color = if ($a.Status -eq "Up") { "Green" } else { "Yellow" }
                Write-Host ("  {0}  VPN-ish adapter: {1} [{2}]" -f $mark, $a.Name, $a.Status) -ForegroundColor $color
            }
            Write-Info "If none are Up after a router reboot: open StosVPN / LocalDevVPN on the phone, toggle it off/on."
            $conflict = @($vpnish) | Where-Object {
                $_.Status -eq "Up" -and ($_.Name -match "Nord|Tailscale|OpenVPN|Mullvad|Express" -or $_.InterfaceDescription -match "Nord|Tailscale|OpenVPN|Mullvad|Express")
            }
            if ($conflict) {
                Write-Bad ("PC VPN may interfere with SideStore's local tunnel: {0}" -f (($conflict | ForEach-Object { $_.Name }) -join ", "))
                Write-Info "While repairing UDID: disconnect Nord/Tailscale (or enable split-tunnel / allow local LAN), then retry StosVPN on the phone."
            }
        } else {
            Write-Info "No StosVPN/WireGuard adapter visible on the PC (normal - the tunnel lives on the phone)."
            Write-Info "After a router reboot, reopen StosVPN on the iPhone and confirm it shows Connected."
        }
    } catch {}

    # Apple Mobile Device Support (needed for USB pairing via iloader)
    $appleSvc = Get-Service -Name "Apple Mobile Device Service", "AppleMobileDeviceService" -ErrorAction SilentlyContinue
    if (-not $appleSvc) {
        # Service display name varies by iTunes / Apple Devices install
        $appleSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -match "Apple Mobile Device|Apple Devices"
        } | Select-Object -First 2
    }
    if ($appleSvc) {
        foreach ($s in @($appleSvc)) {
            if ($s.Status -eq "Running") {
                Write-Ok ("{0} is running" -f $s.DisplayName)
            } else {
                Write-Bad ("{0} is {1} - start it before USB pairing" -f $s.DisplayName, $s.Status)
                Write-Info "Try: Start-Service -Name '$($s.Name)'  (or reopen Apple Devices / iTunes)"
            }
        }
    } else {
        Write-Bad "Apple Mobile Device service not found."
        Write-Info "Install Apple Devices (or classic iTunes from apple.com, not the Store) before using iloader over USB."
    }

    # iloader on PATH / common locations
    $iloaderHints = @(
        (Get-Command iloader -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
        "$env:LOCALAPPDATA\Programs\iloader\iloader.exe"
        "$env:LOCALAPPDATA\iloader\iloader.exe"
        "$env:ProgramFiles\iloader\iloader.exe"
        "${env:ProgramFiles(x86)}\iloader\iloader.exe"
    ) | Where-Object { $_ } | Select-Object -Unique
    $foundIloader = $iloaderHints | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($foundIloader) {
        Write-Ok "iloader found: $foundIloader"
    } else {
        Write-Bad "iloader not found on PATH / common install dirs."
        Write-Info "Download from https://iloader.sidestore.io (or SideStore docs) - required to replace the pairing file."
    }
}

Write-Step 1 "Do this first after a router / Wi-Fi reset (often enough)"
Write-Info "1. On the iPhone: unlock, reconnect to the same Wi-Fi as this PC."
Write-Info "2. Open StosVPN / LocalDevVPN -> disconnect, then reconnect (must show Connected)."
Write-Info "3. In SideStore -> Settings -> VPN Configuration: Device IP must match StosVPN"
Write-Info "   (default is often 10.7.0.1 - copy whatever StosVPN shows)."
Write-Info "4. Reboot the iPhone (AssistiveTouch restart is fine)."
Write-Info "5. After reboot: Wi-Fi + StosVPN Connected, then SideStore -> Refresh."
Write-Info "Optional: Settings -> Privacy & Security -> Developer Mode off, then on (forces a reboot)."

Write-Step 2 "If UDID is still missing - replace the pairing file (official 1006 fix)"
Write-Info "Use a USB cable when possible (most reliable after network flaps)."
Write-Info "1. SideStore -> Settings -> Reset Pairing File."
Write-Info "2. Open iloader on this PC -> Delete Stored Pairing."
Write-Info "3. Unlock phone, Trust this computer if prompted."
Write-Info "4. iloader -> Refresh, pair the device."
Write-Info "5. Manage Pairing File -> Place in All Apps (or Place next to SideStore)."
Write-Info "6. Open SideStore, confirm Apple ID is signed in, then Refresh."
Write-Info "7. Still failing? SideStore Settings -> Anisette -> try Macley, then reboot phone."

Write-Step 3 "Install the Nova IPA once SideStore can see the UDID again"
$ipa = Join-Path (Split-Path -Parent $PSScriptRoot) "App\NovaApp.ipa"
if (Test-Path $ipa) {
    $item = Get-Item $ipa
    Write-Ok ("IPA ready: {0} ({1:N1} MB, {2:g})" -f $ipa, ($item.Length / 1MB), $item.LastWriteTime)
    Write-Info "On the phone: SideStore -> My Apps -> + -> pick NovaApp.ipa (AirDrop / Files / shared folder)."
} else {
    Write-Bad "No NovaApp.ipa yet. Build one with: .\scripts\run-ipa-ci.ps1"
}

Write-Host ""
Write-Host "Docs: https://docs.sidestore.io/docs/troubleshooting/error-codes  (error 1006)" -ForegroundColor DarkGray
Write-Host "Pairing: https://docs.sidestore.io/docs/advanced/pairing-file" -ForegroundColor DarkGray
Write-Host ""
