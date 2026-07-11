# DEPRECATED: use nornir-docker/prod/Dockerfile with INSTALL_CUPY=1 (image nornir:cupy) or start-sample.ps1.
& (Join-Path $PSScriptRoot '..\legacy-interactive-container.ps1') -Volume 'RC3' -Gpu
