# Shared docker image build helpers for docker-build.ps1 and start-cursor-worker.ps1.
# Dot-source:  . (Join-Path $PSScriptRoot 'NornirDockerBuild.ps1')

. (Join-Path $PSScriptRoot 'NornirDotEnv.ps1')

$Script:NornirReservedBuildArgKeys = [string[]]@(
    'NORNIR_RELEASE',
    'SOURCE_REVISION',
    'BUILD_DATE',
    'IMAGE_SOURCE',
    'NORNIR_IMAGE_VARIANT',
    'PACKAGE_VERSIONS_JSON_B64',
    'IMAGE_TITLE',
    'IMAGE_DESCRIPTION'
)

function Get-NornirMergedBuildArgs {
    param(
        [Parameter(Mandatory)][string]$BuildEnvRoot,
        [Parameter(Mandatory)][string]$Tag,
        [hashtable]$ExtraArgs = @{}
    )
    $norm = $Tag -replace ':', '-'
    $sharedPath = Join-Path $BuildEnvRoot 'build.env'
    $perPath = Join-Path $BuildEnvRoot ".build.$norm.env"
    $sharedFull = [System.IO.Path]::GetFullPath($sharedPath)
    $perFull = [System.IO.Path]::GetFullPath($perPath)
    if (Test-Path -LiteralPath $sharedPath) {
        $sharedFull = (Resolve-Path -LiteralPath $sharedPath).Path
    }
    if (Test-Path -LiteralPath $perPath) {
        $perFull = (Resolve-Path -LiteralPath $perPath).Path
    }
    $sharedExists = Test-Path -LiteralPath $sharedPath
    $perExists = Test-Path -LiteralPath $perPath
    Write-Host "[$Tag] norm=$norm : $sharedFull : $(if ($sharedExists) { 'found and merged' } else { 'not found' })"
    Write-Host "[$Tag] norm=$norm : $perFull : $(if ($perExists) { 'found and merged' } else { 'not found' })"
    $m = @{}
    foreach ($entry in (Read-NornirDotEnvFile $sharedPath).GetEnumerator()) {
        $m[$entry.Key] = $entry.Value
    }
    foreach ($entry in (Read-NornirDotEnvFile $perPath).GetEnumerator()) {
        $m[$entry.Key] = $entry.Value
    }
    foreach ($k in $ExtraArgs.Keys) {
        $m[$k] = $ExtraArgs[$k]
    }
    foreach ($rk in $Script:NornirReservedBuildArgKeys) {
        [void]$m.Remove($rk)
    }
    return $m
}

function Invoke-NornirDockerBuild {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BuildEnvRoot,
        [Parameter(Mandatory)][string]$Dockerfile,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Variant,
        [string]$Title = '',
        [string]$Description = '',
        [hashtable]$ExtraArgs = @{},
        [hashtable]$OciArgs = @{}
    )
    $merged = Get-NornirMergedBuildArgs -BuildEnvRoot $BuildEnvRoot -Tag $Tag -ExtraArgs $ExtraArgs
    $dockerBuildArgs = @(
        'build',
        '-f', $Dockerfile,
        '-t', $Tag
    )
    foreach ($k in ($merged.Keys | Sort-Object)) {
        $dockerBuildArgs += @('--build-arg', "$k=$($merged[$k])")
    }
    if ($OciArgs.Count -gt 0) {
        foreach ($k in ($OciArgs.Keys | Sort-Object)) {
            $dockerBuildArgs += @('--build-arg', "$k=$($OciArgs[$k])")
        }
    }
    $dockerBuildArgs += '.'
    Write-Host "docker $($dockerBuildArgs -join ' ')"
    & docker @dockerBuildArgs
    if ($LASTEXITCODE -ne 0) { return $LASTEXITCODE }
    return 0
}

function Invoke-NornirCursorWorkerImagesBuild {
    <#
    .SYNOPSIS
      Quick rebuild of nornir:dev-cursor-base and nornir:cursor-worker (no OCI/BOM labels).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$BuildEnvRoot = ''
    )
    if ([string]::IsNullOrWhiteSpace($BuildEnvRoot)) {
        $BuildEnvRoot = (Get-Location).ProviderPath
    }
    Write-Host "Building from: $RepoRoot"
    Push-Location -LiteralPath $RepoRoot
    try {
        $exitCode = Invoke-NornirDockerBuild `
            -RepoRoot $RepoRoot `
            -BuildEnvRoot $BuildEnvRoot `
            -Dockerfile 'nornir-docker/dev/Dockerfile' `
            -Tag 'nornir:dev-cursor-base' `
            -Variant 'dev' `
            -ExtraArgs @{ INSTALL_MONOREPO_EDITABLES = '0' }
        if ($exitCode -ne 0) { return $exitCode }

        $cursorMerged = Get-NornirMergedBuildArgs -BuildEnvRoot $BuildEnvRoot -Tag 'nornir:cursor-worker' -ExtraArgs @{ BASE_IMAGE = 'nornir:dev-cursor-base' }
        $cursorWorkerArgs = @(
            'build',
            '-f', 'nornir-docker/Dockerfile.cursor-worker',
            '-t', 'nornir:cursor-worker'
        )
        foreach ($k in ($cursorMerged.Keys | Sort-Object)) {
            $cursorWorkerArgs += @('--build-arg', "$k=$($cursorMerged[$k])")
        }
        $cursorWorkerArgs += '.'
        Write-Host "docker $($cursorWorkerArgs -join ' ')"
        & docker @cursorWorkerArgs
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}