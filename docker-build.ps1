<#
.SYNOPSIS
  Build Nornir Docker images (dev, dev-cursor-base, cursor-worker, prod, cupy) from the monorepo root.

.DESCRIPTION
  Sets OCI-related build-args from VERSION, git, and release/package-versions.yaml.
  Uses Push-Location to the repo root for docker context; on exit, error, or Ctrl+C,
  Pop-Location restores your invocation directory.

  Optional build-time knobs (non-secrets only; avoid PATs/API keys in build-args):
  From the directory you invoke this script from (current working directory), before cd to repo root:
    build.env              — shared across all images in this run
    .build.<id>.env         — per image; <id> is the tag with ':' replaced by '-' (e.g. .build.nornir-dev.env for nornir:dev)
  Precedence (highest wins): build.env < .build.<id>.env < script -ExtraArgs < fixed OCI/BOM args appended by this script.
  Committed nornir-docker/example.*.build.env files are templates only; this script does not merge them.

.PARAMETER Images
  Short names or tags to build (default: all). Accepts cupy, nornir:cupy, nornir-cupy, etc.
  Catalogue order is always used. Selecting cursor-worker also builds dev-cursor-base first.

.PARAMETER NoCache
  Pass --no-cache to each docker build.
#>
param(
    [string[]]$Images = @('dev', 'dev-cursor-base', 'cursor-worker', 'prod', 'cupy'),
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NornirDockerBuild.ps1')

$Script:NornirCatalogueOrder = @('dev', 'dev-cursor-base', 'cursor-worker', 'prod', 'cupy')

function Normalize-NornirImageId {
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim().ToLowerInvariant()
    if ($n.StartsWith('nornir:')) {
        $n = $n.Substring('nornir:'.Length)
    }
    elseif ($n.StartsWith('nornir-')) {
        $n = $n.Substring('nornir-'.Length)
    }
    return $n
}

function Resolve-NornirBuildImageSet {
    param([Parameter(Mandatory)][string[]]$Requested)
    $allowed = $Script:NornirCatalogueOrder
    $selected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $Requested) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $id = Normalize-NornirImageId $raw
        if ($allowed -notcontains $id) {
            Write-Error ("Unknown image '$raw' (normalized '$id'). Allowed: " + ($allowed -join ', '))
        }
        [void]$selected.Add($id)
    }
    if ($selected.Count -eq 0) {
        Write-Error ("No images selected. Allowed: " + ($allowed -join ', '))
    }
    if ($selected.Contains('cursor-worker')) {
        [void]$selected.Add('dev-cursor-base')
    }
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $allowed) {
        if ($selected.Contains($id)) {
            $ordered.Add($id)
        }
    }
    return , $ordered.ToArray()
}

# Invocation directory (e.g. D:\Docker\Builds\nornir) — NOT the script install path.
$BuildEnvRoot = (Get-Location).ProviderPath
$selectedImages = Resolve-NornirBuildImageSet -Requested $Images
Write-Host ("Building docker images; build-arg env from invocation directory: " + (Get-Location).ProviderPath)
Write-Host ("Selected: " + (($selectedImages | ForEach-Object { "nornir:$_" }) -join ', '))

$RepoRoot = Split-Path -Parent $PSScriptRoot

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

    $ociArgs = @{
        NORNIR_RELEASE            = $NornirRelease
        SOURCE_REVISION           = $SourceRevision
        BUILD_DATE                = $BuildDate
        IMAGE_SOURCE              = $ImageSource
        PACKAGE_VERSIONS_JSON_B64 = $PackageVersionsB64
    }

    $catalogue = @(
        @{
            Id          = 'dev'
            Tag         = 'nornir:dev'
            Dockerfile  = 'nornir-docker/dev/Dockerfile'
            Variant     = 'dev'
            Title       = 'Nornir development image'
            Description = 'Headless Nornir stack with pytest and CuPy for Python 3.14'
            ExtraArgs   = @{}
            ImageVariant = 'dev'
            Kind        = 'standard'
            Banner      = 'Building nornir:dev ...'
        }
        @{
            Id          = 'dev-cursor-base'
            Tag         = 'nornir:dev-cursor-base'
            Dockerfile  = 'nornir-docker/dev/Dockerfile'
            Variant     = 'dev'
            Title       = 'Nornir cursor worker base'
            Description = 'Python venv + CuPy + pytest; Nornir packages from /workspace'
            ExtraArgs   = @{ INSTALL_MONOREPO_EDITABLES = '0' }
            ImageVariant = 'dev'
            Kind        = 'standard'
            Banner      = 'Building nornir:dev-cursor-base (no monorepo under /opt/nornir; cursor worker base) ...'
        }
        @{
            Id   = 'cursor-worker'
            Tag  = 'nornir:cursor-worker'
            Kind = 'cursor-worker'
            Banner = 'Building nornir:cursor-worker ...'
        }
        @{
            Id          = 'prod'
            Tag         = 'nornir:prod'
            Dockerfile  = 'nornir-docker/prod/Dockerfile'
            Variant     = 'prod'
            Title       = 'Nornir production image (CPU)'
            Description = 'Headless Nornir production stack for Python 3.14 without CuPy'
            ExtraArgs   = @{}
            ImageVariant = 'prod'
            Kind        = 'standard'
            Banner      = 'Building nornir:prod ...'
        }
        @{
            Id          = 'cupy'
            Tag         = 'nornir:cupy'
            Dockerfile  = 'nornir-docker/prod/Dockerfile'
            Variant     = 'prod-cupy'
            Title       = 'Nornir production image (CuPy)'
            Description = 'Headless Nornir production stack for Python 3.14 with CuPy'
            ExtraArgs   = @{ INSTALL_CUPY = '1' }
            ImageVariant = 'prod-cupy'
            Kind        = 'standard'
            Banner      = 'Building nornir:cupy ...'
        }
    )

    $selectedSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$selectedImages,
        [StringComparer]::OrdinalIgnoreCase
    )

    foreach ($spec in $catalogue) {
        if (-not $selectedSet.Contains([string]$spec.Id)) {
            continue
        }
        if ($exitCode -ne 0) {
            break
        }

        Write-Host $spec.Banner
        if ($spec.Kind -eq 'cursor-worker') {
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
            $exitCode = Invoke-NornirDockerCli -ArgumentList $cursorWorkerArgs
            if ($exitCode -eq 0) {
                $summaryOk = Write-NornirImageBuildSummary -Tag 'nornir:cursor-worker' -Version $NornirRelease
                if (-not $summaryOk) {
                    Write-Warning '  Post-build verification reported problems for nornir:cursor-worker'
                    $exitCode = 2
                }
            }
            continue
        }

        # Take [-1] so a leaked success-stream object cannot make ($exitCode -ne 0) true.
        $exitCode = [int]@(Invoke-NornirDockerBuild `
            -RepoRoot $RepoRoot `
            -BuildEnvRoot $BuildEnvRoot `
            -Dockerfile $spec.Dockerfile `
            -Tag $spec.Tag `
            -Variant $spec.Variant `
            -Title $spec.Title `
            -Description $spec.Description `
            -ExtraArgs $spec.ExtraArgs `
            -NoCache:$NoCache `
            -VersionTag $NornirRelease `
            -OciArgs ($ociArgs + @{
                NORNIR_IMAGE_VARIANT = $spec.ImageVariant
                IMAGE_TITLE          = $spec.Title
                IMAGE_DESCRIPTION    = $spec.Description
            }))[-1]
    }

    if ($exitCode -eq 0) {
        Write-Host 'Done.'
    }
}
finally {
    Pop-Location
}

exit ([int]$exitCode)
