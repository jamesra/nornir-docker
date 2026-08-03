<#
.SYNOPSIS
  Tag and push Nornir Docker images to GitHub Container Registry (ghcr.io).

.DESCRIPTION
  Tags local images nornir:dev, nornir:dev-cursor-base, nornir:prod, nornir:cupy, and
  nornir-dashboard:latest for ghcr.io/<Owner>/... using VERSION from the monorepo root.
  Requires docker login to ghcr.io first (PAT with write:packages).

  Before each push, prints the local image Id/Created/OCI created label so you can confirm
  you are not re-pushing a stale floating tag.

.PARAMETER Owner
  GHCR namespace. Default: jamesra (or $env:NORNIR_GHCR_OWNER).

.PARAMETER Tags
  Local image tag suffixes to push. Default: dev, dev-cursor-base, prod, cupy.

.PARAMETER IncludeDashboard
  Also push nornir-dashboard:latest (and version tag).

.PARAMETER DryRun
  Print docker tag/push commands without running them.

.PARAMETER MaxAgeHours
  Warn (do not fail) if local image Created time is older than this many hours. Default: 24.
  Set to 0 to disable.
#>
param(
    [string]$Owner = '',
    [string[]]$Tags = @('dev', 'dev-cursor-base', 'prod', 'cupy'),
    [switch]$IncludeDashboard,
    [switch]$DryRun,
    [double]$MaxAgeHours = 24
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

function Assert-NornirLocalImageFresh {
    param(
        [Parameter(Mandatory)][string]$LocalTag,
        [double]$MaxAgeHours
    )
    $id = (& docker image inspect $LocalTag --format '{{.Id}}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
        Write-Error "Local image not found: $LocalTag (build it first with docker-build.ps1)"
    }
    $created = (& docker image inspect $LocalTag --format '{{.Created}}').Trim()
    $built = (& docker image inspect $LocalTag --format '{{index .Config.Labels "org.opencontainers.image.created"}}').Trim()
    $rev = (& docker image inspect $LocalTag --format '{{index .Config.Labels "org.opencontainers.image.revision"}}').Trim()
    Write-Host "  Local $LocalTag"
    Write-Host "    Id:      $id"
    Write-Host "    Created: $created"
    Write-Host "    Labels:  revision=$rev created=$built"

    if ($MaxAgeHours -gt 0) {
        try {
            $createdDt = [datetime]::Parse($created, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $ageHours = ([datetime]::UtcNow - $createdDt.ToUniversalTime()).TotalHours
            if ($ageHours -gt $MaxAgeHours) {
                Write-Warning ("    Image is {0:N1} hours old (MaxAgeHours={1}). Floating tag may be stale; rebuild with docker-build.ps1 -Images {2}" -f $ageHours, $MaxAgeHours, ($LocalTag -replace '^nornir:', ''))
            }
        }
        catch {
            Write-Warning "    Could not parse Created timestamp for age check"
        }
    }
}

$registry = "ghcr.io/$Owner/nornir"
foreach ($tag in $Tags) {
    $local = "nornir:$tag"
    Write-Host "=== Push $local ==="
    Assert-NornirLocalImageFresh -LocalTag $local -MaxAgeHours $MaxAgeHours
    Invoke-NornirDockerCli -DockerCliArgs @('tag', $local, "${registry}:$tag")
    Invoke-NornirDockerCli -DockerCliArgs @('tag', $local, "${registry}:${tag}-$ver")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${registry}:$tag")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${registry}:${tag}-$ver")
    Write-Host ''
}

if ($IncludeDashboard) {
    $dashLocal = 'nornir-dashboard:latest'
    Write-Host "=== Push $dashLocal ==="
    Assert-NornirLocalImageFresh -LocalTag $dashLocal -MaxAgeHours $MaxAgeHours
    $dashReg = "ghcr.io/$Owner/nornir-dashboard"
    Invoke-NornirDockerCli -DockerCliArgs @('tag', $dashLocal, "${dashReg}:latest")
    Invoke-NornirDockerCli -DockerCliArgs @('tag', $dashLocal, "${dashReg}:$ver")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${dashReg}:latest")
    Invoke-NornirDockerCli -DockerCliArgs @('push', "${dashReg}:$ver")
    Write-Host ''
}

Write-Host "Done. Pushed to ghcr.io/$Owner (VERSION=$ver)."
Write-Host "On the appliance, confirm a NEW digest:"
Write-Host "  docker pull ghcr.io/$Owner/nornir:cupy"
Write-Host "  docker buildx imagetools inspect ghcr.io/$Owner/nornir:cupy"
