#Requires -Version 7.2
<#
.SYNOPSIS
  Copy machine-local files from the old D:\Docker layout into the stack layout (never deletes).

.DESCRIPTION
  The old layout grew per service (Builds\IdentityServer\.env.All*, mounted-configs\IdentityServer,
  Builds\cloudflare.ini, Run\segmentation-server models, Run\nornir-dashboard\dashboard.run.env ...).
  The stack layout keeps every stack in the same shape:

    Run/<stack>/<stack>.run.env   Run/<stack>/secrets/   Data/<stack>/   Certs/   Work/   Logs/

  This script prints an old -> new table and copies each existing source. Env files that map to
  one run.env are concatenated (later files win when compose reads them), each with a header that
  names its source. When a destination already exists, it writes <dest>.migrated next to it so you
  can diff and merge by hand. Old files are left in place; delete them yourself after checking.

  Variable names inside migrated env files are NOT renamed. Compare each file with its
  example.<stack>.run.env (the renamed keys are listed in the deployment docs, "Migrating").

.PARAMETER From
  Old layout root. Default: NORNIR_DOCKER_USER_ROOT, else D:\Docker.

.PARAMETER To
  New layout root. Default: same as -From (in-place migration into the new folder names).

.PARAMETER VikingRepoRoot
  Viking checkout whose Servers/IdentityServer/DataProtectionKeys the old Identity compose used
  (copied to Data/viking-identity/DataProtectionKeys so users stay signed in). Default: VIKING_REPO_ROOT_HOST.

.PARAMETER IncludeWork
  Also copy mounted-configs\nornir-build-* session folders into Work/ (large; usually unnecessary).

.EXAMPLE
  .\Move-DockerHostLayout.ps1 -WhatIf

.EXAMPLE
  .\Move-DockerHostLayout.ps1 -From D:\Docker -To \\newserver\c$\srv\docker
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$From = '',
    [string]$To = '',
    [string]$VikingRepoRoot = '',
    [switch]$IncludeWork
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StackLib.ps1')

$From = Get-DockerHostRoot -Root $From
if (-not $To) { $To = $From }
if (-not $VikingRepoRoot) { $VikingRepoRoot = Get-RepoRootFromEnv -VarName 'VIKING_REPO_ROOT_HOST' -HostEnv (Read-HostEnv -Root $To) }

# Kind: env (concatenate into one run/secrets env), file, dir (copy folder contents)
$map = @(
    @{ Kind = 'env'; Dest = 'Run/nornir-dashboard/nornir-dashboard.run.env'; Src = @('Run/nornir-dashboard/dashboard.run.env') }
    @{ Kind = 'env'; Dest = 'Run/viking-identity/viking-identity.run.env'; Src = @('Builds/IdentityServer/.env.All', 'Builds/IdentityServer/.env.All.Production', 'Builds/IdentityServer/.env.All.Docker') }
    @{ Kind = 'file'; Dest = 'Run/viking-identity/secrets/Duende_License.key'; Src = @('Configs/IdentityServer/Duende_License.key', 'mounted-configs/IdentityServer/Duende_License.key') }
    @{ Kind = 'file'; Dest = 'Run/viking-identity/secrets/secrets.json'; Src = @('mounted-configs/IdentityServer/secrets.json') }
    @{ Kind = 'dir'; Dest = 'Data/viking-identity/DataProtectionKeys'; Src = @('mounted-configs/IdentityServer/DataProtectionKeys'); SrcAbs = @($(if ($VikingRepoRoot) { Join-DockerHostPath $VikingRepoRoot 'Servers/IdentityServer/DataProtectionKeys' })) }
    @{ Kind = 'file'; Dest = 'Run/viking-certs/secrets/cloudflare.ini'; Src = @('Builds/cloudflare.ini', 'Builds/IdentityServer/cloudflare.ini', 'Builds/SegmentationServer/cloudflare.ini') }
    @{ Kind = 'env'; Dest = 'Run/viking-annotation/viking-annotation.run.env'; Src = @('Builds/GrpcAnnotationService/.env.Docker', 'Builds/AnnotationSql/.env') }
    @{ Kind = 'dir'; Dest = 'Data/viking-corrections/corrections'; Src = @('Builds/GrpcAnnotationService/corrections') }
    @{ Kind = 'env'; Dest = 'Run/viking-corrections/viking-corrections.run.env'; Src = @('Builds/SectionCorrectionService/.env.Docker') }
    @{ Kind = 'env'; Dest = 'Run/viking-segmentation/viking-segmentation.run.env'; Src = @('Builds/SegmentationServer/.env') }
    @{ Kind = 'dir'; Dest = 'Data/viking-segmentation/models'; Src = @('Run/segmentation-server') }
    @{ Kind = 'env'; Dest = 'Run/sam2-gallery/sam2-gallery.run.env'; Src = @('Builds/AnnotationGallery/.env') }
)

$rows = [System.Collections.Generic.List[object]]::new()

function Resolve-Rel([string]$Root, [string]$Rel) { Join-DockerHostPath $Root $Rel }

function Get-FreeDestination([string]$Dest) {
    if (Test-Path -LiteralPath $Dest) { return "$Dest.migrated" }
    return $Dest
}

foreach ($m in $map) {
    $srcs = @(@($m.Src | ForEach-Object { Resolve-Rel $From $_ }) + @($m.SrcAbs | Where-Object { $_ }) | Where-Object { Test-Path -LiteralPath $_ })
    $destFull = Resolve-Rel $To $m.Dest
    if (-not $srcs.Count) {
        $rows.Add([pscustomobject]@{ Action = 'skip (no source)'; From = ($m.Src -join ' + '); To = $m.Dest })
        continue
    }
    if ($m.Kind -ne 'env') { $srcs = @($srcs[0]) }  # first existing source wins for files/dirs
    $target = Get-FreeDestination $destFull
    $action = if ($target -ne $destFull) { 'copy -> .migrated (dest exists)' } else { 'copy' }
    $rows.Add([pscustomobject]@{ Action = $action; From = (($srcs | ForEach-Object { if ($_.StartsWith($From)) { [System.IO.Path]::GetRelativePath($From, $_) } else { $_ } }) -join ' + '); To = [System.IO.Path]::GetRelativePath($To, $target) })
    if (-not $PSCmdlet.ShouldProcess($target, "copy from $($srcs -join ', ')")) { continue }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
    switch ($m.Kind) {
        'env' {
            $out = [System.Collections.Generic.List[string]]::new()
            $out.Add("# Migrated by Move-DockerHostLayout.ps1 on $(Get-Date -Format s). Review against the example.<stack>.run.env.")
            foreach ($s in $srcs) {
                $out.Add('')
                $out.Add("# ---- from $s ----")
                foreach ($l in (Get-Content -LiteralPath $s)) { $out.Add($l) }
            }
            Set-Content -LiteralPath $target -Value $out -Encoding utf8
        }
        'file' { Copy-Item -LiteralPath $srcs[0] -Destination $target }
        'dir' {
            $null = New-Item -ItemType Directory -Force -Path $target
            Copy-Item -Path (Join-Path $srcs[0] '*') -Destination $target -Recurse -Force
        }
    }
    if ($target -like "*$([IO.Path]::DirectorySeparatorChar)secrets$([IO.Path]::DirectorySeparatorChar)*" -and -not (Test-NornirWindowsHost)) { & chmod 600 $target }
}

# Disposable build sessions: mounted-configs/nornir-build-* -> Work/
$legacyWork = Resolve-Rel $From 'mounted-configs'
$sessions = if (Test-Path -LiteralPath $legacyWork) { @(Get-ChildItem -LiteralPath $legacyWork -Directory -Filter 'nornir-build-*') } else { @() }
if ($sessions.Count) {
    if ($IncludeWork) {
        foreach ($d in $sessions) {
            $dest = Resolve-Rel $To "Work/$($d.Name)"
            $rows.Add([pscustomobject]@{ Action = 'copy'; From = "mounted-configs/$($d.Name)"; To = "Work/$($d.Name)" })
            if ($PSCmdlet.ShouldProcess($dest, 'copy session folder')) { Copy-Item -LiteralPath $d.FullName -Destination $dest -Recurse }
        }
    }
    else {
        $rows.Add([pscustomobject]@{ Action = "leave ($($sessions.Count) sessions; -IncludeWork to copy)"; From = 'mounted-configs/nornir-build-*'; To = 'Work/' })
    }
}

# Things that are replaced rather than copied
foreach ($r in @(
        @{ From = 'Builds/ReverseProxy (Nginx Proxy Manager GUI state)'; To = 'viking-proxy stack (routes rendered from VIKING_HOSTNAME_* / VIKING_UPSTREAM_*)' }
        @{ From = 'Builds/*/rebuild-and-start.ps1, restart_omni.cmd'; To = 'stack.ps1 <stack> rebuild|restart' }
        @{ From = 'Builds/nornir-build/*.ps1 (copies)'; To = 'forwarding launchers (Initialize-DockerHost.ps1)' }
        @{ From = '*-letsencrypt docker volumes'; To = 'Certs/<TLS_CERT_NAME>/ (stack.ps1 certs ...)' }
    )) {
    $rows.Add([pscustomobject]@{ Action = 'replaced'; From = $r.From; To = $r.To })
}

$rows | Format-Table -AutoSize -Wrap | Out-Host
Write-Host "Old files were not modified. Review *.migrated files, then run: stack.ps1 doctor" -ForegroundColor Yellow
