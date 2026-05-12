<#
.SYNOPSIS
  Build (optional) and run the Nornir Cursor self-hosted cloud agent worker image.

.DESCRIPTION
  By default, creates a unique folder under D:\Docker\mounted-configs\nornir-cursor-worker (see -AgentCloneParent), runs a host-side git clone
  into it (same pattern as topography/docker/start-cursor-worker.ps1), and bind-mounts that directory at /workspace.
  The container entrypoint then pull/submodule/pip as usual.
  Use -LiveMount to bind-mount a host path at /workspace (RepoRoot if -WorkspaceMountPath omitted).
  Use -LiveMount -UseUniqueWorkspaceFolder to create an empty unique folder per run under -WorkspaceRunParent
  (default D:\Docker\mounted-configs\nornir-cursor-worker); the container uses clone strategy and clones into /workspace (same isolation idea as D:\agents host-clone mode).
  Use -UseNamedDockerVolume for a Docker named volume at /workspace (compose-style persistence).

  Loads nornir-docker/.env.cursor-worker (or optional override under $NORNIR_DOCKER_USER_ROOT) into the host process for keys like CURSOR_API_KEY when not already set.
  GITHUB_TOKEN and GH_TOKEN are never loaded into the host process: they stay in .env.cursor-worker and are passed
  only into the container via --env-file (avoids Git Credential Manager / leaked PAT on Windows).
  Passes --env-file into the container so every variable in the file is available inside the worker.

.PARAMETER Image
  Image tag. Default: nornir:cursor-worker

.PARAMETER RepoRoot
  Monorepo root for docker build context. Default: parent of nornir-docker.

.PARAMETER Rebuild
  Rebuild nornir:dev-cursor-base and nornir:cursor-worker before run.

.PARAMETER Detach
  docker run -d instead of -it.

.PARAMETER KeepContainer
  Do not pass --rm to docker run, leaving the container on disk after it exits so it can be restarted (docker start).

.PARAMETER ContainerName
  Container name when -KeepContainer is set. Default: nornir-cursor-worker

.PARAMETER ReplaceExistingContainer
  If a container with -ContainerName already exists, remove it before starting a new one.

.PARAMETER SmokeTest
  Short-lived container: agent --version then sleep (no CURSOR_API_KEY required). Mounts WorkspaceMountPath or RepoRoot at /workspace.

.PARAMETER EnvFilePath
  Full path to the worker env file. If omitted: NORNIR_CURSOR_WORKER_ENV_FILE if set; else nornir-docker/.env.cursor-worker if present; else $NORNIR_DOCKER_USER_ROOT/nornir-cursor-worker.run.env; default path for messages is nornir-docker/.env.cursor-worker. Committed template: example.nornir-cursor-worker.run.env.

.PARAMETER WorkspaceMountPath
  Host directory bind-mounted at /workspace when -LiveMount or -SmokeTest is used. If omitted, uses RepoRoot (monorepo root). Ignored when -UseUniqueWorkspaceFolder is set.

.PARAMETER UseUniqueWorkspaceFolder
  With -LiveMount only: create a new empty directory under -WorkspaceRunParent (timestamp + short guid) and mount it at /workspace. The container uses NORNIR_WORKSPACE_STRATEGY=clone (default) and clones into /workspace. Use -RemoveCloneAfter to delete the folder after exit.

.PARAMETER WorkspaceRunParent
  Parent directory for -UseUniqueWorkspaceFolder. Default: D:\Docker\mounted-configs\nornir-cursor-worker

.PARAMETER LiveMount
  Bind-mount WorkspaceMountPath (or RepoRoot if unset), or a unique folder when -UseUniqueWorkspaceFolder, at /workspace (no host isolated clone). Takes precedence over -UseNamedDockerVolume.

.PARAMETER UseNamedDockerVolume
  Mount the Docker named volume (-WorkspaceVolume) at /workspace instead of a unique folder under -AgentCloneParent.

.PARAMETER AgentCloneParent
  Host directory for isolated clones when neither -LiveMount nor -UseNamedDockerVolume. Default: D:\Docker\mounted-configs\nornir-cursor-worker

.PARAMETER CloneUrl
  Git clone URL for isolated clone. Default: origin remote of RepoRoot.

.PARAMETER CloneBranch
  Branch for isolated clone (-b). Default: current branch of RepoRoot if not detached; else remote default.

.PARAMETER RemoveCloneAfter
  After the container exits, delete the host workspace folder when applicable: isolated host clone, or -LiveMount -UseUniqueWorkspaceFolder when this switch is set.
  If the folder is a git checkout, removal is skipped when git reports a non-empty working tree (uncommitted or untracked changes); a warning is shown instead.

.PARAMETER Gpu
  Pass --gpus all to docker run.

.PARAMETER NoGpu
  Do not pass --gpus all (override the default).

.PARAMETER WorkspaceVolume
  Named volume for /workspace when -UseNamedDockerVolume is set. Default: nornir-cursor-worker-workspace

.PARAMETER SkipEnvFile
  Do not pass --env-file (use only explicit -e / host env).

.EXAMPLE
  .\nornir-docker\start-cursor-worker.ps1 -LiveMount -UseUniqueWorkspaceFolder -WorkspaceRunParent 'D:\Docker\mounted-configs\nornir-cursor-worker' -EnvFilePath 'D:\Docker\Builds\nornir-cursor-worker\.env.cursor-worker'

.EXAMPLE
  .\nornir-docker\start-cursor-worker.ps1 -LiveMount -WorkspaceMountPath 'D:\Docker\mounted-configs\nornir-cursor-worker\fixed-src' -EnvFilePath 'D:\Docker\Builds\nornir-cursor-worker\.env.cursor-worker'

.EXAMPLE
  .\nornir-docker\start-cursor-worker.ps1

.EXAMPLE
  .\nornir-docker\start-cursor-worker.ps1 -Rebuild

.EXAMPLE
  .\nornir-docker\start-cursor-worker.ps1 -SmokeTest

.EXAMPLE
  .\nornir-docker\start-cursor-worker.ps1 -LiveMount -Gpu

.EXAMPLE
  .\nornir-docker\start-cursor-worker.ps1 -RemoveCloneAfter -CloneBranch dev
#>
param(
    [string]$Image = "nornir:cursor-worker",
    [string]$RepoRoot = "",
    [switch]$Rebuild,
    [switch]$Detach,
    [switch]$KeepContainer,
    [string]$ContainerName = "nornir-cursor-worker",
    [switch]$ReplaceExistingContainer,
    [switch]$SmokeTest,
    [switch]$LiveMount,
    [switch]$UseNamedDockerVolume,
    [string]$AgentCloneParent = "D:\Docker\mounted-configs\nornir-cursor-worker",
    [string]$CloneUrl = "",
    [string]$CloneBranch = "",
    [switch]$RemoveCloneAfter,
    [switch]$Gpu,
    [switch]$NoGpu,
    [string]$WorkspaceVolume = "nornir-cursor-worker-workspace",
    [switch]$SkipEnvFile,
    [string]$EnvFilePath = "",
    [string]$WorkspaceMountPath = "",
    [switch]$UseUniqueWorkspaceFolder,
    [string]$WorkspaceRunParent = "D:\Docker\mounted-configs\nornir-cursor-worker"
)

$ErrorActionPreference = "Continue"

. (Join-Path $PSScriptRoot "CursorWorkerWorkspaceGit.ps1")

function Set-CursorWorkerWindowTitle {
    param(
        [string]$Title = ""
    )
    try {
        if ($Title) {
            $Host.UI.RawUI.WindowTitle = $Title
        }
    }
    catch {
        # Non-interactive hosts (e.g. some CI) may not support RawUI.
    }
}

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

if ($UseUniqueWorkspaceFolder -and -not $LiveMount) {
    Write-Error "-UseUniqueWorkspaceFolder requires -LiveMount."
    exit 1
}

# Default to GPU on (override with -NoGpu). Keep -Gpu for backward compatibility.
$useGpu = $true
if ($PSBoundParameters.ContainsKey("Gpu")) { $useGpu = [bool]$Gpu }
if ($NoGpu) { $useGpu = $false }

# Shown until workspace folder name is known (e.g. per-run folder under WorkspaceRunParent).
$script:nornirAgentFallbackTitleId = [guid]::NewGuid().ToString("n").Substring(0, 8)
Set-CursorWorkerWindowTitle -Title $script:nornirAgentFallbackTitleId

if ($EnvFilePath) {
    $script:envFile = $EnvFilePath
}
elseif ($env:NORNIR_CURSOR_WORKER_ENV_FILE) {
    $script:envFile = $env:NORNIR_CURSOR_WORKER_ENV_FILE
}
else {
    $defaultRuntime = Join-Path $PSScriptRoot ".env.cursor-worker"
    $coLocatedRun = Join-Path $PSScriptRoot "nornir-cursor-worker.run.env"
    if (Test-Path -LiteralPath $defaultRuntime) {
        $script:envFile = $defaultRuntime
    }
    elseif (Test-Path -LiteralPath $coLocatedRun) {
        $script:envFile = $coLocatedRun
    }
    else {
        $ur = $env:NORNIR_DOCKER_USER_ROOT
        if ($ur -and $ur.Trim()) {
            $userRun = Join-Path $ur.Trim() "nornir-cursor-worker.run.env"
            if (Test-Path -LiteralPath $userRun) {
                $script:envFile = $userRun
            }
        }
        if (-not $script:envFile) {
            $script:envFile = $defaultRuntime
        }
    }
}

function Resolve-WorkspaceMountHostPath {
    if ([string]::IsNullOrWhiteSpace($WorkspaceMountPath)) {
        return $RepoRoot
    }
    $p = $WorkspaceMountPath.Trim()
    if (-not (Test-Path -LiteralPath $p)) {
        $null = New-Item -ItemType Directory -Force -Path $p
    }
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function Import-DotEnvFile {
    param(
        [string]$Path,
        # Never promote GitHub PATs into the host process (avoids GCM / leaked env); container gets them via --env-file only.
        [string[]]$ExcludeFromHostProcess = @("GITHUB_TOKEN", "GH_TOKEN")
    )
    $exclude = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $ExcludeFromHostProcess) { [void]$exclude.Add($x) }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            if ($exclude.Contains($name)) { return }
            $raw = $Matches[2].Trim()
            if (($raw.StartsWith('"') -and $raw.EndsWith('"')) -or ($raw.StartsWith("'") -and $raw.EndsWith("'"))) {
                $raw = $raw.Substring(1, $raw.Length - 2)
            }
            $existing = [Environment]::GetEnvironmentVariable($name, "Process")
            if ([string]::IsNullOrEmpty($existing)) {
                [Environment]::SetEnvironmentVariable($name, $raw, "Process")
            }
        }
    }
}

function Get-DotEnvVariableValue {
    param([string]$Path, [string]$VariableName)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $lineT = $line.Trim()
        if ($lineT -match '^\s*#' -or $lineT -eq '') { continue }
        if ($lineT -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            if (-not [string]::Equals($name, $VariableName, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $raw = $Matches[2].Trim()
            if (($raw.StartsWith('"') -and $raw.EndsWith('"')) -or ($raw.StartsWith("'") -and $raw.EndsWith("'"))) {
                $raw = $raw.Substring(1, $raw.Length - 2)
            }
            return $raw
        }
    }
    return $null
}

function Resolve-GitHubPatForHostClone {
    param([string]$DotEnvPath)
    foreach ($key in @("GITHUB_TOKEN", "GH_TOKEN")) {
        $v = Get-DotEnvVariableValue -Path $DotEnvPath -VariableName $key
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    foreach ($key in @("GITHUB_TOKEN", "GH_TOKEN")) {
        $v = [Environment]::GetEnvironmentVariable($key, "Process")
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        $v = [Environment]::GetEnvironmentVariable($key, "User")
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        $v = [Environment]::GetEnvironmentVariable($key, "Machine")
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $null
}

function New-IsolatedAgentGitClone {
    param(
        [string]$SourceRepoRoot,
        [string]$ParentDir,
        [string]$Url,
        [string]$Branch,
        [string]$GitHubToken = ""
    )
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRepoRoot ".git"))) {
        Write-Error "Isolated clone requires SourceRepoRoot to be a git checkout (missing .git)."
        exit 1
    }
    if (-not $Url) {
        Push-Location $SourceRepoRoot
        try {
            $Url = (git remote get-url origin 2>$null)
        }
        finally { Pop-Location }
    }
    if (-not $Url) {
        Write-Error "Could not read origin URL; pass -CloneUrl."
        exit 1
    }
    $token = $GitHubToken
    $cloneUrl = $Url
    if ($Url -match '^https://github\.com/' -and $token) {
        $cloneUrl = $Url -replace '^https://', "https://x-access-token:${token}@"
    }
    elseif ($Url -match '^https://' -and -not $token) {
        Write-Warning "Clone URL is HTTPS but GITHUB_TOKEN/GH_TOKEN is empty; private repos may fail."
    }
    if (-not $Branch) {
        Push-Location $SourceRepoRoot
        try {
            $br = (git rev-parse --abbrev-ref HEAD 2>$null)
        }
        finally { Pop-Location }
        if ($br -and $br -ne "HEAD") { $Branch = $br }
    }
    $null = New-Item -ItemType Directory -Force -Path $ParentDir
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $suffix = [guid]::NewGuid().ToString("n").Substring(0, 8)
    $folderName = "nornir-agent-$stamp-$suffix"
    $dest = Join-Path $ParentDir $folderName
    $gitArgs = @("-c", "credential.helper=", "clone")
    if ($Branch) {
        $gitArgs += @("-b", $Branch)
    }
    $gitArgs += @($cloneUrl, $dest)
    $logLine = "git $($gitArgs -join ' ')"
    if ($token) { $logLine = $logLine -replace [regex]::Escape($token), "***" }
    Write-Host "Isolated clone: $logLine"
    $prevGitTermPrompt = $env:GIT_TERMINAL_PROMPT
    $prevGcmInteractive = $env:GCM_INTERACTIVE
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:GCM_INTERACTIVE = "never"
    try {
        & git @gitArgs
    }
    finally {
        if ($null -eq $prevGitTermPrompt -or $prevGitTermPrompt -eq "") {
            [Environment]::SetEnvironmentVariable("GIT_TERMINAL_PROMPT", $null, "Process")
        }
        else {
            $env:GIT_TERMINAL_PROMPT = $prevGitTermPrompt
        }
        if ($null -eq $prevGcmInteractive -or $prevGcmInteractive -eq "") {
            [Environment]::SetEnvironmentVariable("GCM_INTERACTIVE", $null, "Process")
        }
        else {
            $env:GCM_INTERACTIVE = $prevGcmInteractive
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git clone failed."
        exit 1
    }
    return (Resolve-Path -LiteralPath $dest).ProviderPath
}

function Test-LocalDockerImage {
    param([string]$Ref)
    $null = docker image inspect $Ref 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Invoke-NornirWorkerBuild {
    param([string]$Root)
    Write-Host "Building from: $Root"
    Push-Location $Root
    try {
        docker build -f nornir-docker/dev/Dockerfile `
            --build-arg INSTALL_MONOREPO_EDITABLES=0 `
            -t nornir:dev-cursor-base $Root
        if ($LASTEXITCODE -ne 0) { throw "docker build nornir:dev-cursor-base failed" }
        docker build -f nornir-docker/Dockerfile.cursor-worker `
            --build-arg BASE_IMAGE=nornir:dev-cursor-base `
            -t nornir:cursor-worker $Root
        if ($LASTEXITCODE -ne 0) { throw "docker build nornir:cursor-worker failed" }
    }
    finally {
        Pop-Location
    }
}

if ($Rebuild) {
    Invoke-NornirWorkerBuild -Root $RepoRoot
}
elseif (-not (Test-LocalDockerImage -Ref $Image)) {
    Write-Host "Image '$Image' not found; building nornir:dev-cursor-base and worker..."
    Invoke-NornirWorkerBuild -Root $RepoRoot
}

if (-not $SkipEnvFile) {
    Import-DotEnvFile -Path $script:envFile
}

function Get-DockerWorkerEnvArgs {
    param([string]$DotEnvPath)
    if ($SkipEnvFile) { return @() }
    if (-not (Test-Path -LiteralPath $DotEnvPath)) { return @() }
    return @("--env-file", (Resolve-Path -LiteralPath $DotEnvPath).ProviderPath)
}

if (-not $SmokeTest -and -not $env:CURSOR_API_KEY) {
    Write-Error @"
CURSOR_API_KEY is not set in this PowerShell session.

With -SkipEnvFile: set `$env:CURSOR_API_KEY before running.
Otherwise: use -EnvFilePath, or set `$env:NORNIR_CURSOR_WORKER_ENV_FILE, or copy example.nornir-cursor-worker.run.env to nornir-docker/.env.cursor-worker and set CURSOR_API_KEY (loaded into the host process for docker -e; GITHUB_TOKEN is not).

Or run with -SmokeTest to verify Docker/agent CLI only.
"@
    exit 1
}

$cloneDirForCleanup = $null
$useMountedWorkspaceStrategy = $false
$effectiveRemoveCloneAfter = [bool]$RemoveCloneAfter

if ($KeepContainer -and $effectiveRemoveCloneAfter) {
    Write-Warning "-RemoveCloneAfter is not compatible with -KeepContainer (the container would keep a mount to a deleted host folder). Disabling removal."
    $effectiveRemoveCloneAfter = $false
}

if ($KeepContainer -and [string]::IsNullOrWhiteSpace($ContainerName)) {
    Write-Error "-ContainerName cannot be empty when -KeepContainer is set."
    exit 1
}

if ($SmokeTest) {
    $workspaceHostPath = Resolve-WorkspaceMountHostPath
    $volumeArgs = @("-v", "${workspaceHostPath}:/workspace")
    $useMountedWorkspaceStrategy = $true
    Write-Host "Mode: smoke test ($workspaceHostPath -> /workspace)"
    $smokeLeaf = Split-Path -Leaf $workspaceHostPath
    Set-CursorWorkerWindowTitle -Title $smokeLeaf
}
elseif ($LiveMount) {
    if ($UseUniqueWorkspaceFolder) {
        if ($WorkspaceMountPath) {
            Write-Warning "-WorkspaceMountPath is ignored when -UseUniqueWorkspaceFolder is set."
        }
        $null = New-Item -ItemType Directory -Force -Path $WorkspaceRunParent
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $suffix = [guid]::NewGuid().ToString("n").Substring(0, 8)
        $folderName = "nornir-cursor-worker-$stamp-$suffix"
        $workspaceHostPath = Join-Path $WorkspaceRunParent $folderName
        $null = New-Item -ItemType Directory -Force -Path $workspaceHostPath
        $workspaceHostPath = (Resolve-Path -LiteralPath $workspaceHostPath).ProviderPath
        if ($RemoveCloneAfter) {
            $cloneDirForCleanup = $workspaceHostPath
        }
        Write-Host "Mode: live mount unique empty folder -> /workspace (host: $workspaceHostPath)"
    }
    else {
        $workspaceHostPath = Resolve-WorkspaceMountHostPath
        Write-Host "Mode: live mount -> /workspace ($workspaceHostPath)"
    }
    $volumeArgs = @("-v", "${workspaceHostPath}:/workspace")
    if (-not $UseUniqueWorkspaceFolder) {
        $useMountedWorkspaceStrategy = $true
    }
}
elseif ($UseNamedDockerVolume) {
    $null = docker volume inspect $WorkspaceVolume 2>$null
    if ($LASTEXITCODE -ne 0) {
        docker volume create $WorkspaceVolume | Out-Null
    }
    $volumeArgs = @("-v", "${WorkspaceVolume}:/workspace")
    Write-Host "Mode: Docker volume $WorkspaceVolume -> /workspace"
}
else {
    $patForClone = Resolve-GitHubPatForHostClone -DotEnvPath $script:envFile
    $workspaceHostPath = New-IsolatedAgentGitClone -SourceRepoRoot $RepoRoot -ParentDir $AgentCloneParent -Url $CloneUrl -Branch $CloneBranch -GitHubToken $patForClone
    $cloneDirForCleanup = $workspaceHostPath
    $volumeArgs = @("-v", "${workspaceHostPath}:/workspace")
    $useMountedWorkspaceStrategy = $true
    Write-Host "Mode: isolated host clone -> /workspace (host: $workspaceHostPath)"
    Write-Host ""
}

if (-not $SmokeTest) {
    $nornirWinTitle = $script:nornirAgentFallbackTitleId
    if ($workspaceHostPath) {
        $nornirWinTitle = (Split-Path -Leaf $workspaceHostPath)
    }
    elseif ($UseNamedDockerVolume) {
        $nornirWinTitle = $WorkspaceVolume
    }
    Set-CursorWorkerWindowTitle -Title $nornirWinTitle
}

if ($SmokeTest) {
    $smokeName = "nornir-cursor-worker-smoke"
    docker rm -f $smokeName 2>$null | Out-Null
    Write-Host "Smoke test: agent --version, then sleep 30s"
    $smokeArgs = @(
        "run", "--rm", "--name", $smokeName,
        "--entrypoint", "/bin/sh"
    ) + (Get-DockerWorkerEnvArgs -DotEnvPath $script:envFile) + @(
        "-e", "HOME=/root",
        "-e", "NORNIR_WORKSPACE_STRATEGY=mounted"
    ) + $volumeArgs + @(
        "-w", "/workspace", $Image,
        "-c", "agent --version && sleep 30"
    )
    & docker @smokeArgs
    exit $LASTEXITCODE
}

$dockerArgs = @("run") + (Get-DockerWorkerEnvArgs -DotEnvPath $script:envFile) + @("-e", "HOME=/root")

if ($KeepContainer) {
    if ($ReplaceExistingContainer) {
        $null = docker rm -f $ContainerName 2>$null
    }
    else {
        $null = docker container inspect $ContainerName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Error "Container '$ContainerName' already exists. Use -ReplaceExistingContainer or choose a different -ContainerName."
            exit 1
        }
    }
    $dockerArgs += @("--name", $ContainerName)
}
else {
    $dockerArgs += "--rm"
}

if ($LiveMount -and $UseUniqueWorkspaceFolder) {
    # Explicit clone overrides NORNIR_WORKSPACE_STRATEGY in .env.cursor-worker (e.g. mounted).
    $dockerArgs += @("-e", "NORNIR_WORKSPACE_STRATEGY=clone")
}
elseif ($useMountedWorkspaceStrategy) {
    $dockerArgs += @("-e", "NORNIR_WORKSPACE_STRATEGY=mounted")
}

if ($useGpu) {
    $dockerArgs += @("--gpus", "all")
}

if ($Detach) {
    $dockerArgs += "-d"
}
else {
    $dockerArgs += "-it"
}

$dockerArgs += $volumeArgs
$dockerArgs += @("-w", "/workspace")

if ($env:CURSOR_API_KEY) {
    $dockerArgs += @("-e", "CURSOR_API_KEY=$($env:CURSOR_API_KEY)")
}

# GITHUB_TOKEN / GH_TOKEN are intentionally omitted: use .env.cursor-worker + --env-file only so the PAT is not re-injected from Windows profile.
foreach ($kv in @(
    "CURSOR_ACCESS_TOKEN",
    "CURSOR_TEAM_ID"
)) {
    $v = [Environment]::GetEnvironmentVariable($kv, "Process")
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($kv, "User") }
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($kv, "Machine") }
    if ($v) {
        $dockerArgs += @("-e", "${kv}=$v")
    }
}

$dockerArgs += $Image

Write-Host "Starting worker: $Image"
if ((Test-Path -LiteralPath $script:envFile) -and -not $SkipEnvFile) {
    Write-Host "  Env file: $($script:envFile) (+ GitHub PAT not loaded on host; CURSOR_API_KEY from process if set in file)"
}
elseif (-not $SkipEnvFile) {
    Write-Host "  Env: env file missing at $($script:envFile) (optional vars from user/machine; add file for GITHUB_TOKEN in container)"
}
if ($LiveMount -and $UseUniqueWorkspaceFolder) {
    Write-Host "  Workspace: NORNIR_WORKSPACE_STRATEGY=clone (empty bind-mounted folder; container clones into /workspace)"
}
elseif ($useMountedWorkspaceStrategy) {
    Write-Host "  Workspace: NORNIR_WORKSPACE_STRATEGY=mounted (existing checkout: git fetch; pull only if NORNIR_SYNC_REMOTE=1 in .env)"
}
Write-Host ""

$dockerExit = 1
try {
    & docker @dockerArgs
    $dockerExit = $LASTEXITCODE
}
finally {
    if ($effectiveRemoveCloneAfter -and $cloneDirForCleanup -and (Test-Path -LiteralPath $cloneDirForCleanup)) {
        $disp = Get-CursorWorkerRemoveCloneAfterDisposition -Path $cloneDirForCleanup
        Write-Host ""
        switch ($disp) {
            'remove' {
                Write-Host "Removing workspace (--RemoveCloneAfter): $cloneDirForCleanup"
                Remove-Item -LiteralPath $cloneDirForCleanup -Recurse -Force -ErrorAction SilentlyContinue
            }
            'skip-dirty' {
                Write-Warning "RemoveCloneAfter: not removing '$cloneDirForCleanup' because the git working tree is not clean (uncommitted changes, untracked files, or submodule changes). Commit, stash, or discard changes, then delete the folder manually if you still want it removed."
            }
            'skip-no-git' {
                Write-Warning "RemoveCloneAfter: not removing '$cloneDirForCleanup' because 'git' was not found on PATH and a clean working tree could not be verified. Remove the folder manually or install Git for Windows and re-run."
            }
            'skip-git-error' {
                Write-Warning "RemoveCloneAfter: not removing '$cloneDirForCleanup' because 'git status --porcelain' failed in that directory. Fix the repository or remove the folder manually."
            }
        }
    }
}

exit $dockerExit
