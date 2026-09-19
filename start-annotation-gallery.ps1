<#
.SYNOPSIS
  Start or stop the slim annotation overlay gallery Compose stack.

.DESCRIPTION
  Runs docker compose -f compose.annotation-gallery.yaml for the fixed project
  name nornir-annotation-gallery. Loads annotation-gallery.run.env from
  Run\nornir-annotation-gallery when present.

  The gallery image is stdlib Python only (no nornir-buildmanager). Point
  GALLERY_VOLUME_DIR_HOST at a folder of volume-root links and bind storage
  so those links resolve. Weekly ExportAnnotationCrops belongs on nornir:prod
  via annotation-gallery/refresh-export.sh, not this container.

.PARAMETER DockerUserRoot
  Machine-local Docker root. Default: NORNIR_DOCKER_USER_ROOT or C:\Docker.

.PARAMETER Down
  Run compose down instead of up -d.

.PARAMETER Rebuild
  Rebuild the gallery image and recreate the container.
#>
param(
    [string]$DockerUserRoot = '',
    [switch]$Down,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NornirDotEnv.ps1')

function Get-NornirDockerUserRootLocal {
    param([string]$DockerUserRoot)
    if (-not [string]::IsNullOrWhiteSpace($DockerUserRoot)) {
        return $DockerUserRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($env:NORNIR_DOCKER_USER_ROOT)) {
        return $env:NORNIR_DOCKER_USER_ROOT
    }
    return 'C:\Docker'
}

$DockerUserRoot = Get-NornirDockerUserRootLocal -DockerUserRoot $DockerUserRoot
$composeFile = Join-Path $PSScriptRoot 'compose.annotation-gallery.yaml'
if (-not (Test-Path -LiteralPath $composeFile)) {
    Write-Error "Missing $composeFile"
}

$ComposeProject = 'nornir-annotation-gallery'
$runEnv = Join-Path $DockerUserRoot 'Run\nornir-annotation-gallery\annotation-gallery.run.env'
if (Test-Path -LiteralPath $runEnv) {
    Import-NornirDotEnvFile -Path $runEnv
    Write-Host "Loaded env: $runEnv"
}
else {
    Write-Host "No $runEnv (using process env / compose defaults)"
}

$composeArgs = @(
    'compose',
    '--project-name', $ComposeProject,
    '-f', $composeFile
)
if (Test-Path -LiteralPath $runEnv) {
    $composeArgs += @('--env-file', $runEnv)
}

if ($Down) {
    & docker @composeArgs down
    exit $LASTEXITCODE
}

if ($Rebuild) {
    & docker @composeArgs up -d --build --force-recreate
}
else {
    & docker @composeArgs up -d --build
}

$hostBind = if ([string]::IsNullOrWhiteSpace($env:GALLERY_BIND_HOST)) { '127.0.0.1' } else { $env:GALLERY_BIND_HOST }
Write-Host "Gallery UI: http://${hostBind}:8090"
