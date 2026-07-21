#Requires -Version 5.1
<#
.SYNOPSIS
  Download the latest CI .ipa artifact into Nova/App/NovaApp.ipa.

.DESCRIPTION
  Pulls NovaApp-unsigned-ipa from a GitHub Actions run that actually produced
  that artifact, prints the commit it was built from, and writes App/NovaApp.ipa.

.PARAMETER RunId
  Specific Actions run id. Default: newest successful run that has the IPA artifact.

.PARAMETER Wait
  If set with -RunId, poll until that run finishes before downloading.

.EXAMPLE
  .\scripts\download-ipa.ps1
  .\scripts\download-ipa.ps1 -RunId 1234567890 -Wait
#>
[CmdletBinding()]
param(
    [string]$RunId,
    [switch]$Wait
)

$ErrorActionPreference = "Stop"

function Find-Gh {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    $candidates = @(
        @(
            $(if ($cmd) { $cmd.Source })
            "$env:LOCALAPPDATA\GitHubCLI\bin\gh.exe"
            "$env:ProgramFiles\GitHub CLI\gh.exe"
            # Hardcoded fallbacks - bridge spawn env may omit ProgramFiles.
            "C:\Program Files\GitHub CLI\gh.exe"
            "${env:ProgramW6432}\GitHub CLI\gh.exe"
        ) | Where-Object { $_ -and (Test-Path $_) }
    )
    if ($candidates.Count -eq 0) {
        throw "gh CLI not found. Install GitHub CLI and run 'gh auth login'."
    }
    return $candidates[0]
}

function Get-RunIpaArtifact {
    param([string]$Gh, [string]$Id)
    $json = & $Gh api "repos/:owner/:repo/actions/runs/$Id/artifacts"
    if ($LASTEXITCODE -ne 0) { return $null }
    $arts = ($json | ConvertFrom-Json).artifacts
    return $arts | Where-Object { $_.name -eq "NovaApp-unsigned-ipa" -and -not $_.expired } | Select-Object -First 1
}

$NovaRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $NovaRoot
$DestIpa = Join-Path $NovaRoot "App\NovaApp.ipa"
$Staging = Join-Path $env:TEMP ("nova-ipa-" + [guid]::NewGuid().ToString("n"))

$gitBin = "C:\Program Files\Git\bin"
if ((Test-Path $gitBin) -and ($env:Path -notlike "*$gitBin*")) {
    $env:Path = "$gitBin;$env:Path"
}
$git = Join-Path $gitBin "git.exe"
if (-not (Test-Path $git)) { $git = "git" }

$gh = Find-Gh
Push-Location $RepoRoot
try {
    $headSha = (& $git rev-parse HEAD).Trim()
    $dirtyNova = & $git status --porcelain -- Nova
    if ($dirtyNova) {
        Write-Warning "You have uncommitted Nova changes. No CI IPA can include them until you commit + push, then re-run the IPA job."
        $dirtyNova | ForEach-Object { Write-Host "  $_" }
    }

    if (-not $RunId) {
        Write-Host "Looking up newest successful CI run that uploaded NovaApp-unsigned-ipa..."
        $runsJson = & $gh run list --workflow CI --limit 40 --json databaseId,conclusion,status,displayTitle,createdAt,event,headSha,headBranch
        if ($LASTEXITCODE -ne 0) { throw "gh run list failed (exit $LASTEXITCODE)" }
        $runs = $runsJson | ConvertFrom-Json

        $candidate = $null
        foreach ($run in $runs) {
            if ($run.conclusion -ne "success") { continue }
            if ($run.event -notin @("workflow_dispatch", "push")) { continue }
            $art = Get-RunIpaArtifact -Gh $gh -Id ([string]$run.databaseId)
            if ($art) {
                $candidate = $run
                $script:FoundArtifact = $art
                break
            }
        }

        if (-not $candidate) {
            throw "No successful CI run with a NovaApp-unsigned-ipa artifact. Run .\scripts\run-ipa-ci.ps1 (after commit+push)."
        }
        $RunId = [string]$candidate.databaseId
        Write-Host ("Using run {0} ({1})" -f $RunId, $candidate.displayTitle)
        Write-Host ("  event={0} branch={1} created={2}" -f $candidate.event, $candidate.headBranch, $candidate.createdAt)
        Write-Host ("  built from {0}" -f $candidate.headSha)
        if ($candidate.headSha -ne $headSha) {
            Write-Warning ("This IPA is NOT from your current HEAD ({0}). Re-run IPA CI on the latest push if you expected newer code." -f $headSha.Substring(0, 7))
        }
    }

    if ($Wait) {
        Write-Host "Waiting for run $RunId to finish..."
        & $gh run watch $RunId --exit-status
        if ($LASTEXITCODE -ne 0) {
            $failedJobs = & $gh run view $RunId --json jobs --jq '.jobs[] | select(.conclusion=="failure") | "\(.name) (ID \(.databaseId))"' 2>$null
            $failedJobs = ("$failedJobs" -replace "`r", "").Trim()
            if (-not $failedJobs) { $failedJobs = "(see Actions run $RunId)" }

            # Surface real compile/test errors - gh often dumps Node/action
            # deprecation noise at the end, which is useless on the phone.
            $logFailed = & $gh run view $RunId --log-failed 2>$null | Out-String
            $errorLines = @()
            foreach ($line in ($logFailed -split "`r?`n")) {
                if ($line -notmatch '(^|\s)error:') { continue }
                if ($line -match 'Node\.js 20|actions/checkout|actions/setup-node|github\.blog/changelog') { continue }
                $cleaned = ($line -replace '.*?error:\s*', 'error: ').Trim()
                if ($cleaned) { $errorLines += $cleaned }
            }
            if ($errorLines.Count -gt 6) {
                $errorLines = $errorLines[($errorLines.Count - 6)..($errorLines.Count - 1)]
            }
            if ($errorLines.Count -gt 0) {
                $detail = $errorLines -join " | "
            } else {
                $detail = "no compile errors extracted - open Actions run $RunId"
            }
            throw "Run $RunId did not succeed. Failed: $failedJobs. $detail"
        }
    }

    $runMeta = & $gh run view $RunId --json headSha,createdAt,event,headBranch,url,conclusion | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "gh run view failed for $RunId" }
    Write-Host ("Run {0}: {1}" -f $RunId, $runMeta.url)
    Write-Host ("  built from {0} ({1} on {2})" -f $runMeta.headSha, $runMeta.event, $runMeta.headBranch)

    $art = Get-RunIpaArtifact -Gh $gh -Id $RunId
    if (-not $art) {
        throw "Run $RunId has no NovaApp-unsigned-ipa artifact (wrong run, or ios-ipa job did not run)."
    }
    Write-Host ("  artifact {0:N1} MB, created {1}" -f ($art.size_in_bytes / 1MB), $art.created_at)

    New-Item -ItemType Directory -Path $Staging -Force | Out-Null
    try {
        Write-Host "Downloading artifact NovaApp-unsigned-ipa from run $RunId..."
        & $gh run download $RunId -n NovaApp-unsigned-ipa -D $Staging
        if ($LASTEXITCODE -ne 0) {
            throw "gh run download failed (exit $LASTEXITCODE)."
        }

        $found = Get-ChildItem -Path $Staging -Filter "NovaApp.ipa" -Recurse -File | Select-Object -First 1
        if (-not $found) {
            throw "Downloaded artifact but NovaApp.ipa was not inside it. Contents:`n$((Get-ChildItem -Recurse $Staging | Select-Object -ExpandProperty FullName) -join "`n")"
        }

        $destDir = Split-Path -Parent $DestIpa
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $found.FullName -Destination $DestIpa -Force
        $item = Get-Item -LiteralPath $DestIpa
        Write-Host ("Wrote {0} ({1:N1} MB)" -f $DestIpa, ($item.Length / 1MB))
        Write-Host "Sideload with SideStore (My Apps -> +). Check Settings/Listen for NovaBuildStamp matching the short SHA above."
        Write-Host "If SideStore says it cannot detect UDID (esp. after a router reboot): .\scripts\repair-sidestore.ps1"
        if ($runMeta.headSha -and $runMeta.headSha -ne $headSha) {
            Write-Warning "Still not your current HEAD - commit, push, then .\scripts\run-ipa-ci.ps1 for a fresh build."
        }
    }
    finally {
        Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Pop-Location
}
