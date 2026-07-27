<#
.SYNOPSIS
  Start, restart, or rebuild the co-located Mosquitto + nornir-dashboard stack.

.DESCRIPTION
  Runs docker compose -f compose.dashboard.yaml for the fixed project name
  ``nornir-dashboard`` (stable volumes/networks across cwd). Loads
  dashboard.run.env from Run\nornir-dashboard when present (localhost binds).

  Use -Rebuild when deploying local nornir-builddashboard code changes during
  testing: rebuilds the nornir-dashboard image and recreates only that
  container (Mosquitto is left running so retained run meta stays available).
  Hard-refresh the browser after -Rebuild; the UI also reloads /api/runs when
  the WebSocket reconnects.

.PARAMETER DockerUserRoot
  Machine-local Docker root. Default: NORNIR_DOCKER_USER_ROOT or C:\Docker.

.PARAMETER RepoRoot
  Monorepo root (parent of nornir-docker). Default: parent of this script's directory.

.PARAMETER Down
  Run compose down instead of up -d.

.PARAMETER Rebuild
  Rebuild the nornir-dashboard image and force-recreate the dashboard container
  without restarting Mosquitto (retained MQTT meta for live runs is preserved).

.PARAMETER NoCache
  With -Rebuild, pass ``--no-cache`` to ``docker compose build`` before up so
  every layer is rebuilt (slower; use when layer cache hides code changes).
#>
param(
    [string]$DockerUserRoot = '',
    [string]$RepoRoot = '',
    [switch]$Down,
    [switch]$Rebuild,
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NornirDevRunMounts.ps1')
. (Join-Path $PSScriptRoot 'NornirDotEnv.ps1')

if ($NoCache -and -not $Rebuild) {
    Write-Error '-NoCache requires -Rebuild.'
}
if ($Down -and $Rebuild) {
    Write-Error 'Use either -Down or -Rebuild, not both.'
}

$DockerUserRoot = Get-NornirDockerUserRoot -DockerUserRoot $DockerUserRoot
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$composeFile = Join-Path $PSScriptRoot 'compose.dashboard.yaml'
if (-not (Test-Path -LiteralPath $composeFile)) {
    Write-Error "Missing $composeFile"
}

# Keep volumes/networks stable regardless of invocation directory.
$ComposeProject = 'nornir-dashboard'

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

function Invoke-DashboardCompose {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComposeArgs
    )
    # Native docker compose stdout must not enter the PowerShell pipeline: assigning
    # $code = Invoke-DashboardCompose ... would capture log lines, and ($code -ne 0)
    # would then look like a failure even when the exit code was 0.
    & docker compose -p $ComposeProject -f $composeFile @envFiles @ComposeArgs | Out-Host
    return [int]$LASTEXITCODE
}

function Test-DashboardServiceRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    $services = & docker compose -p $ComposeProject -f $composeFile @envFiles ps --status running --services $ServiceName
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $matches = @($services | Where-Object { $_.Trim() -eq $ServiceName })
    return ($matches.Count -gt 0)
}

function Test-DashboardHttp {
    try {
        $probe = Invoke-WebRequest -Uri 'http://127.0.0.1:8087/' -UseBasicParsing -TimeoutSec 3
        return ($probe.StatusCode -ge 200 -and $probe.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

Push-Location $PSScriptRoot
try {
    if ($Down) {
        $code = Invoke-DashboardCompose -ComposeArgs @('down')
        if ($code -ne 0) {
            Write-Error "docker compose failed (exit $code)"
        }
    }
    else {
        if ($Rebuild) {
            $buildArgs = @('build', 'nornir-dashboard')
            if ($NoCache) {
                $buildArgs = @('build', '--no-cache', 'nornir-dashboard')
                Write-Host 'Rebuilding nornir-dashboard image (no cache)...'
            }
            else {
                Write-Host 'Rebuilding nornir-dashboard image...'
            }
            $code = Invoke-DashboardCompose -ComposeArgs $buildArgs
            if ($code -ne 0) {
                Write-Error "docker compose build failed (exit $code)"
            }

            # Ensure broker is up without recreating it (keeps retained run meta).
            if (Test-DashboardServiceRunning -ServiceName 'mosquitto') {
                Write-Host 'Mosquitto is already running; leaving it unchanged.'
            }
            else {
                Write-Host 'Ensuring Mosquitto is up...'
                $code = Invoke-DashboardCompose -ComposeArgs @('up', '-d', 'mosquitto')
                if ($code -ne 0) {
                    if (Test-DashboardServiceRunning -ServiceName 'mosquitto') {
                        Write-Warning "mosquitto up returned exit $code, but service is already running — continuing"
                    }
                    else {
                        Write-Warning "Could not start mosquitto (exit $code). If host port :1883 is already occupied by another stack, adjust NORNIR_MQTT_BIND_HOST."
                    }
                }
            }

            # Recreate only the dashboard so it loads the new image and re-subscribes.
            Write-Host 'Removing existing nornir-dashboard container...'
            $code = Invoke-DashboardCompose -ComposeArgs @('rm', '-s', '-f', 'nornir-dashboard')
            if ($code -ne 0) {
                Write-Warning "docker compose rm returned exit $code for nornir-dashboard; continuing with recreate"
            }

            Write-Host 'Recreating nornir-dashboard container (Mosquitto left running)...'
            $code = Invoke-DashboardCompose -ComposeArgs @(
                'up', '-d', '--no-deps', 'nornir-dashboard'
            )
            if ($code -ne 0) {
                if (Test-DashboardHttp) {
                    Write-Warning "compose recreate failed (exit $code), but dashboard already responds on :8087 — continuing"
                }
                else {
                    Write-Error "docker compose failed (exit $code)"
                }
            }
        }
        else {
            $code = Invoke-DashboardCompose -ComposeArgs @('up', '-d')
            if ($code -ne 0) {
                # Host mosquitto (or another stack) may already own :1883; dashboard UI alone is enough.
                if (Test-DashboardHttp) {
                    Write-Warning "compose up failed (exit $code), but dashboard already responds on :8087 — continuing"
                }
                else {
                    Write-Error "docker compose failed (exit $code)"
                }
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
    if ($Rebuild) {
        Write-Host 'Hard-refresh the browser after -Rebuild. Live progress during the brief downtime is not replayed; retained run meta + SQLite history should reappear.'
    }
}
