#Requires -Version 5.1
<#
    Tiny TCP/HTTP kick listener used when Nova Bridge (:8787) is hung or dead.
    Uses TcpListener (no URL ACL / admin) so it works from the user-mode watchdog.

    Phone: POST /restart with Bearer NOVA_BRIDGE_TOKEN
    Writes logs/bridge.kick so watchdog-bridge.ps1 restarts the bridge.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$KickPort,
    [string]$Token = $env:NOVA_BRIDGE_KICK_TOKEN,
    [Parameter(Mandatory = $true)][string]$FlagPath,
    [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = "Continue"
if ([string]::IsNullOrEmpty($Token)) { $Token = "" }

function Write-KickLog([string]$Message) {
    $line = "{0:u} kick: {1}" -f (Get-Date).ToUniversalTime(), $Message
    Add-Content -Path $LogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
}

function Send-HttpResponse([System.Net.Sockets.NetworkStream]$Stream, [int]$Status, [string]$Json) {
    $reason = switch ($Status) {
        200 { "OK" }
        401 { "Unauthorized" }
        404 { "Not Found" }
        500 { "Internal Server Error" }
        default { "OK" }
    }
    $body = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $KickPort)
try {
    $listener.Start()
    Write-KickLog "listening on 0.0.0.0:$KickPort (TcpListener)"
} catch {
    Write-KickLog "FAILED to start listener: $($_.Exception.Message)"
    exit 1
}

try {
    while ($true) {
        $client = $null
        $stream = $null
        try {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $buffer = New-Object byte[] 8192
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { continue }
            $raw = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $lines = $raw -split "`r?`n"
            $requestLine = if ($lines.Count -gt 0) { $lines[0] } else { "" }
            $method = ""
            $path = "/"
            if ($requestLine -match '^(\S+)\s+(\S+)') {
                $method = $Matches[1]
                $path = ($Matches[2] -split '\?')[0]
            }
            $path = $path.TrimEnd("/")
            if ([string]::IsNullOrEmpty($path)) { $path = "/" }

            $auth = ""
            foreach ($line in $lines) {
                if ($line -match '^(?i)Authorization:\s*(.+)$') {
                    $auth = $Matches[1].Trim()
                    break
                }
            }
            $provided = ""
            if ($auth.StartsWith("Bearer ")) { $provided = $auth.Substring(7) }

            $bodyObj = @{ ok = $false }
            $status = 404
            if ($method -eq "GET" -and ($path -eq "/health" -or $path -eq "/")) {
                $bodyObj = @{ ok = $true; service = "nova-bridge-watchdog"; kick = $true }
                $status = 200
            } elseif ($method -eq "POST" -and $path -eq "/restart") {
                if ([string]::IsNullOrEmpty($Token)) {
                    $bodyObj = @{ ok = $false; error = "server_missing_token" }
                    $status = 500
                } elseif ($provided -cne $Token) {
                    $bodyObj = @{ ok = $false; error = "unauthorized" }
                    $status = 401
                } else {
                    Set-Content -Path $FlagPath -Value ("{0:u}" -f (Get-Date).ToUniversalTime()) -Encoding ascii
                    $bodyObj = @{
                        ok         = $true
                        restarting = $true
                        via        = "watchdog-kick"
                        hint       = "Watchdog will restart the bridge shortly."
                    }
                    $status = 200
                    Write-KickLog "accepted POST /restart from $($client.Client.RemoteEndPoint)"
                }
            } else {
                $bodyObj = @{ ok = $false; error = "not_found" }
                $status = 404
            }

            Send-HttpResponse -Stream $stream -Status $status -Json ($bodyObj | ConvertTo-Json -Compress)
        } catch {
            Write-KickLog "request error: $($_.Exception.Message)"
        } finally {
            if ($stream) { try { $stream.Close() } catch { } }
            if ($client) { try { $client.Close() } catch { } }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    Write-KickLog "listener stopped"
}
