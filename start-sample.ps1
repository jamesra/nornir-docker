<#
.SYNOPSIS
  Minimal samples: build all images, run nornir-build via Compose, or open the cursor-dev shell.

.DESCRIPTION
  Run from anywhere; the script resolves the monorepo root (parent of nornir-docker/).

  - Build: delegates to docker-build.ps1 (OCI labels + BOM).
  - NornirBuild: docker compose run with repo mounted at /workspace (same convention as nd-build / docs).
  - CursorDev: delegates to run-cursor-dev.ps1 (requires nornir-docker/.env or NORNIR_TESTDATA_HOST; template dev/example.cursor-dev.run.env; optional NORNIR_REPRO_DATA_HOST for /data).

.PARAMETER Sample
  Build | NornirBuild | CursorDev | List

.PARAMETER ForwardArgs
  For NornirBuild only: remaining arguments are passed to nornir-build inside the container.
#>
param(
    [ValidateSet('Build', 'NornirBuild', 'CursorDev', 'List')]
    [string]$Sample = 'List',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardArgs
)

$ErrorActionPreference = 'Stop'
$DockerDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DockerDir

function Show-Samples {
    Write-Host @"
Nornir Docker samples (from repo root: $RepoRoot)

  Build all images (OCI + BOM):
    .\nornir-docker\start-sample.ps1 -Sample Build

  Run nornir-build in container (mounts repo at /workspace):
    .\nornir-docker\start-sample.ps1 -Sample NornirBuild -- --help

  Interactive cursor-dev shell (same as run-cursor-dev.ps1):
    .\nornir-docker\run-cursor-dev.ps1
    .\nornir-docker\start-sample.ps1 -Sample CursorDev

  Full Cursor worker (Windows layouts, env files, GPU): see start-cursor-worker.ps1
"@
}

switch ($Sample) {
    'List' {
        Show-Samples
        exit 0
    }
    'Build' {
        & (Join-Path $DockerDir 'docker-build.ps1')
        exit $LASTEXITCODE
    }
    'NornirBuild' {
        Set-Location $RepoRoot
        $composeFile = Join-Path $DockerDir 'compose.yaml'
        $vol = "${RepoRoot}:/workspace"
        $runArgs = @(
            'compose', '-f', $composeFile,
            'run', '--rm',
            '-v', $vol,
            '-w', '/workspace',
            'nornir', 'nornir-build'
        )
        foreach ($a in $ForwardArgs) { $runArgs += $a }
        Write-Host "docker $($runArgs -join ' ')"
        & docker @runArgs
        exit $LASTEXITCODE
    }
    'CursorDev' {
        & (Join-Path $DockerDir 'run-cursor-dev.ps1') @ForwardArgs
        exit $LASTEXITCODE
    }
}
