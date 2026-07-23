# Dev/cursor-dev bind-mount helpers shared by docker-run-nornir-dev.ps1,
# start-cursor-worker.ps1, and start-nornir-build.ps1.
# Dot-source:  . (Join-Path $PSScriptRoot 'NornirDevRunMounts.ps1')

. (Join-Path $PSScriptRoot 'NornirDotEnv.ps1')

function Get-NornirDockerUserRoot {
    <#
    .SYNOPSIS
      Resolve NORNIR_DOCKER_USER_ROOT (default C:\Docker when unset).
    #>
    param([string]$DockerUserRoot = '')
    if (-not [string]::IsNullOrWhiteSpace($DockerUserRoot)) {
        return $DockerUserRoot.Trim()
    }
    if ($env:NORNIR_DOCKER_USER_ROOT -and $env:NORNIR_DOCKER_USER_ROOT.Trim()) {
        return $env:NORNIR_DOCKER_USER_ROOT.Trim()
    }
    return 'C:\Docker'
}

function Get-NornirNetMountsRunRoot {
    <#
    .SYNOPSIS
      Shared CIFS/NFS run tree: Run\nornir-net-mounts (not per-session).
    #>
    param([string]$DockerUserRoot = '')
    $root = Get-NornirDockerUserRoot -DockerUserRoot $DockerUserRoot
    return (Join-Path $root 'Run\nornir-net-mounts')
}

function Get-NornirDevRunEnvFilePaths {
    <#
    .SYNOPSIS
      Env file search order for mounts: nornir-net-mounts, legacy nornir-dev, repo .env.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptsRepoRoot,
        [string]$DockerUserRoot = ''
    )
    $DockerUserRoot = Get-NornirDockerUserRoot -DockerUserRoot $DockerUserRoot
    $netMountsEnv = Join-Path $DockerUserRoot 'Run\nornir-net-mounts\.run.nornir-net-mounts.env'
    $legacyDevEnv = Join-Path $DockerUserRoot 'Run\nornir-dev\.run.nornir-dev.env'
    $fallback = Join-Path $ScriptsRepoRoot 'nornir-docker\.env'
    return @($netMountsEnv, $legacyDevEnv, $fallback)
}

function Get-NornirNetMountsHostPaths {
    <#
    .SYNOPSIS
      Resolve host dirs for nas-mounts.tsv and secrets from env, with filesystem defaults.
    #>
    param(
        [Parameter(Mandatory)][string[]]$EnvPaths,
        [string]$DockerUserRoot = ''
    )
    $netMountsDir = Get-NornirDotEnvValue -Key 'NORNIR_NET_MOUNTS_DIR_HOST' -Paths $EnvPaths
    $netCredsDir = Get-NornirDotEnvValue -Key 'NORNIR_NET_CREDS_DIR_HOST' -Paths $EnvPaths
    if ($netMountsDir -and $netCredsDir) {
        return @{
            MountsDir = $netMountsDir
            CredsDir  = $netCredsDir
            FromEnv   = $true
        }
    }
    $runRoot = Get-NornirNetMountsRunRoot -DockerUserRoot $DockerUserRoot
    $defaultMounts = Join-Path $runRoot 'net-mounts'
    $defaultCreds = Join-Path $runRoot 'secrets\net-creds'
    if ((Test-Path -LiteralPath $defaultMounts) -and (Test-Path -LiteralPath $defaultCreds)) {
        return @{
            MountsDir = $defaultMounts
            CredsDir  = $defaultCreds
            FromEnv   = $false
        }
    }
    # Legacy layout under Run\nornir-dev
    $legacyRoot = Join-Path (Get-NornirDockerUserRoot -DockerUserRoot $DockerUserRoot) 'Run\nornir-dev'
    $legacyMounts = Join-Path $legacyRoot 'net-mounts'
    $legacyCreds = Join-Path $legacyRoot 'secrets\net-creds'
    if ((Test-Path -LiteralPath $legacyMounts) -and (Test-Path -LiteralPath $legacyCreds)) {
        return @{
            MountsDir = $legacyMounts
            CredsDir  = $legacyCreds
            FromEnv   = $false
        }
    }
    return $null
}

function New-NornirDevDockerRunMountArgs {
    <#
    .SYNOPSIS
      Build docker run -v / -e arguments for cursor-dev-style data mounts.
    #>
    param(
        [Parameter(Mandatory)][string[]]$EnvPaths,
        [switch]$IncludeTestOutput,
        [switch]$IncludeLegacyCode,
        [switch]$IncludeNetMounts,
        [string]$DockerUserRoot = ''
    )
    $dockerArgs = [System.Collections.ArrayList]::new()
    $notes = [System.Collections.ArrayList]::new()

    $testdataHost = Get-NornirDotEnvValue -Key 'NORNIR_TESTDATA_HOST' -Paths $EnvPaths
    if ($testdataHost) {
        [void]$dockerArgs.Add('-v')
        [void]$dockerArgs.Add("${testdataHost}:/nornir-testdata:ro")
        [void]$notes.Add('testdata -> /nornir-testdata')
    }

    $reproDataHost = Get-NornirDotEnvValue -Key 'NORNIR_REPRO_DATA_HOST' -Paths $EnvPaths
    if ($reproDataHost) {
        [void]$dockerArgs.Add('-v')
        [void]$dockerArgs.Add("${reproDataHost}:/data:ro")
        [void]$dockerArgs.Add('-e')
        [void]$dockerArgs.Add('INPUT_NORNIR_DATA=/data')
        [void]$notes.Add('repro data -> /data')
    }

    if ($IncludeTestOutput) {
        $testOutputHost = Get-NornirDotEnvValue -Key 'NORNIR_TESTOUTPUT_HOST' -Paths $EnvPaths
        if (-not $testOutputHost) {
            $testOutputHost = 'D:/nornir-test-output'
        }
        [void]$dockerArgs.Add('-v')
        [void]$dockerArgs.Add("${testOutputHost}:/tmp/nornir-test-output")
        [void]$notes.Add('test output -> /tmp/nornir-test-output')
    }

    if ($IncludeLegacyCode) {
        $legacyHost = Get-NornirDotEnvValue -Key 'NORNIR_LEGACY_CODE_HOST' -Paths $EnvPaths
        if (-not $legacyHost) {
            $legacyHost = 'D:/src/SVN/SCI/trunk'
        }
        [void]$dockerArgs.Add('-v')
        [void]$dockerArgs.Add("${legacyHost}:/legacycode:ro")
        [void]$notes.Add('legacy code -> /legacycode')
    }

    $volumesHost = Get-NornirDotEnvValue -Key 'NORNIR_VOLUMES_HOST' -Paths $EnvPaths
    if ($volumesHost) {
        [void]$dockerArgs.Add('-v')
        [void]$dockerArgs.Add("${volumesHost}:/volumes")
        [void]$notes.Add('NAS volumes -> /volumes')
    }

    if ($IncludeNetMounts) {
        $resolved = Get-NornirNetMountsHostPaths -EnvPaths $EnvPaths -DockerUserRoot $DockerUserRoot
        if ($resolved) {
            $netMountsDir = $resolved.MountsDir
            $netCredsDir = $resolved.CredsDir
            [void]$dockerArgs.Add('-v')
            [void]$dockerArgs.Add("${netMountsDir}:/etc/nornir-net-mounts:ro")
            [void]$dockerArgs.Add('-v')
            [void]$dockerArgs.Add("${netCredsDir}:/run/secrets/net-creds:ro")
            [void]$dockerArgs.Add('-e')
            [void]$dockerArgs.Add('NORNIR_NET_MOUNTS=1')
            [void]$dockerArgs.Add('--cap-add')
            [void]$dockerArgs.Add('SYS_ADMIN')
            [void]$dockerArgs.Add('--cap-add')
            [void]$dockerArgs.Add('DAC_READ_SEARCH')
            [void]$dockerArgs.Add('--security-opt')
            [void]$dockerArgs.Add('apparmor=unconfined')
            [void]$notes.Add('in-container CIFS/NFS (path B) -> /etc/nornir-net-mounts')
        }
    }

    return @{
        DockerArgs = @($dockerArgs)
        Notes      = @($notes)
        Enabled    = ($dockerArgs.Count -gt 0)
    }
}

function Add-NornirDevParityDockerRunArgs {
    <#
    .SYNOPSIS
      Same NAS/testdata mounts as cursor-dev for start-cursor-worker.ps1 -DevParityMounts.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptsRepoRoot,
        [string]$DockerUserRoot = ''
    )
    $paths = Get-NornirDevRunEnvFilePaths -ScriptsRepoRoot $ScriptsRepoRoot -DockerUserRoot $DockerUserRoot
    $existing = @($paths | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -eq 0) {
        return @{
            Enabled    = $false
            DockerArgs = @()
            Notes      = @()
        }
    }
    $mounts = New-NornirDevDockerRunMountArgs -EnvPaths $existing `
        -IncludeTestOutput -IncludeLegacyCode -IncludeNetMounts `
        -DockerUserRoot $DockerUserRoot
    return $mounts
}
