<#
.SYNOPSIS
  Symlink machine-local env files from D:\Docker\Builds\nornir into nornir-docker\.

.DESCRIPTION
  Docker Compose (and Dev Containers) load nornir-docker\.env from the first compose file
  directory. This script points that file (and optional build-arg env files) at the
  canonical copies under $NORNIR_DOCKER_USER_ROOT\Builds\nornir so edits there are picked
  up without copying.

  Re-run after a fresh clone or if links are replaced by regular files.

  Requires permission to create symbolic links (Windows Developer Mode or elevated shell).
  Falls back to hard links for individual env files when symlinks are not permitted.
#>
[CmdletBinding()]
param(
    [string]$BuildRoot = $(if ($env:NORNIR_DOCKER_USER_ROOT) {
            Join-Path $env:NORNIR_DOCKER_USER_ROOT 'Builds\nornir'
        } else {
            'D:\Docker\Builds\nornir'
        }),
    [string]$RepoDockerDir = $(if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path })
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BuildRoot)) {
    throw "Build env root not found: $BuildRoot. Set NORNIR_DOCKER_USER_ROOT or pass -BuildRoot."
}

$links = @(
    '.env',
    '.build.nornir-dev.env',
    '.build.nornir-cursor-worker.env'
)

foreach ($name in $links) {
    $target = Join-Path $BuildRoot $name
    $linkPath = Join-Path $RepoDockerDir $name

    if (-not (Test-Path -LiteralPath $target)) {
        Write-Warning "Skipping $name - target missing: $target"
        continue
    }

    $targetFull = (Resolve-Path -LiteralPath $target).Path

    if (Test-Path -LiteralPath $linkPath) {
        $existing = Get-Item -LiteralPath $linkPath -Force
        if ($existing.LinkType -eq 'SymbolicLink' -and $existing.Target -contains $targetFull) {
            Write-Host "OK (already linked): $linkPath -> $targetFull"
            continue
        }
        Remove-Item -LiteralPath $linkPath -Force
    }

    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetFull -ErrorAction Stop | Out-Null
        Write-Host "Linked (symlink): $linkPath -> $targetFull"
    }
    catch {
        if (Test-Path -LiteralPath $linkPath) {
            Remove-Item -LiteralPath $linkPath -Force
        }
        New-Item -ItemType HardLink -Path $linkPath -Target $targetFull | Out-Null
        Write-Host "Linked (hard link): $linkPath -> $targetFull"
    }
}

Write-Host ""
Write-Host 'Dev Containers reads nornir-docker/.env via compose.cursor-dev.yaml.'
Write-Host "Edit env files under: $BuildRoot"
