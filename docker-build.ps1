# Build nornir:dev, nornir:dev-cursor-base, nornir:cursor-worker, nornir:prod, and nornir:cupy from the monorepo root.
# Sets OCI-related build-args from VERSION, git, and release/package-versions.yaml.
# Uses Push-Location to the repo root for docker context; on exit, error, or Ctrl+C, Pop-Location restores your invocation directory.
#
# Optional build-time knobs (non-secrets only; avoid PATs/API keys in build-args):
# From the directory you invoke this script from (current working directory), before cd to repo root:
#   build.env              — shared across all images in this run
#   .build.<id>.env         — per image; <id> is the tag with ':' replaced by '-' (e.g. .build.nornir-dev.env for nornir:dev)
# Precedence (highest wins): build.env < .build.<id>.env < script -ExtraArgs < fixed OCI/BOM args appended by this script.
# Committed nornir-docker/example.*.build.env files are templates only; this script does not merge them.

$ErrorActionPreference = 'Stop'


# Invocation directory (e.g. D:\Docker\Builds\nornir) — NOT the script install path.
$BuildEnvRoot = (Get-Location).ProviderPath
Write-Host ("Building docker images; build-arg env from invocation directory: " + (Get-Location).ProviderPath)

$RepoRoot = Split-Path -Parent $PSScriptRoot

$ScriptReservedBuildArgKeys = [string[]]@(
    'NORNIR_RELEASE',
    'SOURCE_REVISION',
    'BUILD_DATE',
    'IMAGE_SOURCE',
    'NORNIR_IMAGE_VARIANT',
    'PACKAGE_VERSIONS_JSON_B64',
    'IMAGE_TITLE',
    'IMAGE_DESCRIPTION'
)

function Parse-NornirEnvLine {
    param([string]$Line)
    $Line = $Line.TrimEnd()
    if (-not $Line.Trim() -or $Line.TrimStart().StartsWith('#')) {
        return $null
    }
    $eq = $Line.IndexOf('=')
    if ($eq -lt 1) { return $null }
    $key = $Line.Substring(0, $eq).Trim()
    if (-not $key) { return $null }
    $raw = $Line.Substring($eq + 1).TrimStart()
    if (-not $raw) {
        return @{ Key = $key; Value = '' }
    }
    $value = $null
    if ($raw.StartsWith('"')) {
        $end = $raw.IndexOf('"', 1)
        if ($end -lt 0) {
            throw "Unclosed double quote in env line: $Line"
        }
        $value = $raw.Substring(1, $end - 1)
    }
    elseif ($raw.StartsWith("'")) {
        $end = $raw.IndexOf("'", 1)
        if ($end -lt 0) {
            throw "Unclosed single quote in env line: $Line"
        }
        $value = $raw.Substring(1, $end - 1)
    }
    else {
        $value = $raw.Trim() -replace '\r$', ''
    }
    return @{ Key = $key; Value = $value }
}

function Read-NornirDotEnvFile {
    param([string]$Path)
    $out = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $out
    }
    Get-Content -LiteralPath $Path -Encoding utf8 | ForEach-Object {
        $pair = Parse-NornirEnvLine $_
        if ($null -ne $pair) {
            $out[$pair.Key] = $pair.Value
        }
    }
    return $out
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
    foreach ($rk in $ScriptReservedBuildArgKeys) {
        [void]$m.Remove($rk)
    }
    return $m
}

function Invoke-NornirDockerBuild {
    param(
        [Parameter(Mandatory)][string]$Dockerfile,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Variant,
        [Parameter()][string]$Title,
        [Parameter()][string]$Description,
        [hashtable]$ExtraArgs = @{}
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
    $dockerBuildArgs += @(
        '--build-arg', "NORNIR_RELEASE=$NornirRelease",
        '--build-arg', "SOURCE_REVISION=$SourceRevision",
        '--build-arg', "BUILD_DATE=$BuildDate",
        '--build-arg', "IMAGE_SOURCE=$ImageSource",
        '--build-arg', "NORNIR_IMAGE_VARIANT=$Variant",
        '--build-arg', "PACKAGE_VERSIONS_JSON_B64=$PackageVersionsB64",
        '--build-arg', "IMAGE_TITLE=$Title",
        '--build-arg', "IMAGE_DESCRIPTION=$Description",
        '.'
    )
    Write-Host "docker $($dockerBuildArgs -join ' ')"
    & docker @dockerBuildArgs
    if ($LASTEXITCODE -ne 0) { return $LASTEXITCODE }
    return 0
}

$exitCode = 0
try {
    Push-Location -LiteralPath $RepoRoot

$versionPath = Join-Path $RepoRoot 'VERSION'
if (-not (Test-Path $versionPath)) {
    Write-Error "Missing VERSION at $versionPath"
}
$NornirRelease = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($NornirRelease)) {
    Write-Error "VERSION file is empty"
}

$gitOut = & git -C $RepoRoot rev-parse HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $gitOut) {
    $SourceRevision = [string]$gitOut.Trim()
}
else {
    $SourceRevision = 'unknown'
}

$BuildDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$ImageSource = 'https://github.com/jamesra/nornir'

$bomScript = Join-Path $RepoRoot 'release\docker_package_versions_json.py'
$yamlPath = Join-Path $RepoRoot 'release\package-versions.yaml'
if (-not (Test-Path $bomScript)) {
    Write-Error "Missing $bomScript"
}
$venvPy = Join-Path $RepoRoot 'venv\pyre314\Scripts\python.exe'
$pythonExe = if (Test-Path $venvPy) { $venvPy } else { 'python' }
$PackageVersionsB64 = & $pythonExe $bomScript --base64 $yamlPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "docker_package_versions_json.py failed (install PyYAML: pip install pyyaml)"
}

Write-Host "Building nornir:dev ..."
$exitCode = Invoke-NornirDockerBuild `
    -Dockerfile 'nornir-docker/dev/Dockerfile' `
    -Tag 'nornir:dev' `
    -Variant 'dev' `
    -Title 'Nornir development image' `
    -Description 'Headless Nornir stack with pytest and CuPy for Python 3.14'

if ($exitCode -eq 0) {
    Write-Host "Building nornir:dev-cursor-base (no monorepo under /opt/nornir; cursor worker base) ..."
    $exitCode = Invoke-NornirDockerBuild `
        -Dockerfile 'nornir-docker/dev/Dockerfile' `
        -Tag 'nornir:dev-cursor-base' `
        -Variant 'dev' `
        -Title 'Nornir cursor worker base' `
        -Description 'Python venv + CuPy + pytest; Nornir packages from /workspace' `
        -ExtraArgs @{ 'INSTALL_MONOREPO_EDITABLES' = '0' }
}

if ($exitCode -eq 0) {
    Write-Host "Building nornir:cursor-worker ..."
    $cursorMerged = Get-NornirMergedBuildArgs -BuildEnvRoot $BuildEnvRoot -Tag 'nornir:cursor-worker' -ExtraArgs @{ 'BASE_IMAGE' = 'nornir:dev-cursor-base' }
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
    $exitCode = $LASTEXITCODE
}

if ($exitCode -eq 0) {
    Write-Host "Building nornir:prod ..."
    $exitCode = Invoke-NornirDockerBuild `
        -Dockerfile 'nornir-docker/prod/Dockerfile' `
        -Tag 'nornir:prod' `
        -Variant 'prod' `
        -Title 'Nornir production image (CPU)' `
        -Description 'Headless Nornir production stack for Python 3.14 without CuPy'
}

if ($exitCode -eq 0) {
    Write-Host "Building nornir:cupy ..."
    $exitCode = Invoke-NornirDockerBuild `
        -Dockerfile 'nornir-docker/prod/Dockerfile' `
        -Tag 'nornir:cupy' `
        -Variant 'prod-cupy' `
        -Title 'Nornir production image (CuPy)' `
        -Description 'Headless Nornir production stack for Python 3.14 with CuPy' `
        -ExtraArgs @{ 'INSTALL_CUPY' = '1' }
}

if ($exitCode -eq 0) {
    Write-Host 'Done.'
}
}
finally {
    Pop-Location
}

exit $exitCode
