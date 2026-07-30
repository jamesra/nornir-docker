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
            MountsDir = (Resolve-NornirHostBindPath -Path $netMountsDir)
            CredsDir  = (Resolve-NornirHostBindPath -Path $netCredsDir)
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

function Test-NornirWslUncHostPath {
    param([Parameter(Mandatory)][string]$Path)
    $normalized = $Path.Trim()
    if ($normalized -match '(?i)^\\\\wsl(\$|\.localhost)\\') { return $true }
    if ($normalized -match '(?i)^\\wsl\.localhost\\') { return $true }
    if ($normalized -match '(?i)^wsl\.localhost\\') { return $true }
    return $false
}

function Get-NornirWslDistroNames {
    <#
    .SYNOPSIS
      Return installed WSL distro names (exact spelling) from wsl -l -v.
    #>
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        return @()
    }
    try {
        $text = [string](& wsl -l -v 2>&1 | Out-String)
    }
    catch {
        return @()
    }
    $names = [System.Collections.ArrayList]::new()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\*?\s*(\S+)\s+(Running|Stopped)') {
            [void]$names.Add($Matches[1])
        }
    }
    return @($names)
}

function Resolve-NornirHostBindPath {
    <#
    .SYNOPSIS
      Normalize host bind paths for docker -v (fix WSL UNC prefix and distro name casing).
    #>
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim()
    if (-not (Test-NornirWslUncHostPath -Path $p)) {
        return $p
    }
    if ($p -match '^(?<prefix>\\\\wsl\.localhost\\)(?<distro>[^\\]+)(?<rest>\\.*)$') {
        $prefix = $Matches['prefix']
        $distroInPath = $Matches['distro']
        $rest = $Matches['rest']
    }
    elseif ($p -match '^(?<prefix>\\\\wsl\$\\)(?<distro>[^\\]+)(?<rest>\\.*)$') {
        $prefix = $Matches['prefix']
        $distroInPath = $Matches['distro']
        $rest = $Matches['rest']
    }
    elseif ($p -match '^(?<single>\\)wsl\.localhost\\(?<distro>[^\\]+)(?<rest>\\.*)$') {
        $prefix = '\\wsl.localhost\'
        $distroInPath = $Matches['distro']
        $rest = $Matches['rest']
    }
    elseif ($p -match '^wsl\.localhost\\(?<distro>[^\\]+)(?<rest>\\.*)$') {
        $prefix = '\\wsl.localhost\'
        $distroInPath = $Matches['distro']
        $rest = $Matches['rest']
    }
    else {
        return $p
    }
    $distros = Get-NornirWslDistroNames
    foreach ($d in $distros) {
        if ($d -ceq $distroInPath) {
            return "${prefix}${d}${rest}"
        }
    }
    foreach ($d in $distros) {
        if ($d -ieq $distroInPath) {
            return "${prefix}${d}${rest}"
        }
    }
    return "${prefix}${distroInPath}${rest}"
}

function Test-NornirHostPathExists {
    param([Parameter(Mandatory)][string]$Path)
    try {
        return Test-Path -LiteralPath $Path
    }
    catch {
        return $false
    }
}

function Get-NornirWslUncPathDiagnostics {
    param([Parameter(Mandatory)][string]$Path)
    $lines = [System.Collections.ArrayList]::new()
    $distros = Get-NornirWslDistroNames
    if ($distros.Count -gt 0) {
        [void]$lines.Add("Installed WSL distros (use exact name): $($distros -join ', ')")
    }
    else {
        [void]$lines.Add('Could not list WSL distros (is WSL installed?).')
    }
    if ($Path -match '(?i)^\\\\wsl(?:\$|\.localhost)\\([^\\]+)\\') {
        $distroInPath = $Matches[1]
        $matched = @($distros | Where-Object { $_ -ieq $distroInPath })
        if ($matched.Count -eq 0 -and $distros.Count -gt 0) {
            [void]$lines.Add("Distro '$distroInPath' in the path is not installed. Docker fails with distro-services/*.sock when the name is wrong.")
        }
        elseif ($matched.Count -eq 1 -and $matched[0] -cne $distroInPath) {
            [void]$lines.Add("Distro name casing may be wrong: path has '$distroInPath' but WSL reports '$($matched[0])'.")
        }
    }
    [void]$lines.Add('Docker Desktop -> Settings -> Resources -> WSL integration: enable for that distro, then wsl --shutdown and restart Docker.')
    [void]$lines.Add('Try: wsl -d <Distro> -- test -e <linux-path>  (linux path = /mnt/c/... for C:\...)')
    [void]$lines.Add('Alternate UNC prefix: \\wsl$\<Distro>\mnt\c\... instead of \\wsl.localhost\<Distro>\...')
    [void]$lines.Add('If WSL UNC stays blocked, use C:\... paths in .env (no WSL integration required for path-B CIFS).')
    return ($lines -join [Environment]::NewLine)
}

function Get-NornirRequiredCredFileNames {
    <#
    .SYNOPSIS
      Parse credentials=/run/secrets/net-creds/<name>.cred from nas-mounts.tsv.
    #>
    param([Parameter(Mandatory)][string]$MountsDir)
    $tsv = Join-Path $MountsDir 'nas-mounts.tsv'
    if (-not (Test-NornirHostPathExists -Path $tsv)) {
        return @()
    }
    $required = [System.Collections.ArrayList]::new()
    Get-Content -LiteralPath $tsv -Encoding utf8 | ForEach-Object {
        $line = $_.TrimEnd("`r")
        if (-not $line -or $line.StartsWith('#')) { return }
        if ($line -match 'credentials=/run/secrets/net-creds/([^,\s]+)') {
            [void]$required.Add($Matches[1])
        }
    }
    return @($required | Select-Object -Unique)
}

function Get-NornirNetCredsDirDiagnostics {
    param(
        [Parameter(Mandatory)][string]$CredsDir,
        [Parameter(Mandatory)][string]$MountsDir
    )
    $lines = [System.Collections.ArrayList]::new()
    $required = Get-NornirRequiredCredFileNames -MountsDir $MountsDir
    if ($required.Count -gt 0) {
        [void]$lines.Add("Required by nas-mounts.tsv: $($required -join ', ')")
        foreach ($name in $required) {
            $path = Join-Path $CredsDir $name
            if (-not (Test-NornirHostPathExists -Path $path)) {
                [void]$lines.Add("  Missing: $name")
            }
        }
    }
    else {
        [void]$lines.Add('Add one *.cred file per CIFS row in nas-mounts.tsv (credentials=/run/secrets/net-creds/<name>.cred).')
    }
    try {
        $all = @(Get-ChildItem -LiteralPath $CredsDir -File -ErrorAction Stop)
        if ($all.Count -eq 0) {
            [void]$lines.Add("Directory is empty: ${CredsDir}")
        }
        else {
            $names = ($all | ForEach-Object { $_.Name }) -join ', '
            [void]$lines.Add("Files present (none matched *.cred): $names")
            [void]$lines.Add('Rename or copy credential files to use the .cred extension (e.g. storage4.cred).')
        }
    }
    catch {
        [void]$lines.Add("Could not list ${CredsDir}: $($_.Exception.Message)")
    }
    [void]$lines.Add(@'
Example storage4.cred (LF line endings, no .txt suffix):
  username=myuser
  password=mypass
  domain=WORKGROUP
'@)
    return ($lines -join [Environment]::NewLine)
}

function Assert-NornirNetMountHostPathsReady {
    <#
    .SYNOPSIS
      Verify net-mount and cred host dirs exist before docker run (avoids opaque WSL socket errors).
    #>
    param(
        [Parameter(Mandatory)][string]$MountsDir,
        [Parameter(Mandatory)][string]$CredsDir
    )

    $issues = [System.Collections.ArrayList]::new()
    $resolvedMountsDir = Resolve-NornirHostBindPath -Path $MountsDir
    $resolvedCredsDir = Resolve-NornirHostBindPath -Path $CredsDir
    foreach ($pair in @(
            @{ Label = 'NORNIR_NET_MOUNTS_DIR_HOST'; Path = $resolvedMountsDir; NeedFile = 'nas-mounts.tsv' }
            @{ Label = 'NORNIR_NET_CREDS_DIR_HOST'; Path = $resolvedCredsDir; NeedFile = $null }
        )) {
        $hostPath = $pair.Path
        $label = $pair.Label
        if ([string]::IsNullOrWhiteSpace($hostPath)) {
            [void]$issues.Add("${label} is empty.")
            continue
        }
        $isWslUnc = Test-NornirWslUncHostPath -Path $hostPath
        if (-not (Test-NornirHostPathExists -Path $hostPath)) {
            $detail = "${label} path not accessible: ${hostPath}"
            if ($isWslUnc) {
                $detail += [Environment]::NewLine + (Get-NornirWslUncPathDiagnostics -Path $hostPath)
            }
            [void]$issues.Add($detail)
            continue
        }
        if ($pair.NeedFile) {
            $need = Join-Path $hostPath $pair.NeedFile
            if (-not (Test-NornirHostPathExists -Path $need)) {
                [void]$issues.Add("Missing ${need} (required for path-B CIFS).")
            }
        }
        if ($label -eq 'NORNIR_NET_CREDS_DIR_HOST') {
            $creds = @(Get-ChildItem -LiteralPath $hostPath -Filter '*.cred' -File -ErrorAction SilentlyContinue)
            if ($creds.Count -eq 0) {
                $detail = "No *.cred files under ${hostPath}."
                $detail += [Environment]::NewLine + (Get-NornirNetCredsDirDiagnostics -CredsDir $hostPath -MountsDir $resolvedMountsDir)
                [void]$issues.Add($detail)
            }
            else {
                $required = Get-NornirRequiredCredFileNames -MountsDir $resolvedMountsDir
                foreach ($name in $required) {
                    $need = Join-Path $hostPath $name
                    if (-not (Test-NornirHostPathExists -Path $need)) {
                        [void]$issues.Add("Missing credential file required by nas-mounts.tsv: ${need}")
                    }
                }
            }
        }
    }

    if ($issues.Count -gt 0) {
        Write-Error (@"
Host mount paths are not ready for docker bind mounts:
$($issues -join [Environment]::NewLine)

Example .run.nornir-net-mounts.env (WSL UNC — exact distro name from wsl -l -v):
  NORNIR_NET_MOUNTS_DIR_HOST=\\wsl.localhost\Ubuntu\mnt\c\Docker\Run\nornir-net-mounts\net-mounts
  NORNIR_NET_CREDS_DIR_HOST=\\wsl.localhost\Ubuntu\mnt\c\Docker\Run\nornir-net-mounts\secrets\net-creds

Or Windows paths (no WSL UNC):
  NORNIR_NET_MOUNTS_DIR_HOST=C:\Docker\Run\nornir-net-mounts\net-mounts
  NORNIR_NET_CREDS_DIR_HOST=C:\Users\<you>\.nornir\secrets\net-creds
"@)
    }
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
