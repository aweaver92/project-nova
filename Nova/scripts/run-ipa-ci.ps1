#Requires -Version 5.1
<#
.SYNOPSIS
  Trigger the GitHub Actions IPA job and download it to Nova/App/NovaApp.ipa.

.DESCRIPTION
  Dispatches the CI workflow (macOS ios-ipa job), waits for it to finish, then
  writes the artifact to App/NovaApp.ipa for SideStore.

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

# Fail early with a clear message when the bridge spawn can't use keyring auth.
$authOut = & $gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "gh is not authenticated in this environment. Run 'gh auth login' on the PC, or set GH_TOKEN for the bridge. Detail: $(($authOut | Out-String).Trim())"
}

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

    # Right after commit+push, GitHub can briefly 404 the branch for workflow_dispatch
    # ("could not create workflow dispatch event" / "ref not found"). Wait until the
    # remote tip is visible, then retry the dispatch with the real gh stderr.
    $remoteReady = $false
    for ($i = 0; $i -lt 15; $i++) {
        $null = & $git ls-remote --exit-code origin "refs/heads/$Ref" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $remoteReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $remoteReady) {
        throw "Remote branch '$Ref' not visible on origin yet. Push may still be propagating - retry Commit and Build."
    }

    $beforeJson = & $gh run list --workflow CI --event workflow_dispatch --limit 1 --json databaseId,createdAt 2>&1
    $beforeId = $null
    if ($LASTEXITCODE -eq 0 -and $beforeJson) {
        $before = ("$beforeJson" | ConvertFrom-Json) | Select-Object -First 1
        if ($before) { $beforeId = [string]$before.databaseId }
    }

    $dispatchErr = $null
    $dispatched = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $dispatchOut = & $gh workflow run CI --ref $Ref 2>&1
        $dispatchCode = $LASTEXITCODE
        if ($dispatchCode -eq 0) {
            $dispatched = $true
            if ($dispatchOut) { Write-Host ($dispatchOut | Out-String).TrimEnd() }
            break
        }
        $dispatchErr = (($dispatchOut | Out-String).Trim())
        if (-not $dispatchErr) { $dispatchErr = "(no gh output, exit $dispatchCode)" }
        Write-Warning "gh workflow run attempt $attempt/6 failed: $dispatchErr"
        Start-Sleep -Seconds ([Math]::Min(20, 2 * $attempt))
    }
    if (-not $dispatched) {
        throw "gh workflow run failed for ref '$Ref': $dispatchErr"
    }

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
