<#
.SYNOPSIS
  Run nornir-build inside the Nornir Docker image (cwd mounted at /workspace).

.DESCRIPTION
  Host entry point is nd-build so it does not shadow a locally installed nornir-build.
  Default image: nornir:dev (override with NORNIR_DOCKER_IMAGE).

.PARAMETER Gpu
  Passes --gpus all to docker run (use with nornir:cupy image).

.PARAMETER NornirBuildArgs
  All remaining arguments are forwarded to nornir-build inside the container.
#>
param(
    [switch]$Gpu,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$NornirBuildArgs
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NornirDockerRun.ps1')

$image = if ($env:NORNIR_DOCKER_IMAGE) { $env:NORNIR_DOCKER_IMAGE } else { 'nornir:dev' }
$work = (Get-Location).ProviderPath

$runArgs = [System.Collections.ArrayList]@('run', '--rm', '-i')
Add-NornirDockerInteractiveTtyArgs -RunArgs $runArgs
Add-NornirDockerGpuArgs -RunArgs $runArgs -Gpu:$Gpu
Add-NornirDockerUlimitArgs -RunArgs $runArgs
Add-NornirDockerExtraRunArgs -RunArgs $runArgs
Add-NornirDockerMqttRunArgs -RunArgs $runArgs
[void]$runArgs.Add('-v')
[void]$runArgs.Add("${work}:/workspace")
[void]$runArgs.Add('-w')
[void]$runArgs.Add('/workspace')
[void]$runArgs.Add($image)
[void]$runArgs.Add('nornir-build')
foreach ($a in $NornirBuildArgs) {
    [void]$runArgs.Add($a)
}

& docker @runArgs
exit $LASTEXITCODE
