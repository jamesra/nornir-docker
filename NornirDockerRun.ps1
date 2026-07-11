# Shared docker run argument helpers for nornir-docker PowerShell scripts.
# Dot-source:  . (Join-Path $PSScriptRoot 'NornirDockerRun.ps1')

function Add-NornirDockerInteractiveTtyArgs {
    param([System.Collections.IList]$RunArgs)
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        [void]$RunArgs.Add('-t')
    }
}

function Add-NornirDockerGpuArgs {
    param(
        [System.Collections.IList]$RunArgs,
        [bool]$Gpu = $false
    )
    if ($Gpu -or $env:NORNIR_DOCKER_GPU -eq '1') {
        [void]$RunArgs.Add('--gpus')
        [void]$RunArgs.Add('all')
    }
}

function Add-NornirDockerExtraRunArgs {
    param([System.Collections.IList]$RunArgs)
    if ($env:NORNIR_DOCKER_EXTRA_ARGS) {
        $extra = $env:NORNIR_DOCKER_EXTRA_ARGS.Trim() -split '\s+'
        foreach ($x in $extra) {
            if ($x) { [void]$RunArgs.Add($x) }
        }
    }
}

function Add-NornirDockerMqttRunArgs {
    <#
    .SYNOPSIS
      Publish to the dashboard broker when NORNIR_MQTT_HOST is set.
    #>
    param([System.Collections.IList]$RunArgs)
    if (-not $env:NORNIR_MQTT_HOST) { return }
    $mqttPort = if ($env:NORNIR_MQTT_PORT) { $env:NORNIR_MQTT_PORT } else { '1883' }
    $mqttNetwork = if ($env:NORNIR_MQTT_NETWORK) { $env:NORNIR_MQTT_NETWORK } else { 'nornir-docker_nornir' }
    [void]$RunArgs.Add('-e')
    [void]$RunArgs.Add("NORNIR_MQTT_HOST=$($env:NORNIR_MQTT_HOST)")
    [void]$RunArgs.Add('-e')
    [void]$RunArgs.Add("NORNIR_MQTT_PORT=$mqttPort")
    [void]$RunArgs.Add('--network')
    [void]$RunArgs.Add($mqttNetwork)
}

function Add-NornirDockerPublishArgs {
    param(
        [System.Collections.IList]$RunArgs,
        [string]$Map
    )
    if ([string]::IsNullOrWhiteSpace($Map)) { return }
    foreach ($seg in $Map -split ';') {
        $t = $seg.Trim()
        if (-not $t) { continue }
        [void]$RunArgs.Add('-p')
        [void]$RunArgs.Add($t)
    }
}
