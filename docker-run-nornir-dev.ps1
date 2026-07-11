<#
.SYNOPSIS
  Run the nornir:dev image with GPU, repo mount, env from the invocation directory.

.DESCRIPTION
  Environment files are read from the directory you invoke this script from (current working directory), not from the script folder:
    - .run.nornir-dev.env  (required)
    - secrets.env          (required)

  Later file wins on duplicate keys (same as docker --env-file order).

  The workspace bind mount uses the folder containing this script as the host path (default repo root for this script is nornir-docker/).

  Optional variables in the env files:
    NORNIR_TESTDATA_HOST     — if set, bind-mounts to /nornir-testdata (read-only)
    NORNIR_REPRO_DATA_HOST   — if set, bind-mounts to /data (read-only); script also sets INPUT_NORNIR_DATA=/data
    NORNIR_VOLUMES_HOST      — if set, bind-mounts to /volumes and /storage4 (read-write); WSL path to \\192.168.0.199\Data\Volumes
    NORNIR_DEV_PORT_PUBLISH  — semicolon-separated host:container pairs, e.g. "8888:8888;9000:9000"

  Set TESTINPUTPATH / TESTOUTPUTPATH / NORNIR_HEADLESS in .run.nornir-dev.env to match .cursor/environment.json if needed.

  The shell working directory is restored to the invocation directory when the script exits (including Ctrl+C while docker runs).

.PARAMETER Detach
  Run with -d instead of -it.

.PARAMETER Image
  Override image tag (default: nornir:dev).

.PARAMETER RemainingArgs
  Command in the container (default: bash -l).
#>
param(
    [switch]$Detach,
    [string]$Image = 'nornir:dev',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'

$InvokeRoot = (Get-Location).ProviderPath
$RunEnv = Join-Path $InvokeRoot '.run.nornir-dev.env'
$SecretsEnv = Join-Path $InvokeRoot 'secrets.env'

if (-not (Test-Path -LiteralPath $RunEnv)) {
    Write-Error "Missing required file in invocation directory: $RunEnv"
}
if (-not (Test-Path -LiteralPath $SecretsEnv)) {
    Write-Error "Missing required file in invocation directory: $SecretsEnv"
}

$RepoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath

function Add-DockerPublishArgs {
    param([string]$Map)
    $out = @()
    if ([string]::IsNullOrWhiteSpace($Map)) { return $out }
    foreach ($seg in $Map -split ';') {
        $t = $seg.Trim()
        if (-not $t) { continue }
        $out += @('-p', $t)
    }
    return $out
}

function Get-EnvFileValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        $line = $line.TrimEnd()
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*([^=#\s]+)\s*=\s*(.*)$') {
            if ($Matches[1] -eq $Key) {
                $v = $Matches[2].Trim()
                if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
                    return $v.Substring(1, $v.Length - 2)
                }
                return $v
            }
        }
    }
    return $null
}

$testdataHost = Get-EnvFileValue -Path $RunEnv -Key 'NORNIR_TESTDATA_HOST'
if (-not $testdataHost) {
    $testdataHost = Get-EnvFileValue -Path $SecretsEnv -Key 'NORNIR_TESTDATA_HOST'
}

$reproDataHost = Get-EnvFileValue -Path $RunEnv -Key 'NORNIR_REPRO_DATA_HOST'
if (-not $reproDataHost) {
    $reproDataHost = Get-EnvFileValue -Path $SecretsEnv -Key 'NORNIR_REPRO_DATA_HOST'
}

$volumesHost = Get-EnvFileValue -Path $RunEnv -Key 'NORNIR_VOLUMES_HOST'
if (-not $volumesHost) {
    $volumesHost = Get-EnvFileValue -Path $SecretsEnv -Key 'NORNIR_VOLUMES_HOST'
}

$netMountsDir = Get-EnvFileValue -Path $RunEnv -Key 'NORNIR_NET_MOUNTS_DIR_HOST'
if (-not $netMountsDir) {
    $netMountsDir = Get-EnvFileValue -Path $SecretsEnv -Key 'NORNIR_NET_MOUNTS_DIR_HOST'
}
$netCredsDir = Get-EnvFileValue -Path $RunEnv -Key 'NORNIR_NET_CREDS_DIR_HOST'
if (-not $netCredsDir) {
    $netCredsDir = Get-EnvFileValue -Path $SecretsEnv -Key 'NORNIR_NET_CREDS_DIR_HOST'
}

$portMap = Get-EnvFileValue -Path $RunEnv -Key 'NORNIR_DEV_PORT_PUBLISH'
if (-not $portMap) {
    $portMap = Get-EnvFileValue -Path $SecretsEnv -Key 'NORNIR_DEV_PORT_PUBLISH'
}

$exitCode = 0
try {
    $dockerArgs = @('run', '--rm', '--gpus', 'all', '--init')
    if (-not $Detach) {
        $dockerArgs += @('-i', '-t')
    }
    else {
        $dockerArgs += '-d'
    }

    $dockerArgs += @(
        '-v', "${RepoRoot}:/workspace",
        '-w', '/workspace'
    )

    if ($testdataHost) {
        $dockerArgs += @('-v', "${testdataHost}:/nornir-testdata:ro")
    }

    if ($reproDataHost) {
        $dockerArgs += @('-v', "${reproDataHost}:/data:ro", '-e', 'INPUT_NORNIR_DATA=/data')
    }

    if ($volumesHost) {
        $dockerArgs += @('-v', "${volumesHost}:/volumes", '-v', "${volumesHost}:/storage4")
    }

    if ($netMountsDir -and $netCredsDir) {
        $dockerArgs += @(
            '--cap-add', 'SYS_ADMIN',
            '--cap-add', 'DAC_READ_SEARCH',
            '--security-opt', 'apparmor=unconfined',
            '-v', "${netMountsDir}:/etc/nornir-net-mounts:ro",
            '-v', "${netCredsDir}:/run/secrets/net-creds:ro",
            '-e', 'NORNIR_NET_MOUNTS=1'
        )
        # Prefer entry script that applies nas-mounts.tsv (image has mount-network-shares.sh).
        if (-not $RemainingArgs -or $RemainingArgs.Count -eq 0) {
            $RemainingArgs = @('/usr/local/bin/cursor-dev-entry.sh', 'bash', '-l')
        }
    }

    $dockerArgs += @('--env-file', $RunEnv, '--env-file', $SecretsEnv)
    $dockerArgs += (Add-DockerPublishArgs -Map $portMap)
    $dockerArgs += $Image

    if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
        $dockerArgs += $RemainingArgs
    }
    else {
        $dockerArgs += @('bash', '-l')
    }

    Write-Host "docker $($dockerArgs -join ' ')"
    & docker @dockerArgs
    $exitCode = $LASTEXITCODE
}
finally {
    Set-Location -LiteralPath $InvokeRoot
}

exit $exitCode
