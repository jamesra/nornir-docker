<#
.SYNOPSIS
  Everyday launcher for the remote Nornir build appliance (interactive shell + path-B CIFS).

.DESCRIPTION
  Creates a unique workspace under mounted-configs\nornir-build-<version>-<stamp>, enables
  in-container CIFS/NFS from shared Run\nornir-net-mounts (CAP_SYS_ADMIN), picks nornir:cupy
  vs nornir:prod via GPU probe when -Image is omitted, and starts an interactive container.
  This is not the programmer Dev Container (run-cursor-dev) or the AI worker (start-cursor-worker).

.PARAMETER Image
  Docker image. Default: GPU probe -> nornir:cupy or nornir:prod. Use nornir:dev-cursor-base with -Clone for live packages.

.PARAMETER Version
  Version label in the workspace folder name (sanitized). Default: monorepo VERSION or 'local'.

.PARAMETER Clone
  Host-side git clone into the unique workspace (for -Image nornir:dev-cursor-base). Default image baked packages leave an empty /workspace.

.PARAMETER CloneUrl
  Git clone URL when -Clone is set. Default: origin of RepoRoot.

.PARAMETER CloneBranch
  Branch for -Clone (-b). Also used to derive -Version when -Version is omitted.

.PARAMETER RepoRoot
  Monorepo root for scripts and default clone URL. Default: parent of nornir-docker.

.PARAMETER DockerUserRoot
  Machine-local Docker root. Default: NORNIR_DOCKER_USER_ROOT or C:\Docker.

.PARAMETER Gpu
  Force --gpus all.

.PARAMETER NoGpu
  Never pass --gpus all (even if probe succeeds).

.PARAMETER SkipNetMounts
  Do not enable path-B CIFS (not recommended for production appliance).

.PARAMETER RequireNetMounts
  Fail if Run\nornir-net-mounts layout is missing (default: true when layout root exists).

.PARAMETER WorkspaceParent
  Parent for unique session folders. Default: <ROOT>\mounted-configs.

.PARAMETER Detach
  docker run -d instead of interactive.

.PARAMETER KeepContainer
  Do not pass --rm.

.PARAMETER ContainerName
  Optional container name.
#>
param(
    [string]$Image = '',
    [string]$Version = '',
    [switch]$Clone,
    [string]$CloneUrl = '',
    [string]$CloneBranch = '',
    [string]$RepoRoot = '',
    [string]$DockerUserRoot = '',
    [switch]$Gpu,
    [switch]$NoGpu,
    [switch]$SkipNetMounts,
    [switch]$RequireNetMounts,
    [string]$WorkspaceParent = '',
    [switch]$Detach,
    [switch]$KeepContainer,
    [string]$ContainerName = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NornirDockerRun.ps1')
. (Join-Path $PSScriptRoot 'NornirDevRunMounts.ps1')
. (Join-Path $PSScriptRoot 'NornirDotEnv.ps1')

$DockerUserRoot = Get-NornirDockerUserRoot -DockerUserRoot $DockerUserRoot
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

try {
    $Host.UI.RawUI.WindowTitle = 'nornir-build'
}
catch {
}

function Sanitize-NornirVersionLabel {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return 'local' }
    $s = $Raw.Trim() -replace '[\\/:*?"<>|]', '-' -replace '\s+', '-'
    $s = $s.Trim('-')
    if ([string]::IsNullOrWhiteSpace($s)) { return 'local' }
    return $s
}

# Resolve version label
if ([string]::IsNullOrWhiteSpace($Version)) {
    if (-not [string]::IsNullOrWhiteSpace($CloneBranch)) {
        $Version = $CloneBranch
    }
    else {
        $versionPath = Join-Path $RepoRoot 'VERSION'
        if (Test-Path -LiteralPath $versionPath) {
            $Version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
        }
        else {
            $Version = 'local'
        }
    }
}
$versionSafe = Sanitize-NornirVersionLabel -Raw $Version
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
if ([string]::IsNullOrWhiteSpace($WorkspaceParent)) {
    $WorkspaceParent = Join-Path $DockerUserRoot 'mounted-configs'
}
$sessionName = "nornir-build-${versionSafe}-${stamp}"
$sessionDir = Join-Path $WorkspaceParent $sessionName
Write-Host "Workspace: $sessionDir"

# Optional host clone (live packages with nornir:dev-cursor-base)
if ($Clone) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error 'git is required for -Clone'
    }
    if ([string]::IsNullOrWhiteSpace($CloneUrl)) {
        $CloneUrl = (& git -C $RepoRoot remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($CloneUrl)) {
            Write-Error 'Could not resolve -CloneUrl; pass -CloneUrl explicitly'
        }
    }
    $parent = Split-Path -Parent $sessionDir
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Force -Path $parent
    }
    $cloneArgs = @('clone', '--recurse-submodules')
    if (-not [string]::IsNullOrWhiteSpace($CloneBranch)) {
        $cloneArgs += @('-b', $CloneBranch)
    }
    $cloneArgs += @($CloneUrl, $sessionDir)
    Write-Host ("git " + ($cloneArgs -join ' '))
    & git @cloneArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'git clone failed'
    }
}
else {
    $null = New-Item -ItemType Directory -Force -Path $sessionDir
}

# Image selection
$useGpu = $false
if ($NoGpu) {
    $useGpu = $false
    Remove-Item Env:NORNIR_DOCKER_GPU -ErrorAction SilentlyContinue
}
elseif ($Gpu) {
    $useGpu = $true
    $env:NORNIR_DOCKER_GPU = '1'
}
else {
    & (Join-Path $PSScriptRoot 'Test-NornirGpu.ps1') -Quiet | Out-Null
    $useGpu = ($env:NORNIR_DOCKER_GPU -eq '1')
}

if ([string]::IsNullOrWhiteSpace($Image)) {
    if ($Clone) {
        $Image = 'nornir:dev-cursor-base'
    }
    elseif ($useGpu) {
        $Image = 'nornir:cupy'
    }
    else {
        $Image = 'nornir:prod'
    }
}
Write-Host "Image: $Image (GPU=$useGpu)"

# Shared net-mounts env
$envPaths = Get-NornirDevRunEnvFilePaths -ScriptsRepoRoot $RepoRoot -DockerUserRoot $DockerUserRoot
foreach ($p in $envPaths) {
    if (Test-Path -LiteralPath $p) {
        Import-NornirDotEnvFile -Path $p
        Write-Host "Loaded env: $p"
        break
    }
}

$netMountsRoot = Get-NornirNetMountsRunRoot -DockerUserRoot $DockerUserRoot
$tsvPath = Join-Path $netMountsRoot 'net-mounts\nas-mounts.tsv'
$requireMounts = $RequireNetMounts -or (-not $SkipNetMounts)
if (-not $SkipNetMounts) {
    if (-not (Test-Path -LiteralPath $tsvPath)) {
        if ($requireMounts) {
            Write-Error @"
Missing shared CIFS layout: $tsvPath
Run Initialize-NornirBuildAppliance.ps1 -MonorepoRoot <repo>, then edit nas-mounts.tsv and secrets\net-creds\*.cred.
Or pass -SkipNetMounts (not recommended for the production appliance).
"@
        }
    }
}

$runArgs = [System.Collections.ArrayList]::new()
[void]$runArgs.Add('run')
if (-not $KeepContainer) {
    [void]$runArgs.Add('--rm')
}
[void]$runArgs.Add('-i')
if (-not $Detach) {
    Add-NornirDockerInteractiveTtyArgs -RunArgs $runArgs
}
else {
    [void]$runArgs.Add('-d')
}
if (-not [string]::IsNullOrWhiteSpace($ContainerName)) {
    [void]$runArgs.Add('--name')
    [void]$runArgs.Add($ContainerName)
}

Add-NornirDockerGpuArgs -RunArgs $runArgs -Gpu:$useGpu -ForceGpuFlagOnly
Add-NornirDockerUlimitArgs -RunArgs $runArgs
Add-NornirDockerExtraRunArgs -RunArgs $runArgs

# MQTT: co-located dashboard via host.docker.internal
if (-not $env:NORNIR_MQTT_HOST) {
    $env:NORNIR_MQTT_HOST = 'host.docker.internal'
}
if (-not $env:NORNIR_MQTT_PORT) {
    $env:NORNIR_MQTT_PORT = '1883'
}
[void]$runArgs.Add('-e')
[void]$runArgs.Add("NORNIR_MQTT_HOST=$($env:NORNIR_MQTT_HOST)")
[void]$runArgs.Add('-e')
[void]$runArgs.Add("NORNIR_MQTT_PORT=$($env:NORNIR_MQTT_PORT)")
if ($env:NORNIR_MQTT_ENABLE) {
    [void]$runArgs.Add('-e')
    [void]$runArgs.Add("NORNIR_MQTT_ENABLE=$($env:NORNIR_MQTT_ENABLE)")
}
[void]$runArgs.Add('--add-host')
[void]$runArgs.Add('host.docker.internal:host-gateway')

# Workspace bind
[void]$runArgs.Add('-v')
[void]$runArgs.Add("${sessionDir}:/workspace")
[void]$runArgs.Add('-w')
[void]$runArgs.Add('/workspace')

# Path-B net mounts (appliance: shared nornir-net-mounts only — not programmer testdata/volumes)
if (-not $SkipNetMounts) {
    $netEnvOnly = @(Join-Path $netMountsRoot '.run.nornir-net-mounts.env')
    $resolved = Get-NornirNetMountsHostPaths -EnvPaths $netEnvOnly -DockerUserRoot $DockerUserRoot
    if (-not $resolved) {
        Write-Error @"
Path-B CIFS required but host mount dirs were not resolved.
Expected under $netMountsRoot (net-mounts + secrets\net-creds), or set
NORNIR_NET_MOUNTS_DIR_HOST / NORNIR_NET_CREDS_DIR_HOST in .run.nornir-net-mounts.env.
"@
    }
    $netMountsDir = $resolved.MountsDir
    $netCredsDir = $resolved.CredsDir
    [void]$runArgs.Add('-v')
    [void]$runArgs.Add("${netMountsDir}:/etc/nornir-net-mounts:ro")
    [void]$runArgs.Add('-v')
    [void]$runArgs.Add("${netCredsDir}:/run/secrets/net-creds:ro")
    [void]$runArgs.Add('-e')
    [void]$runArgs.Add('NORNIR_NET_MOUNTS=1')
    [void]$runArgs.Add('--cap-add')
    [void]$runArgs.Add('SYS_ADMIN')
    [void]$runArgs.Add('--cap-add')
    [void]$runArgs.Add('DAC_READ_SEARCH')
    [void]$runArgs.Add('--security-opt')
    [void]$runArgs.Add('apparmor=unconfined')
    Write-Host '  mount: in-container CIFS/NFS (path B) -> /etc/nornir-net-mounts'
}

[void]$runArgs.Add($Image)
if ($Detach) {
    [void]$runArgs.Add('sleep')
    [void]$runArgs.Add('infinity')
}
else {
    [void]$runArgs.Add('bash')
}

Write-Host ("docker " + ($runArgs -join ' '))
Write-Host 'Inside: findmnt -t cifs ; nornir-build ...'
& docker @runArgs
exit $LASTEXITCODE
