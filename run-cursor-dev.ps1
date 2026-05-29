<#
.SYNOPSIS
  Run the cursor-dev Compose service (run phase counterpart to docker-build.ps1).

.DESCRIPTION
  Resolves the monorepo root, sets location there, and runs:
    docker compose -f nornir-docker/compose.cursor-dev.yaml run --rm [--gpus all] cursor-dev [@args]

  Use -Clone to run service cursor-dev-clone (named Docker volume at /workspace with fresh clone / branch sync).

  Requires `nornir-docker/.env` (for ${NORNIR_TESTDATA_HOST} substitution) or NORNIR_TESTDATA_HOST already set
  in the environment. Copy from `nornir-docker/dev/example.cursor-dev.run.env` if missing.
  Optional: set `NORNIR_REPRO_DATA_HOST` in `.env` to mount your repro corpus at `/data` (compose sets `INPUT_NORNIR_DATA=/data`).

.PARAMETER Gpu
  Adds `--gpus all` to the compose run (for CuPy/GPU in the container).

.PARAMETER Clone
  Run the cursor-dev-clone service (isolated clone in named volume) instead of cursor-dev (bind-mounted repo root).

.PARAMETER RemainingArgs
  Passed to the container after the service name (e.g. an alternate command).
#>
param(
    [switch]$Gpu,

    [switch]$Clone,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'

$DockerDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DockerDir
$envFile = Join-Path $DockerDir '.env'
$exampleRel = 'nornir-docker/dev/example.cursor-dev.run.env'

if (-not (Test-Path -LiteralPath $envFile) -and [string]::IsNullOrWhiteSpace($env:NORNIR_TESTDATA_HOST)) {
    Write-Error @"
Missing host test data configuration. Do one of:
  Copy nornir-docker/dev/example.cursor-dev.run.env to nornir-docker/.env and set NORNIR_TESTDATA_HOST, or
  set environment variable NORNIR_TESTDATA_HOST to your WSL2 path to nornir-testdata.
See $exampleRel and nornir-docker/README.md
"@
}

if (Test-Path -LiteralPath $envFile) {
    $raw = Get-Content -LiteralPath $envFile -Raw -ErrorAction SilentlyContinue
    if ($raw -match 'NORNIR_TESTDATA_HOST\s*=\s*/home/youruser/nornir-testdata') {
        Write-Warning "NORNIR_TESTDATA_HOST in nornir-docker/.env still looks like the placeholder. Update it to your real WSL2 path."
    }
}

Set-Location -LiteralPath $RepoRoot

$composeFile = Join-Path $DockerDir 'compose.cursor-dev.yaml'
$runArgs = @(
    'compose', '-f', $composeFile,
    'run', '--rm'
)
if ($Gpu) {
    $runArgs += @('--gpus', 'all')
}
$serviceName = if ($Clone) { 'cursor-dev-clone' } else { 'cursor-dev' }
$runArgs += $serviceName
foreach ($a in $RemainingArgs) {
    $runArgs += $a
}

Write-Host "docker $($runArgs -join ' ')"
& docker @runArgs
exit $LASTEXITCODE
