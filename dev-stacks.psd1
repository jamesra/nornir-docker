# Developer stacks (not backend distribution), read by connectomes-deploy's stack.ps1 through
# STACK_EXTRA_REGISTRIES (default entry: NORNIR_REPO_ROOT_HOST:nornir-docker/dev-stacks.psd1).
# Same schema as connectomes-deploy/stacks.psd1; paths are relative to the nornir monorepo root.
@{
    Stacks = @{
        'nornir-dev' = @{
            Engine         = 'script'
            Description    = 'Programmer shell (cursor-dev compose service, bind-mounted monorepo)'
            Script         = 'nornir-docker/run-cursor-dev.ps1'
            ComposeProject = 'nornir-docker'
            ComposeFiles   = @('nornir-docker/compose.cursor-dev.yaml')
            DefaultService = 'cursor-dev'
            ActionArgs     = @{
                shell = @()
                up    = @()
            }
            Example        = $null
            Required       = @()
            Secrets        = @()
            Images         = @('nornir:dev-cursor-base')
            Ports          = @()
            Os             = @('windows', 'linux')
        }
        'nornir-cursor-worker' = @{
            Engine      = 'script'
            Description = 'Cursor self-hosted agent worker'
            Script      = 'nornir-docker/windows-docker-layout/start-nornir-cursor-worker.ps1'
            ActionArgs  = @{
                up    = @()
                shell = @()
            }
            Example     = 'nornir-docker/example.nornir-cursor-worker.run.env'
            Required    = @('CURSOR_API_KEY')
            Secrets     = @()
            Images      = @('nornir:cursor-worker')
            Ports       = @()
            Os          = @('windows', 'linux')
        }
    }
}
