<#
.SYNOPSIS
  Pull Nornir Docker images from GitHub Container Registry (ghcr.io) and retag locally.

.DESCRIPTION
  Pulls ghcr.io/<Owner>/nornir:<tag> (and optional nornir-dashboard) then tags as
  nornir:<tag> / nornir-dashboard:latest so local scripts and Compose keep working.
  Requires docker login to ghcr.io first for private packages
  (PAT with read:packages).

  Default Tags match the build-appliance set (prod, cupy). Pass the full push set
  when you also need dev / dev-cursor-base locally.

.PARAMETER Owner
  GHCR namespace. Default: jamesra (or $env:NORNIR_GHCR_OWNER).

.PARAMETER Tags
  Image tag suffixes to pull. Default: prod, cupy.
  Use @('dev','dev-cursor-base','prod','cupy') to match docker-push.ps1.

.PARAMETER IncludeDashboard
  Also pull/retag nornir-dashboard:latest.

.PARAMETER AlsoVersioned
  Also pull ghcr.io/.../nornir:<tag>-<VERSION> using VERSION from the monorepo root.
  Floating tag is still used for the local retag unless -PreferVersioned.

.PARAMETER PreferVersioned
  Retag local names from the versioned remote tag instead of the floating tag.
  Implies -AlsoVersioned.

.PARAMETER DryRun
  Print docker commands without running them.

.PARAMETER ContinueOnError
  Warn and continue if a pull fails (same tolerance as Initialize-NornirBuildAppliance).
  Without this switch, the first failed pull stops the script.
#>
param(
    [string]$Owner = '',
    [string[]]$Tags = @('prod', 'cupy'),
    [switch]$IncludeDashboard,
    [switch]$AlsoVersioned,
    [switch]$PreferVersioned,
    [switch]$DryRun,
    [switch]$ContinueOnError
)

$ErrorActionPreference = 'Stop'

$DockerDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DockerDir

if ($PreferVersioned) {
    $AlsoVersioned = $true
}

$ver = ''
if ($AlsoVersioned) {
    $versionPath = Join-Path $RepoRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath)) {
        Write-Error "Missing VERSION at $versionPath (needed for -AlsoVersioned / -PreferVersioned)"
    }
    $ver = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($ver)) {
        Write-Error 'VERSION file is empty'
    }
}

if ([string]::IsNullOrWhiteSpace($Owner)) {
    if ($env:NORNIR_GHCR_OWNER -and $env:NORNIR_GHCR_OWNER.Trim()) {
        $Owner = $env:NORNIR_GHCR_OWNER.Trim()
    }
    else {
        $Owner = 'jamesra'
    }
}

function Invoke-NornirDockerCli {
    param([Parameter(Mandatory)][string[]]$DockerCliArgs)
    Write-Host ("docker " + ($DockerCliArgs -join ' '))
    if ($DryRun) {
        return $true
    }
    & docker @DockerCliArgs
    if ($LASTEXITCODE -ne 0) {
        $msg = "docker failed: $($DockerCliArgs -join ' ')"
        if ($ContinueOnError) {
            Write-Warning $msg
            if (($DockerCliArgs -join ' ') -match '\bpull\b') {
                Write-Warning 'Auth likely required: docker login ghcr.io -u <github-user> (PAT with read:packages)'
            }
            return $false
        }
        Write-Error $msg
    }
    return $true
}

$registry = "ghcr.io/$Owner/nornir"
foreach ($tag in $Tags) {
    $floating = "${registry}:$tag"
    $local = "nornir:$tag"
    Write-Host "=== Pull $floating -> $local ==="

    if (-not (Invoke-NornirDockerCli -DockerCliArgs @('pull', $floating))) {
        Write-Host ''
        continue
    }

    $retagFrom = $floating
    if ($AlsoVersioned) {
        $versioned = "${registry}:${tag}-$ver"
        if (Invoke-NornirDockerCli -DockerCliArgs @('pull', $versioned)) {
            if ($PreferVersioned) {
                $retagFrom = $versioned
            }
        }
    }

    [void](Invoke-NornirDockerCli -DockerCliArgs @('tag', $retagFrom, $local))
    Write-Host ''
}

if ($IncludeDashboard) {
    $dashReg = "ghcr.io/$Owner/nornir-dashboard"
    $floating = "${dashReg}:latest"
    $local = 'nornir-dashboard:latest'
    Write-Host "=== Pull $floating -> $local ==="

    if (Invoke-NornirDockerCli -DockerCliArgs @('pull', $floating)) {
        $retagFrom = $floating
        if ($AlsoVersioned) {
            $versioned = "${dashReg}:$ver"
            if ((Invoke-NornirDockerCli -DockerCliArgs @('pull', $versioned)) -and $PreferVersioned) {
                $retagFrom = $versioned
            }
        }
        [void](Invoke-NornirDockerCli -DockerCliArgs @('tag', $retagFrom, $local))
    }
    Write-Host ''
}

Write-Host "Done. Pulled from ghcr.io/$Owner."
Write-Host '  Confirm: docker image ls nornir'
Write-Host "  Inspect: docker buildx imagetools inspect ghcr.io/$Owner/nornir:cupy"
