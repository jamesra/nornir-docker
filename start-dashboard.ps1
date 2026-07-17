<#
.SYNOPSIS
  Start or restart the co-located Mosquitto + nornir-dashboard stack.

.DESCRIPTION
  Runs docker compose -f compose.dashboard.yaml up -d from nornir-docker.
  Loads dashboard.run.env from Run\nornir-dashboard when present (localhost binds).

.PARAMETER DockerUserRoot
  Machine-local Docker root. Default: NORNIR_DOCKER_USER_ROOT or C:\Docker.

.PARAMETER RepoRoot
  Monorepo root (parent of nornir-docker). Default: parent of this script's directory.

.PARAMETER Down
  Run compose down instead of up -d.
#>
param(
    [string]$DockerUserRoot = '',
    [string]$RepoRoot = '',
    [switch]$Down
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NornirDevRunMounts.ps1')
. (Join-Path $PSScriptRoot 'NornirDotEnv.ps1')

$DockerUserRoot = Get-NornirDockerUserRoot -DockerUserRoot $DockerUserRoot
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$composeFile = Join-Path $PSScriptRoot 'compose.dashboard.yaml'
if (-not (Test-Path -LiteralPath $composeFile)) {
    Write-Error "Missing $composeFile"
}

$runEnv = Join-Path $DockerUserRoot 'Run\nornir-dashboard\dashboard.run.env'
if (Test-Path -LiteralPath $runEnv) {
    Import-NornirDotEnvFile -Path $runEnv
    Write-Host "Loaded env: $runEnv"
}
else {
    Write-Host "No dashboard.run.env at $runEnv (using compose defaults / process env)"
}

$envFiles = @()
if (Test-Path -LiteralPath $runEnv) {
    $envFiles += '--env-file'
    $envFiles += $runEnv
}

Push-Location $PSScriptRoot
try {
    if ($Down) {
        & docker compose -f $composeFile @envFiles down
        if ($LASTEXITCODE -ne 0) {
            Write-Error "docker compose failed (exit $LASTEXITCODE)"
        }
    }
    else {
        & docker compose -f $composeFile @envFiles up -d
        if ($LASTEXITCODE -ne 0) {
            # Host mosquitto (or another stack) may already own :1883; dashboard UI alone is enough.
            try {
                $probe = Invoke-WebRequest -Uri 'http://127.0.0.1:8087/' -UseBasicParsing -TimeoutSec 3
                if ($probe.StatusCode -ge 200 -and $probe.StatusCode -lt 500) {
                    Write-Warning "compose up failed (exit $LASTEXITCODE), but dashboard already responds on :8087 — continuing"
                }
                else {
                    Write-Error "docker compose failed (exit $LASTEXITCODE)"
                }
            }
            catch {
                Write-Error "docker compose failed (exit $LASTEXITCODE): $($_.Exception.Message)"
            }
        }
    }
}
finally {
    Pop-Location
}

if (-not $Down) {
    Write-Host 'Dashboard: http://127.0.0.1:8087'
    Write-Host 'MQTT (host bind): see NORNIR_MQTT_BIND_HOST (default 0.0.0.0:1883 in compose; prefer 127.0.0.1 in dashboard.run.env)'
}
