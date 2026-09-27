<#
.SYNOPSIS
  Pull Nornir images from GHCR and retag them for local scripts and Compose.

.DESCRIPTION
  Pulls ghcr.io/<Owner>/<repo>:<tag> and tags the local name (nornir:prod,
  nornir-dashboard:latest, and so on). A tag is unchanged when the local
  image's RepoDigests already contain the digest from `docker buildx imagetools
  inspect`. Unchanged tags are skipped. Requires docker login to ghcr.io first
  for private packages (PAT with read:packages).

  With no -Images or -Tags, pulls the build-appliance set: prod, cupy.
  -IncludeDashboard adds nornir-dashboard:latest only. docker-build.ps1 and
  docker-push.ps1 default to the whole catalogue; this script does not, so a
  refresh does not download dev images or the CUDA trainer.

  Catalogue (short name accepted by -Images / -Tags):
    dev, dev-cursor-base, cursor-worker, prod, cupy
    dashboard, gallery, sam2-trainer

  Not in this catalogue: eclipse-mosquitto:2 (public), and VikingLegacy images
  (segmentation-server, grpc-annotation-service, section-correction-service,
  identity-standalone, identity-webapi, identity-all-services).

.PARAMETER Owner
  GHCR namespace. Default: jamesra (or $env:NORNIR_GHCR_OWNER).

.PARAMETER Images
  Catalogue names or local tags to pull. Default, when -Tags is also empty:
  prod, cupy. Examples: dev, nornir:cupy, dashboard, gallery, sam2-trainer.

.PARAMETER Tags
  Same as -Images. Matches docker-build.ps1 and docker-push.ps1.

.PARAMETER IncludeDashboard
  Also pull and retag nornir-dashboard:latest. Does not add gallery or
  sam2-trainer; pass those with -Images.

.PARAMETER List
  Print each catalogue image as clean, dirty, missing, or unknown. Do not pull.
  With no -Images or -Tags, lists the whole catalogue and marks prod and cupy
  as the default pull.

.PARAMETER Help
  Show this help and exit. `-?` does the same.

.PARAMETER Force
  Pull selected images even when the remote digest already matches.

.PARAMETER DryRun
  Print docker pull/tag commands without running them. Still skips unchanged
  images unless -Force.

.PARAMETER AlsoVersioned
  Also pull ghcr.io/...:<tag>-<VERSION> using VERSION from the monorepo root.
  The floating tag is still used for the local retag unless -PreferVersioned.

.PARAMETER PreferVersioned
  Retag local names from the versioned remote tag instead of the floating tag.
  Implies -AlsoVersioned.

.PARAMETER ContinueOnError
  Warn and continue if a pull fails. Without this switch, the first failed
  pull stops the script.

.EXAMPLE
  .\nornir-docker\docker-pull.ps1 -Help

.EXAMPLE
  .\nornir-docker\docker-pull.ps1 -List

.EXAMPLE
  .\nornir-docker\docker-pull.ps1 -IncludeDashboard -ContinueOnError

.EXAMPLE
  .\nornir-docker\docker-pull.ps1 -Images dev,gallery
#>
param(
    [string]$Owner = '',
    [string[]]$Images,
    [string[]]$Tags,
    [switch]$IncludeDashboard,
    [switch]$List,
    [switch]$Help,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$AlsoVersioned,
    [switch]$PreferVersioned,
    [switch]$ContinueOnError
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help -Name $PSCommandPath -Full
    return
}

$DockerDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DockerDir

if ($PreferVersioned) {
    $AlsoVersioned = $true
}

$ver = ''
$versionPath = Join-Path $RepoRoot 'VERSION'
if (Test-Path -LiteralPath $versionPath) {
    $ver = (Get-Content -LiteralPath $versionPath -Raw).Trim()
}
if (($AlsoVersioned -or $PreferVersioned) -and [string]::IsNullOrWhiteSpace($ver)) {
    Write-Error "Missing VERSION at $versionPath (needed for -AlsoVersioned / -PreferVersioned)"
}

if ([string]::IsNullOrWhiteSpace($Owner)) {
    if ($env:NORNIR_GHCR_OWNER -and $env:NORNIR_GHCR_OWNER.Trim()) {
        $Owner = $env:NORNIR_GHCR_OWNER.Trim()
    }
    else {
        $Owner = 'jamesra'
    }
}

function Invoke-NornirDockerCli {
    param([Parameter(Mandatory)][string[]]$DockerCliArgs)
    Write-Host ("docker " + ($DockerCliArgs -join ' '))
    if ($DryRun) {
        return $true
    }
    & docker @DockerCliArgs
    if ($LASTEXITCODE -ne 0) {
        $msg = "docker failed: $($DockerCliArgs -join ' ')"
        if ($ContinueOnError) {
            Write-Warning $msg
            if (($DockerCliArgs -join ' ') -match '\bpull\b') {
                Write-Warning 'Auth likely required: docker login ghcr.io -u <github-user> (PAT with read:packages)'
            }
            return $false
        }
        Write-Error $msg
    }
    return $true
}

function Get-GhcrTagDigest {
    param([Parameter(Mandatory)][string]$Reference)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker buildx imagetools inspect $Reference 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        if ($output -match 'not found|manifest unknown|no such manifest|NAME_UNKNOWN') {
            return @{ Status = 'absent'; Digest = '' }
        }
        $detail = ($output -replace '\s+', ' ').Trim()
        if ($detail.Length -gt 180) {
            $detail = $detail.Substring(0, 180)
        }
        return @{ Status = 'error'; Digest = ''; Detail = $detail }
    }
    $match = [regex]::Match($output, 'Digest:\s+(sha256:[0-9a-f]{64})')
    if (-not $match.Success) {
        return @{ Status = 'error'; Digest = ''; Detail = 'imagetools inspect returned no digest' }
    }
    return @{ Status = 'ok'; Digest = $match.Groups[1].Value; Detail = '' }
}

function Get-LocalRepoDigests {
    param([Parameter(Mandatory)][string]$LocalTag)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $json = & docker image inspect $LocalTag --format '{{json .RepoDigests}}' 2>$null
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }
    $parsed = $json | ConvertFrom-Json
    if ($null -eq $parsed) {
        return @()
    }
    return @($parsed)
}

function Test-RemoteDigestMatchesLocal {
    param(
        [Parameter(Mandatory)][string]$RemoteRepo,
        [string[]]$RepoDigests,
        $Remote
    )
    if ($Remote.Status -ne 'ok') {
        return $false
    }
    $needle = "${RemoteRepo}@$($Remote.Digest)"
    return $RepoDigests -contains $needle
}

function Get-PullCatalogue {
    param(
        [Parameter(Mandatory)][string]$OwnerName,
        [string]$Version
    )
    $nornir = "ghcr.io/$OwnerName/nornir"
    $versionSuffix = if ([string]::IsNullOrWhiteSpace($Version)) { '' } else { $Version }
    return @(
        @{
            Key = 'dev'; Local = 'nornir:dev'; RemoteRepo = $nornir; Floating = 'dev'
            VersionTag = $(if ($versionSuffix) { "dev-$versionSuffix" } else { '' })
            Aliases = @('dev', 'nornir:dev')
        },
        @{
            Key = 'dev-cursor-base'; Local = 'nornir:dev-cursor-base'; RemoteRepo = $nornir; Floating = 'dev-cursor-base'
            VersionTag = $(if ($versionSuffix) { "dev-cursor-base-$versionSuffix" } else { '' })
            Aliases = @('dev-cursor-base', 'nornir:dev-cursor-base')
        },
        @{
            Key = 'cursor-worker'; Local = 'nornir:cursor-worker'; RemoteRepo = $nornir; Floating = 'cursor-worker'
            VersionTag = $(if ($versionSuffix) { "cursor-worker-$versionSuffix" } else { '' })
            Aliases = @('cursor-worker', 'nornir:cursor-worker')
        },
        @{
            Key = 'prod'; Local = 'nornir:prod'; RemoteRepo = $nornir; Floating = 'prod'
            VersionTag = $(if ($versionSuffix) { "prod-$versionSuffix" } else { '' })
            Aliases = @('prod', 'nornir:prod')
        },
        @{
            Key = 'cupy'; Local = 'nornir:cupy'; RemoteRepo = $nornir; Floating = 'cupy'
            VersionTag = $(if ($versionSuffix) { "cupy-$versionSuffix" } else { '' })
            Aliases = @('cupy', 'nornir:cupy')
        },
        @{
            Key = 'dashboard'; Local = 'nornir-dashboard:latest'; RemoteRepo = "ghcr.io/$OwnerName/nornir-dashboard"; Floating = 'latest'
            VersionTag = $versionSuffix
            Aliases = @('dashboard', 'nornir-dashboard', 'nornir-dashboard:latest')
        },
        @{
            Key = 'gallery'; Local = 'nornir-annotation-gallery:latest'; RemoteRepo = "ghcr.io/$OwnerName/nornir-annotation-gallery"; Floating = 'latest'
            VersionTag = $versionSuffix
            Aliases = @('gallery', 'annotation-gallery', 'nornir-annotation-gallery', 'nornir-annotation-gallery:latest')
        },
        @{
            Key = 'sam2-trainer'; Local = 'sam2-trainer:dev'; RemoteRepo = "ghcr.io/$OwnerName/sam2-trainer"; Floating = 'dev'
            VersionTag = $(if ($versionSuffix) { "dev-$versionSuffix" } else { '' })
            Aliases = @('sam2', 'sam2-trainer', 'trainer', 'sam2-trainer:dev')
        }
    )
}

function Resolve-PullSelection {
    param(
        $Catalogue,
        [string[]]$Requested
    )
    $selected = [ordered]@{}
    foreach ($name in $Requested) {
        $token = $name.Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        $hit = $null
        foreach ($item in $Catalogue) {
            if ($item.Aliases -contains $token -or $item.Key -eq $token -or $item.Local -eq $token) {
                $hit = $item
                break
            }
        }
        if ($null -eq $hit) {
            Write-Error "Unknown image '$token'. Run .\nornir-docker\docker-pull.ps1 -List"
        }
        $selected[$hit.Key] = $hit
    }
    return $selected
}

function Get-TagState {
    param(
        [string]$RemoteRepo,
        [string]$TagName,
        [string[]]$RepoDigests,
        [bool]$LocalMissing
    )
    if ($LocalMissing) {
        return 'missing'
    }
    if ([string]::IsNullOrWhiteSpace($TagName)) {
        return 'n/a'
    }
    $remote = Get-GhcrTagDigest -Reference "${RemoteRepo}:${TagName}"
    if ($remote.Status -eq 'error') {
        return 'unknown'
    }
    if ($remote.Status -eq 'absent') {
        return 'dirty'
    }
    if (Test-RemoteDigestMatchesLocal -RemoteRepo $RemoteRepo -RepoDigests $RepoDigests -Remote $remote) {
        return 'clean'
    }
    return 'dirty'
}

function Get-ImagePullPlan {
    param(
        $Item,
        [bool]$Selected
    )
    $repoDigests = Get-LocalRepoDigests -LocalTag $Item.Local
    $localMissing = $null -eq $repoDigests
    if ($localMissing) {
        $repoDigests = @()
    }
    $plan = [ordered]@{
        Key = $Item.Key
        Local = $Item.Local
        RemoteRepo = $Item.RemoteRepo
        Floating = $Item.Floating
        VersionTag = $Item.VersionTag
        Selected = $Selected
        FloatingState = Get-TagState -RemoteRepo $Item.RemoteRepo -TagName $Item.Floating -RepoDigests $repoDigests -LocalMissing $localMissing
        VersionState = Get-TagState -RemoteRepo $Item.RemoteRepo -TagName $Item.VersionTag -RepoDigests $repoDigests -LocalMissing $localMissing
        PullFloating = $false
        PullVersion = $false
        Action = 'skip (not selected)'
    }
    if (-not $Selected) {
        return $plan
    }
    $plan.PullFloating = $Force -or ($plan.FloatingState -ne 'clean')
    $plan.PullVersion = $AlsoVersioned -and -not [string]::IsNullOrWhiteSpace($Item.VersionTag) -and ($Force -or ($plan.VersionState -ne 'clean'))
    if ($plan.PullFloating -and $plan.PullVersion) {
        $plan.Action = 'pull'
    }
    elseif ($plan.PullVersion -and -not $plan.PullFloating) {
        $plan.Action = "pull :$($Item.VersionTag) only"
    }
    elseif ($plan.PullFloating -and $AlsoVersioned) {
        $plan.Action = "pull :$($Item.Floating) only"
    }
    elseif ($plan.PullFloating) {
        $plan.Action = 'pull'
    }
    else {
        $plan.Action = 'skip (unchanged)'
    }
    return $plan
}

$catalogue = Get-PullCatalogue -OwnerName $Owner -Version $ver
$requested = @()
if ($Images) { $requested += $Images }
if ($Tags) { $requested += $Tags }
$requested = @($requested | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$explicit = $requested.Count -gt 0

$selected = [ordered]@{}
if ($explicit) {
    $selected = Resolve-PullSelection -Catalogue $catalogue -Requested $requested
}
else {
    foreach ($item in $catalogue) {
        if ($item.Key -in @('prod', 'cupy')) {
            $selected[$item.Key] = $item
        }
    }
}
if ($IncludeDashboard) {
    foreach ($item in $catalogue) {
        if ($item.Key -eq 'dashboard') {
            $selected[$item.Key] = $item
        }
    }
}

$shown = if ($List -and -not $explicit) { $catalogue } else { @($selected.Values) }
$plans = @()
foreach ($item in $shown) {
    $plans += Get-ImagePullPlan -Item $item -Selected:($selected.Contains($item.Key))
}

if ($List) {
    Write-Host ("{0,-36} {1,-10} {2,-28} {3}" -f 'Local', 'Floating', 'Versioned', 'Action')
    foreach ($plan in $plans) {
        $versionLabel = if ([string]::IsNullOrWhiteSpace($plan.VersionTag)) {
            $plan.VersionState
        }
        else {
            "$($plan.VersionState) :$($plan.VersionTag)"
        }
        Write-Host ("{0,-36} {1,-10} {2,-28} {3}" -f $plan.Local, $plan.FloatingState, $versionLabel, $plan.Action)
    }
    Write-Host ''
    Write-Host 'clean = GHCR tag digest is already on this local image. dirty = tag missing or different. missing = not pulled locally. unknown = registry check failed (a pull will be attempted).'
    Write-Host 'Default pull (no -Images or -Tags): prod, cupy. -IncludeDashboard adds nornir-dashboard:latest only.'
    Write-Host 'Pass -Images for dev, dev-cursor-base, cursor-worker, gallery, or sam2-trainer.'
    Write-Host 'Not listed: eclipse-mosquitto:2 (public), and VikingLegacy images (segmentation-server, grpc-annotation-service, section-correction-service, identity-standalone, identity-webapi, identity-all-services).'
    return
}

$pulled = 0
$skipped = 0
foreach ($plan in $plans) {
    if (-not $plan.Selected) {
        continue
    }
    $floatingRef = "$($plan.RemoteRepo):$($plan.Floating)"
    $versionRef = "$($plan.RemoteRepo):$($plan.VersionTag)"
    Write-Host "=== $($plan.Local) ==="
    if (-not $plan.PullFloating -and -not $plan.PullVersion) {
        Write-Host "  Unchanged. Skipping $floatingRef"
        $skipped++
        Write-Host ''
        continue
    }

    $floatingOk = $true
    if ($plan.PullFloating) {
        $floatingOk = Invoke-NornirDockerCli -DockerCliArgs @('pull', $floatingRef)
        if ($floatingOk) {
            $pulled++
        }
    }
    else {
        Write-Host "  Unchanged. Skipping $floatingRef"
    }
    if (-not $floatingOk) {
        Write-Host ''
        continue
    }

    $retagFrom = $null
    if ($plan.PullVersion) {
        if (Invoke-NornirDockerCli -DockerCliArgs @('pull', $versionRef)) {
            $pulled++
            if ($PreferVersioned) {
                $retagFrom = $versionRef
            }
        }
        elseif ($PreferVersioned -and $plan.PullFloating) {
            $retagFrom = $floatingRef
        }
    }
    if ($plan.PullFloating -and -not $PreferVersioned) {
        $retagFrom = $floatingRef
    }
    if ($retagFrom) {
        [void](Invoke-NornirDockerCli -DockerCliArgs @('tag', $retagFrom, $plan.Local))
    }
    Write-Host ''
}

Write-Host "Done. Pulled $pulled tag(s), skipped $skipped image(s). ghcr.io/$Owner."
Write-Host '  Confirm: docker image ls nornir'
Write-Host "  Inspect: docker buildx imagetools inspect ghcr.io/$Owner/nornir:cupy"
