<#
.SYNOPSIS
  Tag and push Nornir, dashboard, gallery, and SAM2 trainer images to GHCR.

.DESCRIPTION
  Pushes every catalogue image that exists locally and whose GHCR tag does not
  already point at that image. A tag is unchanged when the local image's
  RepoDigests contain the digest returned by `docker buildx imagetools inspect`
  for that remote tag. Unchanged tags are skipped. A missing local image is
  skipped with a warning when you push the default set, and is an error when
  you named that image.

  Requires docker login to ghcr.io first (PAT with write:packages).

  Catalogue (short name accepted by -Images):
    dev, dev-cursor-base, cursor-worker, prod, cupy
    dashboard, gallery, sam2-trainer

  Not in this catalogue: eclipse-mosquitto:2 (public), and VikingLegacy images
  (segmentation-server, grpc-annotation-service, section-correction-service,
  identity-standalone, identity-webapi, identity-all-services, identity-devtest,
  certbot renewers). Publish those from VikingLegacy.

.PARAMETER Owner
  GHCR namespace. Default: jamesra (or $env:NORNIR_GHCR_OWNER).

.PARAMETER Images
  Catalogue names or local tags to push. Default: the whole catalogue.
  Examples: cupy, nornir:dev, dashboard, gallery, sam2-trainer.

.PARAMETER Tags
  Same as -Images. Kept so existing ` -Tags prod,cupy ` commands still select
  only those images.

.PARAMETER IncludeDashboard
  With -Images or -Tags, also include dashboard, gallery, and sam2-trainer.
  With no image list, those three are already in the default set.

.PARAMETER List
  Print each catalogue image as clean, dirty, missing, or unknown. Do not tag
  or push.

.PARAMETER Help
  Show this help and exit. `-?` does the same.

.PARAMETER Force
  Push selected images even when the remote digest already matches.

.PARAMETER DryRun
  Print docker tag/push commands without running them. Still skips unchanged
  images unless -Force.

.PARAMETER MaxAgeHours
  Warn (do not fail) if a local image that will be pushed was created more than
  this many hours ago. Default: 24. Set to 0 to disable.

.EXAMPLE
  .\nornir-docker\docker-push.ps1 -Help

.EXAMPLE
  .\nornir-docker\docker-push.ps1 -List

.EXAMPLE
  .\nornir-docker\docker-push.ps1 -Images cupy,gallery
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
    [double]$MaxAgeHours = 24
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help -Name $PSCommandPath -Full
    return
}

$DockerDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DockerDir
$versionPath = Join-Path $RepoRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) {
    Write-Error "Missing VERSION at $versionPath"
}
$ver = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($ver)) {
    Write-Error 'VERSION file is empty'
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
    if (-not $DryRun) {
        & docker @DockerCliArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "docker failed: $($DockerCliArgs -join ' ')"
        }
    }
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

function Get-PushCatalogue {
    param(
        [Parameter(Mandatory)][string]$OwnerName,
        [Parameter(Mandatory)][string]$Version
    )
    $nornir = "ghcr.io/$OwnerName/nornir"
    return @(
        @{
            Key = 'dev'; Local = 'nornir:dev'; RemoteRepo = $nornir; Floating = 'dev'; VersionTag = "dev-$Version"
            Aliases = @('dev', 'nornir:dev')
            Rebuild = 'docker-build.ps1 -Images dev'
        },
        @{
            Key = 'dev-cursor-base'; Local = 'nornir:dev-cursor-base'; RemoteRepo = $nornir; Floating = 'dev-cursor-base'; VersionTag = "dev-cursor-base-$Version"
            Aliases = @('dev-cursor-base', 'nornir:dev-cursor-base')
            Rebuild = 'docker-build.ps1 -Images dev-cursor-base'
        },
        @{
            Key = 'cursor-worker'; Local = 'nornir:cursor-worker'; RemoteRepo = $nornir; Floating = 'cursor-worker'; VersionTag = "cursor-worker-$Version"
            Aliases = @('cursor-worker', 'nornir:cursor-worker')
            Rebuild = 'docker-build.ps1 -Images cursor-worker'
        },
        @{
            Key = 'prod'; Local = 'nornir:prod'; RemoteRepo = $nornir; Floating = 'prod'; VersionTag = "prod-$Version"
            Aliases = @('prod', 'nornir:prod')
            Rebuild = 'docker-build.ps1 -Images prod'
        },
        @{
            Key = 'cupy'; Local = 'nornir:cupy'; RemoteRepo = $nornir; Floating = 'cupy'; VersionTag = "cupy-$Version"
            Aliases = @('cupy', 'nornir:cupy')
            Rebuild = 'docker-build.ps1 -Images cupy'
        },
        @{
            Key = 'dashboard'; Local = 'nornir-dashboard:latest'; RemoteRepo = "ghcr.io/$OwnerName/nornir-dashboard"; Floating = 'latest'; VersionTag = $Version
            Aliases = @('dashboard', 'nornir-dashboard', 'nornir-dashboard:latest')
            Rebuild = 'nornir-docker/start-dashboard.ps1 -Rebuild'
        },
        @{
            Key = 'gallery'; Local = 'nornir-annotation-gallery:latest'; RemoteRepo = "ghcr.io/$OwnerName/nornir-annotation-gallery"; Floating = 'latest'; VersionTag = $Version
            Aliases = @('gallery', 'annotation-gallery', 'nornir-annotation-gallery', 'nornir-annotation-gallery:latest')
            Rebuild = 'Sam2SegmentationTrainer: docker compose -f docker/compose.cursor-dev.yaml build annotation-gallery'
        },
        @{
            Key = 'sam2-trainer'; Local = 'sam2-trainer:dev'; RemoteRepo = "ghcr.io/$OwnerName/sam2-trainer"; Floating = 'dev'; VersionTag = "dev-$Version"
            Aliases = @('sam2', 'sam2-trainer', 'trainer', 'sam2-trainer:dev')
            Rebuild = 'D:\Docker\Builds\sam2-trainer\build.ps1'
        }
    )
}

function Resolve-PushSelection {
    param(
        $Catalogue,
        [string[]]$Requested,
        [switch]$AddCompanions
    )
    if (-not $Requested -or $Requested.Count -eq 0) {
        return $Catalogue
    }
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
            Write-Error "Unknown image '$token'. Run .\nornir-docker\docker-push.ps1 -List"
        }
        $selected[$hit.Key] = $hit
    }
    if ($AddCompanions) {
        foreach ($item in $Catalogue) {
            if ($item.Key -in @('dashboard', 'gallery', 'sam2-trainer')) {
                $selected[$item.Key] = $item
            }
        }
    }
    return @($selected.Values)
}

function Get-ImagePushPlan {
    param($Item)
    $plan = [ordered]@{
        Key = $Item.Key
        Local = $Item.Local
        RemoteRepo = $Item.RemoteRepo
        Floating = $Item.Floating
        VersionTag = $Item.VersionTag
        Rebuild = $Item.Rebuild
        LocalId = ''
        Created = ''
        Revision = ''
        Built = ''
        FloatingState = 'unknown'
        VersionState = 'unknown'
        PushFloating = $false
        PushVersion = $false
        Action = 'skip'
    }
    $repoDigests = Get-LocalRepoDigests -LocalTag $Item.Local
    if ($null -eq $repoDigests) {
        $plan.FloatingState = 'missing'
        $plan.VersionState = 'missing'
        $plan.Action = 'skip (not built)'
        return $plan
    }

    $id = (& docker image inspect $Item.Local --format '{{.Id}}').Trim()
    $plan.LocalId = $id
    $plan.Created = (& docker image inspect $Item.Local --format '{{.Created}}').Trim()
    # JSON labels: embedded double quotes in a --format template are stripped by PowerShell native-arg passing.
    $labelsJson = [string](& docker image inspect $Item.Local --format '{{json .Config.Labels}}')
    $getLabel = { param($n) if ($labelsJson -match ('"' + [regex]::Escape($n) + '":"([^"]*)"')) { $Matches[1] } else { '' } }
    $plan.Revision = & $getLabel 'org.opencontainers.image.revision'
    $plan.Built = & $getLabel 'org.opencontainers.image.created'

    $floatingRef = "$($Item.RemoteRepo):$($Item.Floating)"
    $versionRef = "$($Item.RemoteRepo):$($Item.VersionTag)"
    $floatingRemote = Get-GhcrTagDigest -Reference $floatingRef
    $versionRemote = Get-GhcrTagDigest -Reference $versionRef

    $plan.FloatingState = $floatingRemote.Status
    $plan.VersionState = $versionRemote.Status
    if ($floatingRemote.Status -eq 'error') {
        $plan.FloatingState = 'unknown'
    }
    if ($versionRemote.Status -eq 'error') {
        $plan.VersionState = 'unknown'
    }
    if ($floatingRemote.Status -eq 'absent') {
        $plan.FloatingState = 'dirty'
    }
    if ($versionRemote.Status -eq 'absent') {
        $plan.VersionState = 'dirty'
    }
    if ((Test-RemoteDigestMatchesLocal -RemoteRepo $Item.RemoteRepo -RepoDigests $repoDigests -Remote $floatingRemote)) {
        $plan.FloatingState = 'clean'
    }
    elseif ($floatingRemote.Status -eq 'ok') {
        $plan.FloatingState = 'dirty'
    }
    if ((Test-RemoteDigestMatchesLocal -RemoteRepo $Item.RemoteRepo -RepoDigests $repoDigests -Remote $versionRemote)) {
        $plan.VersionState = 'clean'
    }
    elseif ($versionRemote.Status -eq 'ok') {
        $plan.VersionState = 'dirty'
    }

    $plan.PushFloating = $Force -or ($plan.FloatingState -ne 'clean')
    $plan.PushVersion = $Force -or ($plan.VersionState -ne 'clean')
    if ($plan.PushFloating -and $plan.PushVersion) {
        $plan.Action = 'push'
    }
    elseif ($plan.PushFloating) {
        $plan.Action = "push :$($Item.Floating) only"
    }
    elseif ($plan.PushVersion) {
        $plan.Action = "push :$($Item.VersionTag) only"
    }
    else {
        $plan.Action = 'skip (unchanged)'
    }
    return $plan
}

function Write-ImageAgeWarning {
    param(
        $Plan,
        [double]$MaxAgeHours
    )
    if ($MaxAgeHours -le 0 -or [string]::IsNullOrWhiteSpace($Plan.Created)) {
        return
    }
    try {
        $createdDt = [datetime]::Parse($Plan.Created, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $ageHours = ([datetime]::UtcNow - $createdDt.ToUniversalTime()).TotalHours
        if ($ageHours -gt $MaxAgeHours) {
            Write-Warning ("    Image is {0:N1} hours old (MaxAgeHours={1}). Rebuild with {2}" -f $ageHours, $MaxAgeHours, $Plan.Rebuild)
        }
    }
    catch {
        Write-Warning "    Could not parse Created timestamp for age check"
    }
}

$catalogue = Get-PushCatalogue -OwnerName $Owner -Version $ver
$requested = @()
if ($Images) { $requested += $Images }
if ($Tags) { $requested += $Tags }
$explicit = @($requested | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
$selection = Resolve-PushSelection -Catalogue $catalogue -Requested $requested -AddCompanions:($IncludeDashboard -and $explicit)

$plans = @()
foreach ($item in $selection) {
    $plans += Get-ImagePushPlan -Item $item
}

if ($List) {
    Write-Host ("{0,-36} {1,-10} {2,-28} {3}" -f 'Local', 'Floating', 'Versioned', 'Action')
    foreach ($plan in $plans) {
        $versionLabel = "$($plan.VersionState) :$($plan.VersionTag)"
        Write-Host ("{0,-36} {1,-10} {2,-28} {3}" -f $plan.Local, $plan.FloatingState, $versionLabel, $plan.Action)
    }
    Write-Host ''
    Write-Host 'clean = GHCR tag digest is already on this local image. dirty = tag missing or different. missing = not built locally. unknown = registry check failed (a push will be attempted).'
    Write-Host 'Not listed: eclipse-mosquitto:2 (public), and VikingLegacy images (segmentation-server, grpc-annotation-service, section-correction-service, identity-standalone, identity-webapi, identity-all-services).'
    return
}

$pushed = 0
$skipped = 0
foreach ($plan in $plans) {
    Write-Host "=== $($plan.Local) ==="
    if ($plan.FloatingState -eq 'missing') {
        $message = "Local image not found: $($plan.Local) (build it first: $($plan.Rebuild))"
        if ($explicit) {
            Write-Error $message
        }
        Write-Warning $message
        $skipped++
        Write-Host ''
        continue
    }
    if (-not $plan.PushFloating -and -not $plan.PushVersion) {
        Write-Host "  Unchanged. Skipping $($plan.RemoteRepo):$($plan.Floating) and :$($plan.VersionTag)"
        $skipped++
        Write-Host ''
        continue
    }
    Write-Host "  Id:      $($plan.LocalId)"
    Write-Host "  Created: $($plan.Created)"
    Write-Host "  Labels:  revision=$($plan.Revision) created=$($plan.Built)"
    Write-ImageAgeWarning -Plan $plan -MaxAgeHours $MaxAgeHours
    if ($plan.PushFloating) {
        $remote = "$($plan.RemoteRepo):$($plan.Floating)"
        Invoke-NornirDockerCli -DockerCliArgs @('tag', $plan.Local, $remote)
        Invoke-NornirDockerCli -DockerCliArgs @('push', $remote)
        $pushed++
    }
    else {
        Write-Host "  Unchanged. Skipping $($plan.RemoteRepo):$($plan.Floating)"
    }
    if ($plan.PushVersion) {
        $remote = "$($plan.RemoteRepo):$($plan.VersionTag)"
        Invoke-NornirDockerCli -DockerCliArgs @('tag', $plan.Local, $remote)
        Invoke-NornirDockerCli -DockerCliArgs @('push', $remote)
        $pushed++
    }
    else {
        Write-Host "  Unchanged. Skipping $($plan.RemoteRepo):$($plan.VersionTag)"
    }
    Write-Host ''
}

Write-Host "Done. Pushed $pushed tag(s), skipped $skipped image(s). ghcr.io/$Owner VERSION=$ver."
if ($pushed -gt 0) {
    Write-Host "On the appliance, confirm a NEW digest:"
    Write-Host "  docker pull ghcr.io/$Owner/nornir:cupy"
    Write-Host "  docker buildx imagetools inspect ghcr.io/$Owner/nornir:cupy"
}
