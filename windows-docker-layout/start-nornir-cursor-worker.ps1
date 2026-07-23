<#
.SYNOPSIS
  Thin launcher for the Nornir Cursor worker: delegates to nornir-docker/start-cursor-worker.ps1.

.DESCRIPTION
  Intended to live at D:\Docker\Builds\nornir-cursor-worker\start-nornir-cursor-worker.ps1 (symlink to this file).
  Defaults: -LiveMount -UseUniqueWorkspaceFolder with -WorkspaceRunParent D:\Docker\mounted-configs\nornir-cursor-worker so each run gets its own
  empty host folder; NORNIR_WORKSPACE_STRATEGY=clone (container clones into /workspace).
  Run env default: D:\Docker\Run\nornir-cursor-worker\nornir-cursor-worker.run.env when present.

.PARAMETER RepoRoot
  Monorepo root (parent of nornir-docker). If omitted, uses environment variable NORNIR_MONOREPO_ROOT.

.PARAMETER EnvFilePath
  Path to worker run env. Default: $NORNIR_CURSOR_WORKER_ENV_FILE, then D:\Docker\Run\nornir-cursor-worker\nornir-cursor-worker.run.env, then legacy .env.cursor-worker next to this script.

.PARAMETER WorkspaceRunParent
  Parent for per-run unique folders (nornir-cursor-worker-<stamp>-<guid>). Default: D:\Docker\mounted-configs\nornir-cursor-worker

  All other switches/parameters are forwarded to start-cursor-worker.ps1 (e.g. -Rebuild, -Gpu, -RemoveCloneAfter, -DevParityMounts).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$EnvFilePath = "",
    [string]$WorkspaceRunParent = "D:\Docker\mounted-configs\nornir-cursor-worker",
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$ForwardArgs
)

$ErrorActionPreference = "Stop"

try {
    # Final title is set by start-cursor-worker.ps1 (per-run folder leaf name).
    $Host.UI.RawUI.WindowTitle = "…"
}
catch {
}

if (-not $RepoRoot) {
    $RepoRoot = $env:NORNIR_MONOREPO_ROOT
}
if (-not $RepoRoot) {
    Write-Error @"
RepoRoot not set. Pass -RepoRoot 'D:\src\git\nornir' or set environment variable NORNIR_MONOREPO_ROOT to your monorepo root (parent of nornir-docker).
"@
    exit 1
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$worker = Join-Path $RepoRoot "nornir-docker\start-cursor-worker.ps1"
if (-not (Test-Path -LiteralPath $worker)) {
    Write-Error "start-cursor-worker.ps1 not found at: $worker (check -RepoRoot)."
    exit 1
}

if (-not $EnvFilePath) {
    if ($env:NORNIR_CURSOR_WORKER_ENV_FILE -and (Test-Path -LiteralPath $env:NORNIR_CURSOR_WORKER_ENV_FILE)) {
        $EnvFilePath = $env:NORNIR_CURSOR_WORKER_ENV_FILE
    }
    else {
        $dockerRoot = $env:NORNIR_DOCKER_USER_ROOT
        if ([string]::IsNullOrWhiteSpace($dockerRoot)) { $dockerRoot = 'D:\Docker' }
        $canonical = Join-Path $dockerRoot "Run\nornir-cursor-worker\nornir-cursor-worker.run.env"
        if (Test-Path -LiteralPath $canonical) {
            $EnvFilePath = $canonical
        }
        else {
            $EnvFilePath = Join-Path $PSScriptRoot ".env.cursor-worker"
        }
    }
}

$forward = @{
    RepoRoot                 = $RepoRoot
    EnvFilePath              = $EnvFilePath
    LiveMount                = $true
    UseUniqueWorkspaceFolder = $true
    WorkspaceRunParent       = $WorkspaceRunParent
    Gpu                      = $true
}

if ($null -eq $ForwardArgs -or $ForwardArgs.Count -eq 0) {
    & $worker @forward
}
else {
    & $worker @forward @ForwardArgs
}
