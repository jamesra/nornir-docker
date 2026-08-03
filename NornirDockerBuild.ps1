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

function Invoke-NornirDockerCli {
    <#
    .SYNOPSIS
      Run docker; show stdout on the host and return only the native exit code.

    .DESCRIPTION
      Native docker stdout is on the success stream. If a caller assigns
      `$code = SomeFunction` and SomeFunction runs `& docker ...` without
      redirecting, that stdout is captured into `$code` with the intended
      return value. Comparisons like `if ($code -ne 0)` then treat the
      array as failure and abort multi-image builds. Pipe through Out-Host
      so progress stays visible without polluting the return value.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    & docker @ArgumentList | Out-Host
    return [int]$LASTEXITCODE
}

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

function Write-NornirImageBuildSummary {
    <#
    .SYNOPSIS
      Print Id/Created/OCI labels for a local image and optionally apply a version tag.
    #>
    param(
        [Parameter(Mandatory)][string]$Tag,
        [string]$Version = '',
        [string]$ExpectedBuildDate = '',
        [string]$ExpectedRevision = ''
    )
    $id = (& docker image inspect $Tag --format '{{.Id}}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
        Write-Warning "  Could not inspect $Tag after build"
        return $false
    }
    $created = (& docker image inspect $Tag --format '{{.Created}}').Trim()
    $rev = (& docker image inspect $Tag --format '{{index .Config.Labels "org.opencontainers.image.revision"}}').Trim()
    $built = (& docker image inspect $Tag --format '{{index .Config.Labels "org.opencontainers.image.created"}}').Trim()
    $verLabel = (& docker image inspect $Tag --format '{{index .Config.Labels "org.opencontainers.image.version"}}').Trim()
    Write-Host "  Id:      $id"
    Write-Host "  Created: $created"
    Write-Host "  Labels:  version=$verLabel revision=$rev created=$built"

    $ok = $true
    if ($ExpectedBuildDate -and $built -ne $ExpectedBuildDate) {
        Write-Warning "  BUILD_DATE label mismatch: expected '$ExpectedBuildDate', got '$built' (image may be a stale cache hit)"
        $ok = $false
    }
    if ($ExpectedRevision -and $ExpectedRevision -ne 'unknown' -and $rev -ne $ExpectedRevision) {
        Write-Warning "  SOURCE_REVISION label mismatch: expected '$ExpectedRevision', got '$rev'"
        $ok = $false
    }

    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $suffix = $Tag.Split(':')[-1]
        $versionTag = "nornir:${suffix}-$Version"
        $tagExit = Invoke-NornirDockerCli -ArgumentList @('tag', $Tag, $versionTag)
        if ($tagExit -ne 0) {
            Write-Warning "  Failed to tag $versionTag"
            $ok = $false
        }
        else {
            Write-Host "  Also tagged: $versionTag"
        }
    }
    return [bool]$ok
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
        [hashtable]$OciArgs = @{},
        [switch]$NoCache,
        [string]$VersionTag = ''
    )
    $merged = Get-NornirMergedBuildArgs -BuildEnvRoot $BuildEnvRoot -Tag $Tag -ExtraArgs $ExtraArgs
    $dockerBuildArgs = @(
        'build',
        '-f', $Dockerfile,
        '-t', $Tag
    )
    if ($NoCache) {
        $dockerBuildArgs += '--no-cache'
    }
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
    $buildExit = Invoke-NornirDockerCli -ArgumentList $dockerBuildArgs
    if ($buildExit -ne 0) { return $buildExit }

    $expectedDate = ''
    $expectedRev = ''
    if ($OciArgs.ContainsKey('BUILD_DATE')) { $expectedDate = [string]$OciArgs['BUILD_DATE'] }
    if ($OciArgs.ContainsKey('SOURCE_REVISION')) { $expectedRev = [string]$OciArgs['SOURCE_REVISION'] }
    $summaryOk = Write-NornirImageBuildSummary `
        -Tag $Tag `
        -Version $VersionTag `
        -ExpectedBuildDate $expectedDate `
        -ExpectedRevision $expectedRev
    if (-not $summaryOk) {
        Write-Warning "  Post-build verification reported problems for $Tag"
        return 2
    }
    return 0
}

function Invoke-NornirCursorWorkerImagesBuild {
    <#
    .SYNOPSIS
      Quick rebuild of nornir:dev-cursor-base and nornir:cursor-worker (no OCI/BOM labels).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$BuildEnvRoot = '',
        [switch]$NoCache
    )
    if ([string]::IsNullOrWhiteSpace($BuildEnvRoot)) {
        $BuildEnvRoot = (Get-Location).ProviderPath
    }
    Write-Host "Building from: $RepoRoot"
    Push-Location -LiteralPath $RepoRoot
    try {
        $exitCode = [int]@(Invoke-NornirDockerBuild `
            -RepoRoot $RepoRoot `
            -BuildEnvRoot $BuildEnvRoot `
            -Dockerfile 'nornir-docker/dev/Dockerfile' `
            -Tag 'nornir:dev-cursor-base' `
            -Variant 'dev' `
            -ExtraArgs @{ INSTALL_MONOREPO_EDITABLES = '0' } `
            -NoCache:$NoCache)[-1]
        if ($exitCode -ne 0) { return $exitCode }

        $cursorMerged = Get-NornirMergedBuildArgs -BuildEnvRoot $BuildEnvRoot -Tag 'nornir:cursor-worker' -ExtraArgs @{ BASE_IMAGE = 'nornir:dev-cursor-base' }
        $cursorWorkerArgs = @(
            'build',
            '-f', 'nornir-docker/Dockerfile.cursor-worker',
            '-t', 'nornir:cursor-worker'
        )
        if ($NoCache) {
            $cursorWorkerArgs += '--no-cache'
        }
        foreach ($k in ($cursorMerged.Keys | Sort-Object)) {
            $cursorWorkerArgs += @('--build-arg', "$k=$($cursorMerged[$k])")
        }
        $cursorWorkerArgs += '.'
        Write-Host "docker $($cursorWorkerArgs -join ' ')"
        return (Invoke-NornirDockerCli -ArgumentList $cursorWorkerArgs)
    }
    finally {
        Pop-Location
    }
}
