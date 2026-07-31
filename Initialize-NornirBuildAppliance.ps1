<#
.SYNOPSIS
  One-shot layout, templates, GHCR pull/retag, and co-located dashboard for the build appliance.

.DESCRIPTION
  Creates Run\nornir-net-mounts, Run\nornir-dashboard, Builds\nornir-build, mounted-configs,
  copies example templates when missing, optionally pulls images from ghcr.io, retags as
  nornir:prod / nornir:cupy / nornir-dashboard:latest, and starts the dashboard stack.

.PARAMETER ScriptsRepoRoot
  Path to nornir monorepo (parent of nornir-docker). Alias: -MonorepoRoot.
  When omitted, prompts with default = parent of this script's folder
  (i.e. parent of nornir-docker). Press Enter to accept the default.

.PARAMETER DockerUserRoot
  Machine-local Docker root. Default: NORNIR_DOCKER_USER_ROOT or C:\Docker.

.PARAMETER Owner
  GHCR namespace. Default: jamesra (or NORNIR_GHCR_OWNER).

.PARAMETER SkipPull
  Do not pull/retag images from GHCR.

.PARAMETER SkipDashboard
  Do not start compose.dashboard.yaml.

.PARAMETER SkipSymlink
  Do not create Builds\nornir-build\start-nornir-build.ps1 symlink.

.PARAMETER PromptLogin
  If docker pull fails with auth error, remind operator to docker login ghcr.io.
#>
param(
    [Alias('MonorepoRoot')]
    [string]$ScriptsRepoRoot = '',
    [string]$DockerUserRoot = '',
    [string]$Owner = '',
    [switch]$SkipPull,
    [switch]$SkipDashboard,
    [switch]$SkipSymlink,
    [switch]$PromptLogin
)

$ErrorActionPreference = 'Stop'
try {
    $Host.UI.RawUI.WindowTitle = 'nornir-build-appliance'
}
catch {
}

. (Join-Path $PSScriptRoot 'NornirDevRunMounts.ps1')
. (Join-Path $PSScriptRoot 'NornirBuildDashboard.ps1')

# Default monorepo = parent of nornir-docker (this script's directory).
$defaultScriptsRepoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptsRepoRoot)) {
    $entered = Read-Host "Nornir monorepo root [$defaultScriptsRepoRoot]"
    if ([string]::IsNullOrWhiteSpace($entered)) {
        $ScriptsRepoRoot = $defaultScriptsRepoRoot
    }
    else {
        $ScriptsRepoRoot = $entered.Trim().Trim('"').Trim("'")
    }
}

$DockerUserRoot = Get-NornirDockerUserRoot -DockerUserRoot $DockerUserRoot
if (-not (Test-Path -LiteralPath $ScriptsRepoRoot)) {
    Write-Error "Monorepo root does not exist: $ScriptsRepoRoot"
}
$ScriptsRepoRoot = (Resolve-Path -LiteralPath $ScriptsRepoRoot).ProviderPath
$dockerDir = Join-Path $ScriptsRepoRoot 'nornir-docker'
if (-not (Test-Path -LiteralPath $dockerDir)) {
    Write-Error "Expected nornir-docker under $ScriptsRepoRoot"
}

$null = Initialize-NornirBuildDashboardSubmodule -RepoRoot $ScriptsRepoRoot

if ([string]::IsNullOrWhiteSpace($Owner)) {
    if ($env:NORNIR_GHCR_OWNER -and $env:NORNIR_GHCR_OWNER.Trim()) {
        $Owner = $env:NORNIR_GHCR_OWNER.Trim()
    }
    else {
        $Owner = 'jamesra'
    }
}

$netMountsRoot = Join-Path $DockerUserRoot 'Run\nornir-net-mounts'
$dashboardRunRoot = Join-Path $DockerUserRoot 'Run\nornir-dashboard'
$buildLauncherRoot = Join-Path $DockerUserRoot 'Builds\nornir-build'
$buildSharedRoot = Join-Path $DockerUserRoot 'Builds\nornir'
$mountedConfigsRoot = Join-Path $DockerUserRoot 'mounted-configs'

Write-Host "Nornir build appliance layout under: $DockerUserRoot"
Write-Host "Reminder: set NORNIR_DOCKER_USER_ROOT=$DockerUserRoot (user or system env) if unset."
Write-Host ''

function New-LayoutDir {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Force -Path $Path
    Write-Host "  OK $Path"
}

function Copy-TemplateIfMissing {
    param(
        [string]$Source,
        [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "  Template missing (skipped): $Source"
        return
    }
    if (Test-Path -LiteralPath $Destination) {
        Write-Host "  exists (unchanged): $Destination"
        return
    }
    $destDir = Split-Path -Parent $Destination
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        $null = New-Item -ItemType Directory -Force -Path $destDir
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
    Write-Host "  created: $Destination"
}

function New-SymlinkIfPossible {
    param(
        [string]$LinkPath,
        [string]$TargetPath
    )
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        Write-Warning "  Symlink target missing: $TargetPath"
        return
    }
    $targetFull = (Resolve-Path -LiteralPath $TargetPath).Path
    if (Test-Path -LiteralPath $LinkPath) {
        Write-Host "  launcher exists: $LinkPath"
        return
    }
    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $targetFull | Out-Null
        Write-Host "  symlink: $LinkPath -> $targetFull"
        return
    }
    catch {
        Write-Warning "  Symlink unavailable ($($_.Exception.Message)); copying launcher instead"
    }
    Copy-Item -LiteralPath $targetFull -Destination $LinkPath -Force
    Write-Host "  copied: $LinkPath (edit/update from repo when launchers change)"
}

Write-Host 'Directories:'
New-LayoutDir -Path $netMountsRoot
New-LayoutDir -Path (Join-Path $netMountsRoot 'net-mounts')
New-LayoutDir -Path (Join-Path $netMountsRoot 'secrets\net-creds')
New-LayoutDir -Path $dashboardRunRoot
New-LayoutDir -Path $buildLauncherRoot
New-LayoutDir -Path $buildSharedRoot
New-LayoutDir -Path $mountedConfigsRoot
Write-Host ''

Write-Host 'Templates (created only when missing):'
Copy-TemplateIfMissing `
    -Source (Join-Path $dockerDir 'dev\example.nas-mounts.tsv') `
    -Destination (Join-Path $netMountsRoot 'net-mounts\nas-mounts.tsv')
Copy-TemplateIfMissing `
    -Source (Join-Path $dockerDir 'example.nornir-net-mounts.run.env') `
    -Destination (Join-Path $netMountsRoot '.run.nornir-net-mounts.env')
Copy-TemplateIfMissing `
    -Source (Join-Path $dockerDir 'example.dashboard.run.env') `
    -Destination (Join-Path $dashboardRunRoot 'dashboard.run.env')
Write-Host ''

if (-not $SkipSymlink) {
    Write-Host 'Launcher symlink:'
    New-SymlinkIfPossible `
        -LinkPath (Join-Path $buildLauncherRoot 'start-nornir-build.ps1') `
        -TargetPath (Join-Path $dockerDir 'start-nornir-build.ps1')
    New-SymlinkIfPossible `
        -LinkPath (Join-Path $buildLauncherRoot 'start-dashboard.ps1') `
        -TargetPath (Join-Path $dockerDir 'start-dashboard.ps1')
    Write-Host ''
}

if (-not $SkipPull) {
    Write-Host "Pull/retag from ghcr.io/$Owner ..."
    if ($PromptLogin) {
        Write-Host 'If pull fails: docker login ghcr.io -u <github-user> (PAT with read:packages)'
    }
    $pairs = @(
        @{ Remote = "ghcr.io/$Owner/nornir:prod"; Local = 'nornir:prod' }
        @{ Remote = "ghcr.io/$Owner/nornir:cupy"; Local = 'nornir:cupy' }
        @{ Remote = "ghcr.io/$Owner/nornir-dashboard:latest"; Local = 'nornir-dashboard:latest' }
    )
    foreach ($p in $pairs) {
        Write-Host "  docker pull $($p.Remote)"
        & docker pull $p.Remote
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  pull failed for $($p.Remote). Login and re-run, or build locally with docker-build.ps1."
            continue
        }
        & docker tag $p.Remote $p.Local
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  tag failed: $($p.Remote) -> $($p.Local)"
            continue
        }
        Write-Host "  tagged $($p.Local)"
    }
    Write-Host ''
}

if (-not $SkipDashboard) {
    Write-Host 'Starting co-located dashboard...'
    try {
        & (Join-Path $dockerDir 'start-dashboard.ps1') -DockerUserRoot $DockerUserRoot -RepoRoot $ScriptsRepoRoot
    }
    catch {
        Write-Warning "Dashboard start reported an error: $($_.Exception.Message)"
        Write-Warning 'If http://127.0.0.1:8087 already works (or host mosquitto owns :1883), you can ignore this and run start-dashboard.ps1 later.'
    }
    Write-Host ''
}

Write-Host 'Next (site-specific -- required):'
Write-Host "  1. Edit $($netMountsRoot)\net-mounts\nas-mounts.tsv"
Write-Host "  2. Add credentials under $($netMountsRoot)\secrets\net-creds\*.cred (chmod 600 / tight ACL)"
Write-Host "  3. Set NORNIR_NET_MOUNTS_DIR_HOST / NORNIR_NET_CREDS_DIR_HOST in .run.nornir-net-mounts.env if using UNC paths"
Write-Host ''
Write-Host 'Everyday:'
Write-Host "  & `"$buildLauncherRoot\start-nornir-build.ps1`""
Write-Host '  Dashboard: http://127.0.0.1:8087'
