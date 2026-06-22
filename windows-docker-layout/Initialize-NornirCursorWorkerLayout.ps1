<#
.SYNOPSIS
  Creates D:\Docker\Builds\nornir-cursor-worker layout: directory, optional .env from example, optional symlink to thin launcher.
  Symlinks are not created by git or Docker; run this script (or CONFIG_LAYOUT.md manual steps) once.

.PARAMETER LayoutRoot
  Default: D:\Docker\Builds\nornir-cursor-worker

.PARAMETER MonorepoRoot
  Path to nornir monorepo (parent of nornir-docker). Used for symlink target and example env copy.

.PARAMETER SkipSymlink
  Do not create start-nornir-cursor-worker.ps1 symlink (useful if symlinks require admin and you prefer a shortcut or manual link).

.PARAMETER SkipEnvCopy
  Do not copy .env.cursor-worker.example to .env.cursor-worker if missing.
#>
param(
    [string]$LayoutRoot = "D:\Docker\Builds\nornir-cursor-worker",
    [Parameter(Mandatory = $true)]
    [string]$MonorepoRoot,
    [switch]$SkipSymlink,
    [switch]$SkipEnvCopy
)

$ErrorActionPreference = "Stop"
try {
    $Host.UI.RawUI.WindowTitle = "nornir-layout"
}
catch {
}
$MonorepoRoot = (Resolve-Path -LiteralPath $MonorepoRoot).ProviderPath
Write-Host "Nornir cursor-worker layout: $LayoutRoot"
Write-Host ""
$null = New-Item -ItemType Directory -Force -Path $LayoutRoot

$example = Join-Path $MonorepoRoot "nornir-docker\.env.cursor-worker.example"
$envOut = Join-Path $LayoutRoot ".env.cursor-worker"
if (-not $SkipEnvCopy -and (Test-Path -LiteralPath $example) -and -not (Test-Path -LiteralPath $envOut)) {
    Copy-Item -LiteralPath $example -Destination $envOut
    Write-Host "Created $envOut (edit CURSOR_API_KEY and GITHUB_TOKEN)."
}

if (-not $SkipSymlink) {
    $target = Join-Path $MonorepoRoot "nornir-docker\windows-docker-layout\start-nornir-cursor-worker.ps1"
    $link = Join-Path $LayoutRoot "start-nornir-cursor-worker.ps1"
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Warning "Thin launcher not found at $target; skipping symlink."
    }
    elseif (Test-Path -LiteralPath $link) {
        Write-Host "Symlink path already exists: $link (leave as-is or remove and re-run)."
    }
    else {
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
            Write-Host "Created symlink: $link -> $target"
        }
        catch {
            Write-Warning "Could not create symlink (try elevated shell or Windows Developer Mode): $($_.Exception.Message)"
            Write-Host ""
            Write-Host "Elevated cmd.exe fallback (file symlink):"
            Write-Host "  mklink `"$link`" `"$target`""
        }
    }
}

Write-Host ""
Write-Host "Set user env NORNIR_MONOREPO_ROOT=$MonorepoRoot (or pass -RepoRoot to the launcher)."
Write-Host "Run: & '$LayoutRoot\start-nornir-cursor-worker.ps1'  (after symlink) or:"
Write-Host "  & '$MonorepoRoot\nornir-docker\start-cursor-worker.ps1' -LiveMount -UseUniqueWorkspaceFolder -EnvFilePath '$envOut'"
