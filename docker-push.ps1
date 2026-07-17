<#
.SYNOPSIS
  Tag and push Nornir Docker images to GitHub Container Registry (ghcr.io).

.DESCRIPTION
  Tags local images nornir:dev, nornir:dev-cursor-base, nornir:prod, nornir:cupy, and
  nornir-dashboard:latest for ghcr.io/<Owner>/... using VERSION from the monorepo root.
  Requires docker login to ghcr.io first (PAT with write:packages).

.PARAMETER Owner
  GHCR namespace. Default: jamesra (or $env:NORNIR_GHCR_OWNER).

.PARAMETER Tags
  Local image tag suffixes to push. Default: dev, dev-cursor-base, prod, cupy.

.PARAMETER IncludeDashboard
  Also push nornir-dashboard:latest (and version tag).

.PARAMETER DryRun
  Print docker tag/push commands without running them.
#>
param(
    [string]$Owner = '',
    [string[]]$Tags = @('dev', 'dev-cursor-base', 'prod', 'cupy'),
    [switch]$IncludeDashboard,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$DockerDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DockerDir
$versionPath = Join-Path $RepoRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) {
    Write-Error "Missing VERSION at $versionPath"
}
$ver = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($ver)) {
    Write-Error 'VERSION file is empty'
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
    if (-not $DryRun) {
        & docker @DockerCliArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "docker failed: $($DockerCliArgs -join ' ')"
        }
    }
}

$registry = "ghcr.io/$Owner/nornir"
foreach ($tag in $Tags) {
    $local = "nornir:$tag"
    Invoke-NornirDockerCli -DockerCliArgs @('tag', $local, "${registry}:$tag")
    Invoke-NornirDockerCli -DockerCliArgs @('tag', $local, "${registry}:${tag}-$ver")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${registry}:$tag")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${registry}:${tag}-$ver")
}

if ($IncludeDashboard) {
    $dashReg = "ghcr.io/$Owner/nornir-dashboard"
    Invoke-NornirDockerCli -DockerCliArgs @('tag', 'nornir-dashboard:latest', "${dashReg}:latest")
    Invoke-NornirDockerCli -DockerCliArgs @('tag', 'nornir-dashboard:latest', "${dashReg}:$ver")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${dashReg}:latest")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${dashReg}:$ver")
}

Write-Host "Done. Pushed to ghcr.io/$Owner (VERSION=$ver)."
