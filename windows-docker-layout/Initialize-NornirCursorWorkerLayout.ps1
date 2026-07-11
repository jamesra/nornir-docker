<#
.SYNOPSIS
  Creates D:\Docker layout for nornir-cursor-worker and shared nornir image build scaffolding.

.DESCRIPTION
  Per docker-machine-layout: Builds/nornir (build env), Builds/nornir-cursor-worker (thin launcher),
  Run/nornir-cursor-worker (run secrets), mounted-configs/nornir-cursor-worker (agent clone workspaces).
  Copies committed example.* templates only when destination files are missing.

.PARAMETER ScriptsRepoRoot
  Path to nornir monorepo (parent of nornir-docker). Used for symlink targets and template sources.
  Alias: -MonorepoRoot.

.PARAMETER DockerUserRoot
  Machine-local Docker root. Default: D:\Docker (or $NORNIR_DOCKER_USER_ROOT when set).

.PARAMETER SkipSymlink
  Do not create launcher or build script symlinks.

.PARAMETER SkipEnvCopy
  Do not copy example env templates.

.PARAMETER WarnIfDevParityMissing
  When Run/nornir-cursor-worker.run.env contains NORNIR_WORKER_DEV_PARITY_MOUNTS=1, warn if Run/nornir-dev is absent.
#>
param(
    [Alias('MonorepoRoot')]
    [Parameter(Mandatory = $true)]
    [string]$ScriptsRepoRoot,
    [string]$DockerUserRoot = "",
    [switch]$SkipSymlink,
    [switch]$SkipEnvCopy,
    [switch]$WarnIfDevParityMissing
)

$ErrorActionPreference = "Stop"
try {
    $Host.UI.RawUI.WindowTitle = "nornir-layout"
}
catch {
}

if ([string]::IsNullOrWhiteSpace($DockerUserRoot)) {
    if ($env:NORNIR_DOCKER_USER_ROOT -and $env:NORNIR_DOCKER_USER_ROOT.Trim()) {
        $DockerUserRoot = $env:NORNIR_DOCKER_USER_ROOT.Trim()
    }
    else {
        $DockerUserRoot = "D:\Docker"
    }
}

$ScriptsRepoRoot = (Resolve-Path -LiteralPath $ScriptsRepoRoot).ProviderPath
$dockerDir = Join-Path $ScriptsRepoRoot "nornir-docker"

$buildSharedRoot = Join-Path $DockerUserRoot "Builds\nornir"
$launcherRoot = Join-Path $DockerUserRoot "Builds\nornir-cursor-worker"
$runWorkerRoot = Join-Path $DockerUserRoot "Run\nornir-cursor-worker"
$mountedConfigsRoot = Join-Path $DockerUserRoot "mounted-configs\nornir-cursor-worker"

Write-Host "Nornir cursor-worker machine layout under: $DockerUserRoot"
Write-Host ""

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
        Write-Host "  symlink exists: $LinkPath"
        return
    }
    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $targetFull | Out-Null
        Write-Host "  symlink: $LinkPath -> $targetFull"
    }
    catch {
        Write-Warning "  Could not create symlink: $($_.Exception.Message)"
        Write-Host "  mklink `"$LinkPath`" `"$targetFull`""
    }
}

Write-Host "Directories:"
New-LayoutDir -Path $buildSharedRoot
New-LayoutDir -Path $launcherRoot
New-LayoutDir -Path $runWorkerRoot
New-LayoutDir -Path $mountedConfigsRoot
Write-Host ""

if (-not $SkipEnvCopy) {
    Write-Host "Build env templates -> $buildSharedRoot"
    Copy-TemplateIfMissing -Source (Join-Path $dockerDir "example._shared.build.env") -Destination (Join-Path $buildSharedRoot "build.env")
    Copy-TemplateIfMissing -Source (Join-Path $dockerDir "dev\example.nornir-dev-cursor-base.build.env") -Destination (Join-Path $buildSharedRoot ".build.nornir-dev-cursor-base.env")
    Copy-TemplateIfMissing -Source (Join-Path $dockerDir "example.nornir-cursor-worker.build.env") -Destination (Join-Path $buildSharedRoot ".build.nornir-cursor-worker.env")
    Write-Host ""
    Write-Host "Run env -> $runWorkerRoot"
    Copy-TemplateIfMissing -Source (Join-Path $dockerDir "example.nornir-cursor-worker.run.env") -Destination (Join-Path $runWorkerRoot "nornir-cursor-worker.run.env")
    Copy-TemplateIfMissing -Source (Join-Path $dockerDir "example.nornir-cursor-worker.dev-parity.run.env") -Destination (Join-Path $runWorkerRoot "example.dev-parity.fragment.env")
    Write-Host ""
}

if (-not $SkipSymlink) {
    Write-Host "Symlinks:"
    New-SymlinkIfPossible -LinkPath (Join-Path $launcherRoot "start-nornir-cursor-worker.ps1") -TargetPath (Join-Path $dockerDir "windows-docker-layout\start-nornir-cursor-worker.ps1")
    New-SymlinkIfPossible -LinkPath (Join-Path $buildSharedRoot "build-nornir-images.ps1") -TargetPath (Join-Path $dockerDir "docker-build.ps1")
    Write-Host ""
}

$readmePath = Join-Path $launcherRoot "README.txt"
if (-not (Test-Path -LiteralPath $readmePath)) {
    @"
Nornir cursor-worker launcher (D:\Docker machine layout)

Run secrets:  $runWorkerRoot\nornir-cursor-worker.run.env
Build images: cd $buildSharedRoot then .\build-nornir-images.ps1
Agent clones: $mountedConfigsRoot\nornir-cursor-worker-<stamp>-<guid>\

Set user env:
  NORNIR_DOCKER_USER_ROOT=$DockerUserRoot
  NORNIR_MONOREPO_ROOT=$ScriptsRepoRoot  (host scripts only; not agent /workspace)

Start: & '$launcherRoot\start-nornir-cursor-worker.ps1'
"@ | Set-Content -LiteralPath $readmePath -Encoding utf8
    Write-Host "  created: $readmePath"
}

$workerRunEnv = Join-Path $runWorkerRoot "nornir-cursor-worker.run.env"
if ($WarnIfDevParityMissing -and (Test-Path -LiteralPath $workerRunEnv)) {
    $parityLine = Select-String -LiteralPath $workerRunEnv -Pattern '^\s*NORNIR_WORKER_DEV_PARITY_MOUNTS\s*=\s*1\s*$' -Quiet
    $devRunDir = Join-Path $DockerUserRoot "Run\nornir-dev"
    if ($parityLine -and -not (Test-Path -LiteralPath $devRunDir)) {
        Write-Warning "NORNIR_WORKER_DEV_PARITY_MOUNTS=1 is set but $devRunDir is missing. Configure dev volumes per nornir-docker/windows-docker-layout/NORNIR_DEV_VOLUMES.md"
    }
}

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Edit $workerRunEnv (CURSOR_API_KEY, GITHUB_TOKEN, clone URL/branch)"
Write-Host "  2. Optional: set NORNIR_WORKER_DEV_PARITY_MOUNTS=1 after configuring $DockerUserRoot\Run\nornir-dev\"
Write-Host "  3. Set user env NORNIR_DOCKER_USER_ROOT=$DockerUserRoot and NORNIR_MONOREPO_ROOT=$ScriptsRepoRoot"
Write-Host "  4. cd $buildSharedRoot; .\build-nornir-images.ps1"
Write-Host "  5. & '$launcherRoot\start-nornir-cursor-worker.ps1'"
