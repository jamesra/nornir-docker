# Helpers for the nornir-builddashboard submodule (sources) vs nornir-dashboard Docker image/service name.

function Get-NornirBuildDashboardDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )
    return (Join-Path $RepoRoot 'nornir-builddashboard')
}

function Test-NornirBuildDashboardSources {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )
    $dockerfile = Join-Path (Get-NornirBuildDashboardDir -RepoRoot $RepoRoot) 'Dockerfile'
    return (Test-Path -LiteralPath $dockerfile)
}

function Initialize-NornirBuildDashboardSubmodule {
    <#
    .SYNOPSIS
      Ensure nornir-builddashboard sources exist (init submodule when needed).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $buildDashboardDir = Get-NornirBuildDashboardDir -RepoRoot $RepoRoot
    if (Test-NornirBuildDashboardSources -RepoRoot $RepoRoot) {
        return $buildDashboardDir
    }

    Write-Host "nornir-builddashboard sources not found under $buildDashboardDir"
    Write-Host 'Running: git submodule update --init nornir-builddashboard'
    & git -C $RepoRoot submodule update --init nornir-builddashboard
    if ($LASTEXITCODE -ne 0) {
        Write-Error @"
Failed to initialize the nornir-builddashboard submodule.
The Docker service/image is named nornir-dashboard, but build sources live in the
monorepo submodule directory nornir-builddashboard (not nornir-dashboard).
From the monorepo root run: git submodule update --init nornir-builddashboard
"@
    }

    if (-not (Test-NornirBuildDashboardSources -RepoRoot $RepoRoot)) {
        Write-Error "Missing Dockerfile under $buildDashboardDir. Check out the nornir-builddashboard submodule."
    }

    return $buildDashboardDir
}

function Test-NornirDashboardImagePresent {
    & docker image inspect nornir-dashboard:latest 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-NornirBuildDashboardComposeContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )
    $buildDashboardDir = Initialize-NornirBuildDashboardSubmodule -RepoRoot $RepoRoot
    $resolved = (Resolve-Path -LiteralPath $buildDashboardDir).ProviderPath
    $env:NORNIR_BUILDDASHBOARD_CONTEXT = $resolved
    return $resolved
}
