<#
.SYNOPSIS
  Shared dev-container mount parity for docker run (cursor-worker and similar).

.DESCRIPTION
  When -DevParityMounts or NORNIR_WORKER_DEV_PARITY_MOUNTS=1 is set, reads mount paths from
  $NORNIR_DOCKER_USER_ROOT/Run/nornir-dev/.run.nornir-dev.env (primary) and
  $ScriptsRepoRoot/nornir-docker/.env (fallback for unset keys). Mirrors compose.cursor-dev.yaml binds.
#>

function Get-NornirDotEnvValueFromFile {
    param(
        [string]$Path,
        [string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        $line = $line.TrimEnd()
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*([^=#\s]+)\s*=\s*(.*)$') {
            if ($Matches[1] -ne $Key) { continue }
            $v = $Matches[2].Trim()
            if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
                return $v.Substring(1, $v.Length - 2)
            }
            return $v
        }
    }
    return $null
}

function Get-NornirDevParityEnvValue {
    param(
        [string]$Key,
        [string[]]$SourcePaths
    )
    foreach ($path in $SourcePaths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $v = Get-NornirDotEnvValueFromFile -Path $path -Key $Key
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return $null
}

function Get-NornirDevParityEnvSources {
    param(
        [string]$ScriptsRepoRoot,
        [string]$DockerUserRoot = ""
    )
    $sources = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($DockerUserRoot)) {
        $DockerUserRoot = $env:NORNIR_DOCKER_USER_ROOT
    }
    if ($DockerUserRoot -and $DockerUserRoot.Trim()) {
        $devRun = Join-Path $DockerUserRoot.Trim() 'Run\nornir-dev\.run.nornir-dev.env'
        if (Test-Path -LiteralPath $devRun) {
            $sources.Add($devRun)
        }
    }
    if ($ScriptsRepoRoot -and (Test-Path -LiteralPath $ScriptsRepoRoot)) {
        $composeEnv = Join-Path $ScriptsRepoRoot 'nornir-docker\.env'
        if (Test-Path -LiteralPath $composeEnv) {
            $sources.Add($composeEnv)
        }
    }
    return @($sources)
}

function Add-NornirDevParityDockerRunArgs {
    <#
    .OUTPUTS
      Hashtable with Keys: DockerArgs (string[]), Enabled (bool), Notes (string[])
    #>
    param(
        [string]$ScriptsRepoRoot,
        [string]$DockerUserRoot = ""
    )

    $notes = [System.Collections.Generic.List[string]]::new()
    $args = [System.Collections.ArrayList]@()
    $sources = Get-NornirDevParityEnvSources -ScriptsRepoRoot $ScriptsRepoRoot -DockerUserRoot $DockerUserRoot

    if ($sources.Count -eq 0) {
        return @{
            DockerArgs = @()
            Enabled    = $false
            Notes      = @('Dev parity: no nornir-dev run env or nornir-docker/.env found')
        }
    }

    function _Get([string]$Key) {
        Get-NornirDevParityEnvValue -Key $Key -SourcePaths $sources
    }

    $testdataHost = _Get 'NORNIR_TESTDATA_HOST'
    if ($testdataHost) {
        [void]$args.Add('-v')
        [void]$args.Add("${testdataHost}:/nornir-testdata:ro")
        [void]$args.Add('-e')
        [void]$args.Add('TESTINPUTPATH=/nornir-testdata')
        [void]$notes.Add("testdata -> /nornir-testdata")
    }

    $reproDataHost = _Get 'NORNIR_REPRO_DATA_HOST'
    if ($reproDataHost) {
        [void]$args.Add('-v')
        [void]$args.Add("${reproDataHost}:/data:ro")
        [void]$args.Add('-e')
        [void]$args.Add('INPUT_NORNIR_DATA=/data')
        [void]$notes.Add('repro data -> /data')
    }

    $testoutputHost = _Get 'NORNIR_TESTOUTPUT_HOST'
    if (-not $testoutputHost) { $testoutputHost = 'D:/nornir-test-output' }
    [void]$args.Add('-v')
    [void]$args.Add("${testoutputHost}:/tmp/nornir-test-output")
    [void]$args.Add('-e')
    [void]$args.Add('TESTOUTPUTPATH=/tmp/nornir-test-output')
    [void]$notes.Add('test output -> /tmp/nornir-test-output')

    $legacyHost = _Get 'NORNIR_LEGACY_CODE_HOST'
    if (-not $legacyHost) { $legacyHost = 'D:/src/SVN/SCI/trunk' }
    if (Test-Path -LiteralPath $legacyHost) {
        [void]$args.Add('-v')
        [void]$args.Add("${legacyHost}:/legacycode:ro")
        [void]$notes.Add('legacy code -> /legacycode')
    }

    $volumesHost = _Get 'NORNIR_VOLUMES_HOST'
    if ($volumesHost) {
        [void]$args.Add('-v')
        [void]$args.Add("${volumesHost}:/volumes")
        [void]$notes.Add('NAS volumes -> /volumes')
    }

    $netMountsDir = _Get 'NORNIR_NET_MOUNTS_DIR_HOST'
    $netCredsDir = _Get 'NORNIR_NET_CREDS_DIR_HOST'
    if ($netMountsDir -and $netCredsDir) {
        [void]$args.Add('--cap-add')
        [void]$args.Add('SYS_ADMIN')
        [void]$args.Add('--cap-add')
        [void]$args.Add('DAC_READ_SEARCH')
        [void]$args.Add('--security-opt')
        [void]$args.Add('apparmor:unconfined')
        [void]$args.Add('-v')
        [void]$args.Add("${netMountsDir}:/etc/nornir-net-mounts:ro")
        [void]$args.Add('-v')
        [void]$args.Add("${netCredsDir}:/run/secrets/net-creds:ro")
        [void]$args.Add('-e')
        [void]$args.Add('NORNIR_NET_MOUNTS=1')
        [void]$notes.Add('in-container CIFS/NFS manifest enabled')
    }

    $importCache = _Get 'NORNIR_IMPORT_CACHE_PATH'
    if ($importCache) {
        [void]$args.Add('-e')
        [void]$args.Add("NORNIR_IMPORT_CACHE_PATH=$importCache")
    }
    else {
        [void]$args.Add('-e')
        [void]$args.Add('NORNIR_IMPORT_CACHE_PATH=/tmp/nornir-test-output/ImportCache')
    }

    $gpuBatchMb = _Get 'NORNIR_GPU_PYRAMID_BATCH_MB'
    if ($gpuBatchMb) {
        [void]$args.Add('-e')
        [void]$args.Add("NORNIR_GPU_PYRAMID_BATCH_MB=$gpuBatchMb")
    }

    $cudaPath = _Get 'CUDA_PATH'
    if ($cudaPath) {
        [void]$args.Add('-e')
        [void]$args.Add("CUDA_PATH=$cudaPath")
    }
    else {
        [void]$args.Add('-e')
        [void]$args.Add('CUDA_PATH=/usr/local/cuda')
    }

    [void]$args.Add('-e')
    [void]$args.Add('NORNIR_HEADLESS=1')

    return @{
        DockerArgs = @($args)
        Enabled    = ($args.Count -gt 0)
        Notes      = @($notes)
    }
}
