# DEPRECATED: prefer docker compose -f nornir-docker/compose.yaml or start-sample.ps1.
& (Join-Path $PSScriptRoot '..\legacy-interactive-container.ps1') `
    -Volume 'test' `
    -TestInputPath 'D:/nornir-testdata' `
    -TestOutputPath 'D:/Temp'
