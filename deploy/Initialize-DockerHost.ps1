#Requires -Version 7.2
<#
.SYNOPSIS
  One-time setup of the machine-local Docker host layout on Windows or Ubuntu.

.DESCRIPTION
  Replaces Initialize-NornirBuildAppliance.ps1 and windows-docker-layout/Initialize-NornirCursorWorkerLayout.ps1
  so the dev box, the compute server and the web server all get the same tree:

    <root>/stack.ps1                       forwarding launcher -> <repo>/nornir-docker/deploy/stack.ps1
    <root>/Run/_host/host.env              machine settings (copied from examples/example.host.env)
    <root>/Run/_host/secrets/secrets.env   machine-wide secrets (GITHUB_TOKEN, ...)
    <root>/Run/_host/targets.psd1          remote targets (dev box only; -WithTargets)
    <root>/Run/<stack>/<stack>.run.env     per-stack settings (from each stack's Example)
    <root>/Run/<stack>/secrets/            per-stack secret files
    <root>/Run/nornir-net-mounts/          shared CIFS manifest + credentials (nornir-build)
    <root>/Builds/, Data/<stack>/, Certs/, Work/, Logs/<stack>/

  Existing files are never overwritten. Launchers are small forwarding scripts (never copies of
  the real script), so they keep working after `git pull` on every OS.

.PARAMETER Root
  Layout root. Default: NORNIR_DOCKER_USER_ROOT, else D:\Docker (Windows) or /srv/docker (Linux).

.PARAMETER Role
  Preset for NORNIR_DOCKER_HOST_STACKS: compute, web, iis, dev. Ignored when -Stacks is given.

.PARAMETER Stacks
  Explicit stacks this host runs (written to host.env when that key is empty).

.PARAMETER RepoRoot
  nornir monorepo checkout on this host. Default: the checkout containing this script.

.PARAMETER VikingRepoRoot
  Viking checkout on this host (needed for viking-* stacks).

.PARAMETER WithTargets
  Also copy example.targets.psd1 (use on the machine you deploy from).

.PARAMETER SetUserEnv
  Persist NORNIR_DOCKER_USER_ROOT and NORNIR_REPO_ROOT_HOST (Windows user env, or ~/.profile on Linux).

.PARAMETER SkipDoctor
  Do not run `stack.ps1 doctor` at the end.

.EXAMPLE
  # Ubuntu compute server (after bootstrap-ubuntu.sh)
  pwsh /srv/src/nornir/nornir-docker/deploy/Initialize-DockerHost.ps1 -Role compute -VikingRepoRoot /srv/src/Viking -SetUserEnv

.EXAMPLE
  # Windows dev box that deploys to the servers
  .\nornir-docker\deploy\Initialize-DockerHost.ps1 -Role dev -VikingRepoRoot D:\src\git\Viking -WithTargets -SetUserEnv
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [ValidateSet('compute', 'web', 'iis', 'dev')][string]$Role = 'dev',
    [string[]]$Stacks = @(),
    [string]$RepoRoot = '',
    [string]$VikingRepoRoot = '',
    [switch]$WithTargets,
    [switch]$SetUserEnv,
    [switch]$SkipDoctor
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StackLib.ps1')

$RolePresets = @{
    compute = @('nornir-build', 'nornir-dashboard', 'viking-segmentation')
    web     = @('viking-proxy', 'viking-certs', 'viking-identity', 'viking-annotation', 'viking-corrections')
    iis     = @('viking-iis')
    dev     = @('nornir-dashboard')
}

$layout = Get-DockerHostLayout -Root $Root
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
if ($VikingRepoRoot) { $VikingRepoRoot = (Resolve-Path -LiteralPath $VikingRepoRoot).ProviderPath }
$examples = Join-Path $PSScriptRoot 'examples'
$isWin = Test-NornirWindowsHost
if (-not $Stacks.Count) { $Stacks = $RolePresets[$Role] }
$Stacks = @($Stacks -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

Write-Host "Docker host layout: $($layout.Root)   (role: $Role; stacks: $($Stacks -join ', '))" -ForegroundColor Cyan

function New-Dir {
    param([string]$Path, [switch]$Private)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Force -Path $Path
        Write-Host "  created  $Path"
    }
    if ($Private -and -not $isWin) { & chmod 700 $Path }
}

function Copy-IfMissing {
    param([string]$Source, [string]$Destination, [switch]$Private)
    if (-not (Test-Path -LiteralPath $Source)) { Write-Warning "  template missing: $Source"; return }
    if (Test-Path -LiteralPath $Destination) { Write-Host "  exists   $Destination"; return }
    New-Dir (Split-Path -Parent $Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination
    if ($Private -and -not $isWin) { & chmod 600 $Destination }
    Write-Host "  copied   $Destination  (edit it)" -ForegroundColor Yellow
}

function Set-EnvFileDefault {
    <# Fill KEY= in an env file only when the key is present with an empty value. #>
    param([string]$Path, [string]$Key, [string]$Value)
    if (-not $Value -or -not (Test-Path -LiteralPath $Path)) { return }
    $lines = Get-Content -LiteralPath $Path
    $changed = $false
    $lines = foreach ($l in $lines) {
        if ($l -match "^\s*$([regex]::Escape($Key))\s*=\s*$") { $changed = $true; "$Key=$Value" } else { $l }
    }
    if ($changed) {
        Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
        Write-Host "  set      $Key=$Value in $(Split-Path -Leaf $Path)"
    }
}

function Write-ForwardingLauncher {
    <#
    .SYNOPSIS
      Write a tiny launcher that resolves the repo at run time and forwards all arguments.
    .DESCRIPTION
      Replaces copies of repo scripts (which broke because they dot-source sibling helpers).
      An existing non-generated file is kept as <name>.bak.
    #>
    param([string]$Path, [string]$RepoRelative)
    $marker = '# generated-by: Initialize-DockerHost.ps1'
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path -Force
        if ($existing.LinkType) {
            Remove-Item -LiteralPath $Path -Force
        }
        elseif (-not ((Get-Content -LiteralPath $Path -Raw) -match [regex]::Escape($marker))) {
            Move-Item -LiteralPath $Path -Destination "$Path.bak" -Force
            Write-Host "  backup   $Path.bak (old copy replaced by a forwarding launcher)"
        }
    }
    $rel = $RepoRelative -replace '\\', '/'
    # Launchers live at <root>/stack.ps1 or <root>/Builds/<x>/<name>.ps1 (two levels down).
    $parentFull = (Resolve-Path -LiteralPath (Split-Path -Parent $Path)).ProviderPath.TrimEnd([char[]]'\/')
    $rootFull = (Resolve-Path -LiteralPath $layout.Root).ProviderPath.TrimEnd([char[]]'\/')
    $up = if ($parentFull -ne $rootFull) { "Join-Path (Join-Path `$PSScriptRoot '..') '..'" } else { '$PSScriptRoot' }
    $fallback = $RepoRoot -replace "'", "''"
    $content = @"
$marker
# Forwards to <NORNIR_REPO_ROOT_HOST>/$rel so this launcher survives git pulls on any OS.
`$layoutRoot = $up
`$repo = `$env:NORNIR_REPO_ROOT_HOST
if (-not `$repo) {
    `$f = Join-Path (Join-Path (Join-Path `$layoutRoot 'Run') '_host') 'host.env'
    if (Test-Path -LiteralPath `$f) {
        `$m = Select-String -LiteralPath `$f -Pattern '^\s*NORNIR_REPO_ROOT_HOST\s*=\s*(.+?)\s*$' | Select-Object -First 1
        if (`$m) { `$repo = `$m.Matches[0].Groups[1].Value.Trim('"', "'") }
    }
}
if (-not `$repo) { `$repo = '$fallback' }
if (-not `$env:NORNIR_DOCKER_USER_ROOT) { `$env:NORNIR_DOCKER_USER_ROOT = (Resolve-Path -LiteralPath `$layoutRoot).ProviderPath }
`$target = Join-Path `$repo '$rel'
if (-not (Test-Path -LiteralPath `$target)) { Write-Error "Not found: `$target (set NORNIR_REPO_ROOT_HOST in Run/_host/host.env)"; exit 1 }
& `$target @args
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding utf8
    if (-not $isWin) { & chmod 755 $Path }
    Write-Host "  launcher $Path -> $rel"
}

Write-Host 'Directories:'
New-Dir $layout.Root
foreach ($d in @($layout.HostDir, $layout.Run, $layout.Builds, $layout.Data, $layout.Certs, $layout.Work, $layout.Logs)) { New-Dir $d }
New-Dir (Join-DockerHostPath $layout.HostDir 'secrets') -Private
$hostEnvMap = @{ NORNIR_REPO_ROOT_HOST = $RepoRoot; VIKING_REPO_ROOT_HOST = $VikingRepoRoot }
$registry = Import-StackRegistry -HostEnv $hostEnvMap
foreach ($s in $Stacks) {
    $d = Get-StackDirs -Stack $s -Root $layout.Root
    New-Dir $d.Run
    New-Dir $d.Secrets -Private
    New-Dir $d.Data
    New-Dir $d.Logs
}

Write-Host 'Host files:'
Copy-IfMissing (Join-Path $examples 'example.host.env') $layout.HostEnv
Copy-IfMissing (Join-Path $examples 'example.host.secrets.env') $layout.HostSecretsEnv -Private
Set-EnvFileDefault $layout.HostEnv 'NORNIR_DOCKER_USER_ROOT' $layout.Root
Set-EnvFileDefault $layout.HostEnv 'NORNIR_REPO_ROOT_HOST' $RepoRoot
Set-EnvFileDefault $layout.HostEnv 'VIKING_REPO_ROOT_HOST' $VikingRepoRoot
Set-EnvFileDefault $layout.HostEnv 'NORNIR_DOCKER_HOST_STACKS' ($Stacks -join ',')
if ($WithTargets -or $Role -eq 'dev') { Copy-IfMissing (Join-Path $examples 'example.targets.psd1') $layout.Targets }

Write-Host 'Stack files:'
foreach ($s in $Stacks) {
    $e = $registry[$s]
    if (-not $e) {
        Write-Warning "  stack '$s' not in any registry (Viking stacks need -VikingRepoRoot)"
        continue
    }
    $d = Get-StackDirs -Stack $s -Root $layout.Root
    if ($e.Example) { Copy-IfMissing (Join-DockerHostPath $e.RepoRoot $e.Example) $d.RunEnv }
    foreach ($sx in @($e.SecretExamples)) {
        if ($sx) { Copy-IfMissing (Join-DockerHostPath $e.RepoRoot $sx.From) (Join-DockerHostPath $d.Secrets $sx.To) -Private }
    }
}
if ($Stacks -contains 'nornir-build') {
    $net = Join-DockerHostPath $layout.Run 'nornir-net-mounts'
    New-Dir (Join-DockerHostPath $net 'net-mounts')
    New-Dir (Join-DockerHostPath $net 'secrets' 'net-creds') -Private
    Copy-IfMissing (Join-DockerHostPath $RepoRoot 'nornir-docker/dev/example.nas-mounts.tsv') (Join-DockerHostPath $net 'net-mounts' 'nas-mounts.tsv')
    Copy-IfMissing (Join-DockerHostPath $RepoRoot 'nornir-docker/example.nornir-net-mounts.run.env') (Join-DockerHostPath $net '.run.nornir-net-mounts.env')
    Copy-IfMissing (Join-DockerHostPath $examples 'example.net-creds.cred') (Join-DockerHostPath $net 'secrets' 'net-creds' 'storage.cred') -Private
}

Write-Host 'Launchers:'
Write-ForwardingLauncher -Path (Join-DockerHostPath $layout.Root 'stack.ps1') -RepoRelative 'nornir-docker/deploy/stack.ps1'
$legacyBuild = Join-DockerHostPath $layout.Builds 'nornir-build'
if ((Test-Path -LiteralPath $legacyBuild) -or $Stacks -contains 'nornir-build') {
    New-Dir $legacyBuild
    Write-ForwardingLauncher -Path (Join-DockerHostPath $legacyBuild 'start-nornir-build.ps1') -RepoRelative 'nornir-docker/start-nornir-build.ps1'
    Write-ForwardingLauncher -Path (Join-DockerHostPath $legacyBuild 'start-dashboard.ps1') -RepoRelative 'nornir-docker/start-dashboard.ps1'
}

if ($SetUserEnv) {
    Write-Host 'Environment:'
    if ($isWin) {
        [Environment]::SetEnvironmentVariable('NORNIR_DOCKER_USER_ROOT', $layout.Root, 'User')
        [Environment]::SetEnvironmentVariable('NORNIR_REPO_ROOT_HOST', $RepoRoot, 'User')
        Write-Host '  set user env NORNIR_DOCKER_USER_ROOT, NORNIR_REPO_ROOT_HOST (new shells)'
    }
    else {
        $profileFile = Join-Path $HOME '.profile'
        $block = @(
            '# nornir docker host (Initialize-DockerHost.ps1)',
            "export NORNIR_DOCKER_USER_ROOT='$($layout.Root)'",
            "export NORNIR_REPO_ROOT_HOST='$RepoRoot'",
            "alias stack='pwsh -NoLogo -NoProfile -File $($layout.Root)/stack.ps1'"
        )
        $existing = if (Test-Path $profileFile) { Get-Content $profileFile -Raw } else { '' }
        if ($existing -notmatch 'Initialize-DockerHost\.ps1') {
            Add-Content -LiteralPath $profileFile -Value ($block -join "`n")
            Write-Host "  appended exports + 'stack' alias to $profileFile (re-login)"
        }
        else { Write-Host "  $profileFile already configured" }
    }
}
$env:NORNIR_DOCKER_USER_ROOT = $layout.Root
$env:NORNIR_REPO_ROOT_HOST = $RepoRoot

Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host "  1. Edit $($layout.HostEnv) (VIKING_DOMAIN, TLS_MODE, TLS_EMAIL, ...)"
Write-Host "  2. Edit each Run/<stack>/<stack>.run.env; generate secrets: stack.ps1 secrets new <stack>"
Write-Host "  3. stack.ps1 doctor     then     stack.ps1 all up"
Write-Host "  Docs: https://nornir.github.io/deployment/"

if (-not $SkipDoctor) {
    Write-Host ''
    & (Join-Path $PSScriptRoot 'stack.ps1') doctor -Root $layout.Root
}
