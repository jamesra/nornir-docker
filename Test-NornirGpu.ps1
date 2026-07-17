<#
.SYNOPSIS
  Probe Docker GPU passthrough and set NORNIR_DOCKER_GPU for nornir-docker launchers.

.DESCRIPTION
  Runs a short nvidia-smi container with --gpus all. On success sets NORNIR_DOCKER_GPU=1;
  otherwise clears NORNIR_DOCKER_GPU. Dot-source or call before start-nornir-build.ps1 / nd-build.

.PARAMETER Quiet
  Suppress status messages.

.OUTPUTS
  Boolean: $true when GPU is available.
#>
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$null = docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu22.04 nvidia-smi 2>$null
$ok = ($LASTEXITCODE -eq 0)
if ($ok) {
    $env:NORNIR_DOCKER_GPU = '1'
    if (-not $Quiet) { Write-Host 'GPU detected: NORNIR_DOCKER_GPU=1 (--gpus all)' }
}
else {
    Remove-Item Env:NORNIR_DOCKER_GPU -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host 'No GPU: CPU path (NORNIR_DOCKER_GPU cleared)' }
}
return $ok
