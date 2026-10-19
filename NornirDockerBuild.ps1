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
    # Read labels as JSON: embedded double quotes in a --format template are stripped by PowerShell's
    # native-argument passing ("function org not defined").
    # Regex over the raw JSON (not ConvertFrom-Json) so the ISO created date stays a string.
    $labelsJson = [string](& docker image inspect $Tag --format '{{json .Config.Labels}}')
    $getLabel = { param($n) if ($labelsJson -match ('"' + [regex]::Escape($n) + '":"([^"]*)"')) { $Matches[1] } else { '' } }
    $rev = & $getLabel 'org.opencontainers.image.revision'
    $built = & $getLabel 'org.opencontainers.image.created'
    $verLabel = & $getLabel 'org.opencontainers.image.version'
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

# ---------------------------------------------------------------------------
# Skip-unchanged support: .docker-build-state.json (invocation directory)
# Records, per image tag, the source HEADs (+ dirty hash), Dockerfile/COPY'd file hashes and build-arg hash
# the image was last built from. An image is rebuilt only when one of those changes or the tag's image ID
# no longer matches the recorded one. Compose files are hashed and reported but never trigger a build.
# ---------------------------------------------------------------------------

$Script:NornirBuildStateFileName = '.docker-build-state.json'
# Build-args that change on every run and must not feed the fingerprint.
$Script:NornirVolatileBuildArgKeys = [string[]]@('BUILD_DATE', 'SOURCE_REVISION')

function Get-NornirStringHash {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-NornirFileSha {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NornirImageIdOrEmpty {
    param([Parameter(Mandatory)][string]$Tag)
    $id = & docker image inspect $Tag --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$id)) { return '' }
    return ([string]$id).Trim()
}

function ConvertTo-NornirHashtable {
    <# Recursively turn ConvertFrom-Json output into hashtables (works on Windows PowerShell 5.1 and 7). #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-NornirHashtable $p.Value }
        return $h
    }
    return $InputObject
}

function Get-NornirSourceState {
    <#
    .SYNOPSIS
      "<HEAD>|<dirty hash>" for a COPY'd source directory. Dirty hash is empty for a clean tree, otherwise a
      SHA-256 of `git diff HEAD` plus the contents of untracked, non-ignored files.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelPath
    )
    $dir = Join-Path $RepoRoot $RelPath
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return 'missing' }

    # A submodule is its own repository; a plain folder is tracked by the umbrella repository.
    $top = & git -C $dir rev-parse --show-toplevel 2>$null
    $ownRepo = $false
    if ($LASTEXITCODE -eq 0 -and $top) {
        $a = [System.IO.Path]::GetFullPath([string]$top).TrimEnd('\', '/')
        $b = [System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
        $ownRepo = ($a -ieq $b)
    }
    if ($ownRepo) {
        $repo = $dir
        $spec = @()
    }
    else {
        $repo = $RepoRoot
        $spec = @('--', $RelPath)
    }
    $head = (& git -C $repo rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $head) { $head = 'nohead' }
    $head = ([string]$head).Trim()

    $status = @(& git -C $repo status --porcelain @spec 2>$null)
    if ($status.Count -eq 0) { return "$head|" }

    $diff = (@(& git -C $repo -c core.quotepath=false diff HEAD @spec 2>$null) -join "`n")
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append($diff)
    $untracked = @(& git -C $repo -c core.quotepath=false ls-files -o --exclude-standard @spec 2>$null | Sort-Object)
    foreach ($rel in $untracked) {
        [void]$sb.Append("`nU $rel " + (Get-NornirFileSha (Join-Path $repo $rel)))
    }
    return "$head|" + (Get-NornirStringHash $sb.ToString())
}

function Get-NornirComposeFilesForTag {
    param([Parameter(Mandatory)][string]$Tag)
    switch ($Tag) {
        { $_ -in 'nornir:dev', 'nornir:dev-cursor-base' } { return @('nornir-docker/compose.cursor-dev.yaml') }
        'nornir:cursor-worker' { return @('nornir-docker/compose.cursor-worker.yaml') }
        { $_ -in 'nornir:prod', 'nornir:cupy' } { return @('nornir-docker/compose.yaml') }
        default { return @() }
    }
}

function Get-NornirBuildFingerprint {
    <#
    .SYNOPSIS
      Everything that determines the content of an image build, as nested hashtables of strings.
    .DESCRIPTION
      Sources and files are discovered from the Dockerfile's COPY lines, so a new COPY widens the inputs
      automatically. BuildArgs are the merged build-args minus BUILD_DATE / SOURCE_REVISION.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Dockerfile,
        [Parameter(Mandatory)][string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string]$BaseImage = ''
    )
    $fp = @{
        sources      = @{}
        files        = @{}
        composeFiles = @{}
        buildArgs    = ''
        base         = ''
    }
    $fp.files[$Dockerfile] = Get-NornirFileSha (Join-Path $RepoRoot $Dockerfile)
    $fp.files['.dockerignore'] = Get-NornirFileSha (Join-Path $RepoRoot '.dockerignore')

    $dfPath = Join-Path $RepoRoot $Dockerfile
    if (Test-Path -LiteralPath $dfPath) {
        foreach ($line in (Get-Content -LiteralPath $dfPath)) {
            if ($line -notmatch '^\s*COPY\s+(.+)$') { continue }
            $tokens = @(($Matches[1] -split '\s+') | Where-Object { $_ })
            if ($tokens | Where-Object { $_ -like '--from*' }) { continue }
            $tokens = @($tokens | Where-Object { $_ -notlike '--*' })
            if ($tokens.Count -lt 2) { continue }
            foreach ($src in $tokens[0..($tokens.Count - 2)]) {
                $rel = ($src -replace '^\./', '').TrimEnd('/', '\')
                if ($rel -eq '.' -or [string]::IsNullOrEmpty($rel)) { continue }
                $full = Join-Path $RepoRoot $rel
                if (Test-Path -LiteralPath $full -PathType Container) {
                    $fp.sources[$rel] = Get-NornirSourceState -RepoRoot $RepoRoot -RelPath $rel
                }
                else {
                    $fp.files[$rel] = Get-NornirFileSha $full
                }
            }
        }
    }

    foreach ($c in (Get-NornirComposeFilesForTag -Tag $Tag)) {
        $fp.composeFiles[$c] = Get-NornirFileSha (Join-Path $RepoRoot $c)
    }

    $argLines = foreach ($k in ($BuildArgs.Keys | Sort-Object)) {
        if ($Script:NornirVolatileBuildArgKeys -contains $k) { continue }
        "$k=$($BuildArgs[$k])"
    }
    $fp.buildArgs = Get-NornirStringHash ($argLines -join "`n")

    if (-not [string]::IsNullOrWhiteSpace($BaseImage)) {
        $baseId = Get-NornirImageIdOrEmpty -Tag $BaseImage
        $fp.base = if ($baseId) { "$BaseImage=$baseId" } else { "$BaseImage=missing" }
    }
    return $fp
}

function Get-NornirBuildStatePath {
    param([Parameter(Mandatory)][string]$BuildEnvRoot)
    return Join-Path $BuildEnvRoot $Script:NornirBuildStateFileName
}

function Read-NornirBuildState {
    param([Parameter(Mandatory)][string]$BuildEnvRoot)
    $path = Get-NornirBuildStatePath -BuildEnvRoot $BuildEnvRoot
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $state = ConvertTo-NornirHashtable (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        if ($state -is [hashtable]) { return $state }
    }
    catch {
        Write-Warning "Ignoring unreadable $path ($($_.Exception.Message)); all selected images will be built."
    }
    return @{}
}

function Write-NornirBuildState {
    param(
        [Parameter(Mandatory)][string]$BuildEnvRoot,
        [Parameter(Mandatory)][hashtable]$State
    )
    $path = Get-NornirBuildStatePath -BuildEnvRoot $BuildEnvRoot
    $tmp = "$path.tmp"
    ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Compare-NornirFingerprintMap {
    param([string]$Section, $Current, $Recorded)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Recorded) { $Recorded = @{} }
    foreach ($k in $Current.Keys) {
        if (-not $Recorded.ContainsKey($k)) { $reasons.Add("$Section '$k' is new") }
        elseif ([string]$Recorded[$k] -ne [string]$Current[$k]) { $reasons.Add("$Section '$k' changed") }
    }
    foreach ($k in $Recorded.Keys) {
        if (-not $Current.ContainsKey($k)) { $reasons.Add("$Section '$k' removed") }
    }
    return , $reasons.ToArray()
}

function Test-NornirBuildNeeded {
    <#
    .SYNOPSIS
      Decide whether an image must be built. Returns Needed, Reasons, Fingerprint and ComposeChanged.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BuildEnvRoot,
        [Parameter(Mandatory)][string]$Dockerfile,
        [Parameter(Mandatory)][string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string]$BaseImage = '',
        [switch]$Force
    )
    $fp = Get-NornirBuildFingerprint -RepoRoot $RepoRoot -Dockerfile $Dockerfile -Tag $Tag -BuildArgs $BuildArgs -BaseImage $BaseImage
    $reasons = [System.Collections.Generic.List[string]]::new()
    $composeChanged = @()

    $entry = (Read-NornirBuildState -BuildEnvRoot $BuildEnvRoot)[$Tag]
    $currentId = Get-NornirImageIdOrEmpty -Tag $Tag

    if ($Force) { $reasons.Add('forced (-Force / -NoCache)') }
    if (-not $currentId) { $reasons.Add('image not present locally') }
    if ($null -eq $entry) { $reasons.Add('no recorded build') }
    else {
        if ($currentId -and $entry['imageId'] -ne $currentId) { $reasons.Add('image ID differs from the recorded build') }
        foreach ($sec in 'sources', 'files') {
            $reasons.AddRange([string[]](Compare-NornirFingerprintMap -Section $sec.TrimEnd('s') -Current $fp[$sec] -Recorded $entry[$sec]))
        }
        if ([string]$entry['buildArgs'] -ne $fp.buildArgs) { $reasons.Add('build-args changed') }
        if ([string]$entry['base'] -ne $fp.base) { $reasons.Add('base image changed') }
        $composeChanged = [string[]](Compare-NornirFingerprintMap -Section 'compose' -Current $fp.composeFiles -Recorded $entry['composeFiles'])
    }
    return [pscustomobject]@{
        Needed         = ($reasons.Count -gt 0)
        Reasons        = $reasons.ToArray()
        Fingerprint    = $fp
        ComposeChanged = $composeChanged
    }
}

function Save-NornirBuildState {
    <# Record a successful build (call only after the image built and verified). #>
    param(
        [Parameter(Mandatory)][string]$BuildEnvRoot,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)]$Fingerprint
    )
    $state = Read-NornirBuildState -BuildEnvRoot $BuildEnvRoot
    $entry = @{} + $Fingerprint
    $entry['imageId'] = Get-NornirImageIdOrEmpty -Tag $Tag
    $entry['builtAt'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $state[$Tag] = $entry
    Write-NornirBuildState -BuildEnvRoot $BuildEnvRoot -State $state
}

function Resolve-NornirBuildDecision {
    <#
    .SYNOPSIS
      Test-NornirBuildNeeded plus console reporting. When skipping, compose-file hash changes are reported once
      and recorded so they do not repeat.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BuildEnvRoot,
        [Parameter(Mandatory)][string]$Dockerfile,
        [Parameter(Mandatory)][string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string]$BaseImage = '',
        [switch]$Force
    )
    $check = Test-NornirBuildNeeded -RepoRoot $RepoRoot -BuildEnvRoot $BuildEnvRoot -Dockerfile $Dockerfile -Tag $Tag `
        -BuildArgs $BuildArgs -BaseImage $BaseImage -Force:$Force
    if ($check.Needed) {
        Write-Host "[$Tag] build needed: $($check.Reasons -join '; ')"
    }
    else {
        Write-Host "[$Tag] up to date (sources, Dockerfile and build-args unchanged); skipping build."
    }
    if ($check.ComposeChanged.Count -gt 0) {
        Write-Host "[$Tag] compose file changed (no rebuild needed): $($check.ComposeChanged -join '; ')"
        if (-not $check.Needed) {
            $state = Read-NornirBuildState -BuildEnvRoot $BuildEnvRoot
            $state[$Tag]['composeFiles'] = $check.Fingerprint.composeFiles
            Write-NornirBuildState -BuildEnvRoot $BuildEnvRoot -State $state
        }
    }
    return $check
}

function Set-NornirVersionTag {
    param([Parameter(Mandatory)][string]$Tag, [string]$Version = '')
    if ([string]::IsNullOrWhiteSpace($Version)) { return }
    $versionTag = "nornir:$($Tag.Split(':')[-1])-$Version"
    $null = Invoke-NornirDockerCli -ArgumentList @('tag', $Tag, $versionTag)
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
        [switch]$DryRun,
        [switch]$Force,
        [string]$VersionTag = ''
    )
    $merged = Get-NornirMergedBuildArgs -BuildEnvRoot $BuildEnvRoot -Tag $Tag -ExtraArgs $ExtraArgs
    $decision = Resolve-NornirBuildDecision -RepoRoot $RepoRoot -BuildEnvRoot $BuildEnvRoot -Dockerfile $Dockerfile -Tag $Tag `
        -BuildArgs ($merged + $OciArgs) -Force:($Force -or $NoCache)
    if (-not $decision.Needed) {
        if (-not $DryRun) { Set-NornirVersionTag -Tag $Tag -Version $VersionTag }
        return 0
    }
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
    if ($DryRun) {
        if (-not [string]::IsNullOrWhiteSpace($VersionTag)) {
            $suffix = $Tag.Split(':')[-1]
            Write-Host "docker tag $Tag nornir:${suffix}-$VersionTag"
        }
        return 0
    }
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
    Save-NornirBuildState -BuildEnvRoot $BuildEnvRoot -Tag $Tag -Fingerprint $decision.Fingerprint
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
        $cwDecision = Resolve-NornirBuildDecision -RepoRoot $RepoRoot -BuildEnvRoot $BuildEnvRoot -Dockerfile 'nornir-docker/Dockerfile.cursor-worker' `
            -Tag 'nornir:cursor-worker' -BuildArgs $cursorMerged -BaseImage 'nornir:dev-cursor-base' -Force:$NoCache
        if (-not $cwDecision.Needed) { return 0 }
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
        $cwExit = Invoke-NornirDockerCli -ArgumentList $cursorWorkerArgs
        if ($cwExit -eq 0) {
            Save-NornirBuildState -BuildEnvRoot $BuildEnvRoot -Tag 'nornir:cursor-worker' -Fingerprint $cwDecision.Fingerprint
        }
        return $cwExit
    }
    finally {
        Pop-Location
    }
}
