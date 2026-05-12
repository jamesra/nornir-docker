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

$image = if ($env:NORNIR_DOCKER_IMAGE) { $env:NORNIR_DOCKER_IMAGE } else { 'nornir:dev' }
$work = (Get-Location).ProviderPath

$runArgs = [System.Collections.ArrayList]@('run', '--rm', '-i')
if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    [void]$runArgs.Add('-t')
}
if ($Gpu -or $env:NORNIR_DOCKER_GPU -eq '1') {
    [void]$runArgs.Add('--gpus')
    [void]$runArgs.Add('all')
}
if ($env:NORNIR_DOCKER_EXTRA_ARGS) {
    $extra = $env:NORNIR_DOCKER_EXTRA_ARGS.Trim() -split '\s+'
    foreach ($x in $extra) {
        if ($x) { [void]$runArgs.Add($x) }
    }
}
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
