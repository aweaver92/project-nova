#Requires -Version 5.1
<#
.SYNOPSIS
  Trigger the GitHub Actions IPA job and download it to Nova/App/NovaApp.ipa.

.DESCRIPTION
  Dispatches the CI workflow (macOS ios-ipa job), waits for it to finish, then
  writes the artifact to App/NovaApp.ipa for AltStore.

  On a public repo this uses free Actions minutes. On a private repo macOS is
  billed at 10x - only run when you need a new sideload build.

.PARAMETER Ref
  Git ref to build (branch, tag, or SHA). Default: current branch, else main.

.EXAMPLE
  .\scripts\run-ipa-ci.ps1
  .\scripts\run-ipa-ci.ps1 -Ref main
#>
[CmdletBinding()]
param(
    [string]$Ref
)

$ErrorActionPreference = "Stop"

function Find-Gh {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    $candidates = @(
        @(
            $(if ($cmd) { $cmd.Source })
            "$env:LOCALAPPDATA\GitHubCLI\bin\gh.exe"
            "$env:ProgramFiles\GitHub CLI\gh.exe"
        ) | Where-Object { $_ -and (Test-Path $_) }
    )
    if ($candidates.Count -eq 0) {
        throw "gh CLI not found. Install GitHub CLI and run 'gh auth login'."
    }
    return $candidates[0]
}

$NovaRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $NovaRoot
$DownloadScript = Join-Path $PSScriptRoot "download-ipa.ps1"

$gitBin = "C:\Program Files\Git\bin"
if ((Test-Path $gitBin) -and ($env:Path -notlike "*$gitBin*")) {
    $env:Path = "$gitBin;$env:Path"
}

$gh = Find-Gh
$git = Join-Path $gitBin "git.exe"
if (-not (Test-Path $git)) { $git = "git" }

Push-Location $RepoRoot
try {
    if (-not $Ref) {
        $Ref = (& $git rev-parse --abbrev-ref HEAD).Trim()
        if (-not $Ref -or $Ref -eq "HEAD") { $Ref = "main" }
    }

    $dirtyNova = & $git status --porcelain -- Nova
    if ($dirtyNova) {
        Write-Warning "Uncommitted Nova changes will NOT be in this IPA. Commit + push first, or you will keep getting an old build."
        $dirtyNova | ForEach-Object { Write-Host "  $_" }
    }
    $unpushed = & $git log "origin/$Ref..HEAD" --oneline 2>$null
    if ($unpushed) {
        Write-Warning "Local commits not on origin/$Ref yet - push before dispatching, or CI will build an older tip:"
        $unpushed | ForEach-Object { Write-Host "  $_" }
    }

    Write-Host "Dispatching CI workflow (ios-ipa) on ref '$Ref'..."
    $beforeJson = & $gh run list --workflow CI --event workflow_dispatch --limit 1 --json databaseId,createdAt
    $beforeId = $null
    if ($beforeJson) {
        $before = ($beforeJson | ConvertFrom-Json) | Select-Object -First 1
        if ($before) { $beforeId = [string]$before.databaseId }
    }

    & $gh workflow run CI --ref $Ref
    if ($LASTEXITCODE -ne 0) { throw "gh workflow run failed (exit $LASTEXITCODE)" }

    # Wait for the new run to appear in the list.
    $runId = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $listJson = & $gh run list --workflow CI --event workflow_dispatch --limit 5 --json databaseId,status,createdAt,headBranch
        if ($LASTEXITCODE -ne 0) { continue }
        $runs = $listJson | ConvertFrom-Json
        $match = $runs | Where-Object {
            $_.headBranch -eq $Ref -and ([string]$_.databaseId) -ne $beforeId
        } | Select-Object -First 1
        if ($match) {
            $runId = [string]$match.databaseId
            break
        }
    }
    if (-not $runId) {
        throw "Timed out waiting for the new workflow run to appear. Check GitHub Actions."
    }

    Write-Host "Run $runId started. Waiting for completion (this is the macOS build; often 10-25 min)..."
    & $DownloadScript -RunId $runId -Wait
}
finally {
    Pop-Location
}
