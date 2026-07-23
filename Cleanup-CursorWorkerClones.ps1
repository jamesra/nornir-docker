<#
.SYNOPSIS
  Remove disposable Nornir cursor-worker workspace clones on the host when safe.

.DESCRIPTION
  Scans configurable parent directories for folders matching start-cursor-worker.ps1 naming:
  - WorkspaceRunParent: nornir-cursor-worker-*
  - AgentCloneParent: nornir-agent-*

  Deletes a folder only when:
  - No Docker container (running or stopped) has a bind mount Source equal to that path; and
  - Get-CursorWorkerRemoveCloneAfterDisposition returns 'remove' (clean git porcelain, or no .git).

  Use -WhatIf to list actions without deleting. Use -Confirm:$false to skip confirmation prompts.

.PARAMETER WorkspaceRunParent
  Parent of per-run unique folders (default matches start-cursor-worker.ps1).

.PARAMETER AgentCloneParent
  Parent of isolated host clones (default matches start-cursor-worker.ps1).

.EXAMPLE
  .\Cleanup-CursorWorkerClones.ps1 -WhatIf

.EXAMPLE
  .\Cleanup-CursorWorkerClones.ps1 -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$WorkspaceRunParent = "D:\Docker\mounted-configs\nornir-cursor-worker",
    [string]$AgentCloneParent = "D:\agents"
)

$ErrorActionPreference = "Continue"

. (Join-Path $PSScriptRoot "CursorWorkerWorkspaceGit.ps1")

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Cleanup-CursorWorkerClones: 'docker' is not on PATH. Bind mounts cannot be verified; exiting without removing any folders."
    exit 2
}
$null = docker version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Cleanup-CursorWorkerClones: 'docker' CLI is not usable. Exiting without removing any folders."
    exit 2
}

function Normalize-NornirHostPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    try {
        return [System.IO.Path]::GetFullPath($Path.Trim())
    }
    catch {
        return $Path.Trim()
    }
}

function Get-DockerBindMountSourceIndex {
    <#
    Returns a hashtable: normalized bind Source path -> array of short container IDs.
    #>
    $idx = @{}
    $out = docker ps -aq 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Cleanup-CursorWorkerClones: docker ps -aq failed (exit $LASTEXITCODE). Exiting without removing any folders."
        exit 3
    }
    $lines = @($out | ForEach-Object { $_.ToString() })
    foreach ($line in $lines) {
        $id = $line.Trim()
        if (-not $id) { continue }
        $json = docker inspect $id --format '{{json .Mounts}}' 2>&1
        if ($LASTEXITCODE -ne 0) { continue }
        try {
            $mounts = $json | ConvertFrom-Json
        }
        catch {
            continue
        }
        if (-not $mounts) { continue }
        foreach ($m in @($mounts)) {
            if ($null -eq $m -or $m.Type -ne 'bind') { continue }
            $src = $m.Source
            if ([string]::IsNullOrWhiteSpace($src)) { continue }
            $norm = Normalize-NornirHostPath -Path $src
            if (-not $idx.ContainsKey($norm)) {
                $idx[$norm] = [System.Collections.ArrayList]::new()
            }
            $short = if ($id.Length -ge 12) { $id.Substring(0, 12) } else { $id }
            if ($idx[$norm] -notcontains $short) {
                [void]$idx[$norm].Add($short)
            }
        }
    }
    return $idx
}

function Get-NornirCursorWorkerCleanupCandidates {
    param(
        [string]$Parent,
        [string]$NameRegex
    )
    if (-not (Test-Path -LiteralPath $Parent)) {
        Write-Verbose "Parent does not exist (skip): $Parent"
        return @()
    }
    return @(Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $NameRegex })
}

$bindIndex = Get-DockerBindMountSourceIndex

$workspaceCandidates = Get-NornirCursorWorkerCleanupCandidates -Parent $WorkspaceRunParent -NameRegex '^nornir-cursor-worker-'
$agentCandidates = Get-NornirCursorWorkerCleanupCandidates -Parent $AgentCloneParent -NameRegex '^nornir-agent-'

$all = @($workspaceCandidates) + @($agentCandidates)
if ($all.Count -eq 0) {
    Write-Host "No candidate folders found under WorkspaceRunParent or AgentCloneParent."
    exit 0
}

$removed = 0
$skipped = 0

foreach ($dir in $all) {
    $full = $dir.FullName
    $norm = Normalize-NornirHostPath -Path $full

    if ($bindIndex.ContainsKey($norm)) {
        $ids = ($bindIndex[$norm] | ForEach-Object { $_ }) -join ', '
        Write-Host "[skip docker] $full (bind-mounted by container(s): $ids)"
        $skipped++
        continue
    }

    $disp = Get-CursorWorkerRemoveCloneAfterDisposition -Path $full
    if ($disp -ne 'remove') {
        Write-Host "[skip git:$disp] $full"
        $skipped++
        continue
    }

    if ($PSCmdlet.ShouldProcess($full, "Remove directory (clean git, not bind-mounted)")) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        Write-Host "[removed] $full"
        $removed++
    }
}

Write-Host ""
Write-Host "Done. Removed: $removed  Skipped: $skipped"
