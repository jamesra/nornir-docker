# Shared git disposition helpers for start-cursor-worker.ps1 and Cleanup-CursorWorkerClones.ps1.
# Dot-source this file:  . (Join-Path $PSScriptRoot 'CursorWorkerWorkspaceGit.ps1')

function Get-CursorWorkerRemoveCloneAfterDisposition {
    <#
    .SYNOPSIS
      Decides whether a workspace path may be deleted: missing path / no .git => remove;
      git repo with empty porcelain => remove; otherwise skip with a reason code.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return 'remove'
    }
    $gitMeta = Join-Path $Path ".git"
    if (-not (Test-Path -LiteralPath $gitMeta)) {
        return 'remove'
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return 'skip-no-git'
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $porcelain = & git -C $Path status --porcelain 2>&1
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -ne 0) {
        return 'skip-git-error'
    }
    $text = if ($porcelain -is [array]) { ($porcelain | Out-String) } else { [string]$porcelain }
    if ([string]::IsNullOrWhiteSpace($text.Trim())) {
        return 'remove'
    }
    return 'skip-dirty'
}
