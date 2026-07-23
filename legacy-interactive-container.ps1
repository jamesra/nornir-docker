<#
.SYNOPSIS
  DEPRECATED one-off helper to start a legacy nornir container and open a shell.

.DESCRIPTION
  Prefer docker compose -f nornir-docker/compose.yaml or start-sample.ps1.
  See https://nornir.github.io/docker/index.html
#>
param(
    [string]$Volume = 'test',
    [string]$TestInputPath = 'C:/src/git/nornir-testdata',
    [string]$TestOutputPath = 'C:/Temp',
    [switch]$Gpu
)

$ErrorActionPreference = 'Stop'
$containerName = "nornir-$Volume"
$output = [string](docker ps --filter "name=$containerName")
Write-Host $output
if (-not $output.Contains($containerName)) {
    Write-Host "$containerName container does not exist"
    $runArgs = @(
        'run', '--name', $containerName, '-it', '-d', '--tmpfs', '/tmp',
        '--cap-add', 'SYS_ADMIN', '--cap-add', 'DAC_READ_SEARCH',
        '-v', '//storage2.connectomes.utah.edu/Data:/mnt/storage2',
        '-v', "${TestInputPath}:/mnt/testinput",
        '-v', "${TestOutputPath}:/mnt/testoutput",
        '-e', 'TESTINPUTPATH=/mnt/testinput',
        '-e', 'TESTOUTPUTPATH=/mnt/testoutput'
    )
    if ($Gpu) {
        $runArgs += @('--gpus', 'all', '--net', '--net-alias', $containerName)
    }
    $runArgs += 'nornir'
    & docker @runArgs
}

wt docker exec -it $containerName bash
