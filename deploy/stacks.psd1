# Stack registry for nornir-docker stacks (read by deploy/stack.ps1).
# Viking stacks live in <VIKING_REPO_ROOT_HOST>/deploy/stacks.psd1 with the same schema.
#
# Engine:
#   compose - stack.ps1 runs docker compose -p <key> --env-file ... -f <ComposeFiles> <action>
#   script  - stack.ps1 calls an existing launcher (Script) with ActionArgs per action; observation
#             actions (logs/ps/exec/shell/down) use Container (docker run stacks) or
#             ComposeProject+ComposeFiles (compose-managed by the launcher).
#   iis     - Windows IIS deployment script (Viking only).
# Paths are relative to the owning repo root, forward slashes.
@{
    Stacks = @{
        'nornir-build' = @{
            Engine      = 'script'
            Description = 'Production build appliance: nornir:cupy (GPU) or nornir:prod, path-B CIFS, per-session Work folder'
            Script      = 'nornir-docker/start-nornir-build.ps1'
            Container   = 'nornir-build'
            ActionArgs  = @{
                up    = @('-Detach', '-KeepContainer', '-ContainerName', 'nornir-build')
                shell = @()
            }
            Example     = 'nornir-docker/deploy/examples/example.nornir-build.run.env'
            Required    = @()
            Secrets     = @()
            Images      = @('nornir:cupy', 'nornir:prod')
            Ports       = @()
            Os          = @('linux', 'windows')
        }
        'nornir-dashboard' = @{
            Engine         = 'script'
            Description    = 'Mosquitto broker + nornir build dashboard (http://127.0.0.1:8087)'
            Script         = 'nornir-docker/start-dashboard.ps1'
            ComposeProject = 'nornir-dashboard'
            ComposeFiles   = @('nornir-docker/compose.dashboard.yaml')
            DefaultService = 'nornir-dashboard'
            ActionArgs     = @{
                up      = @()
                restart = @()
                rebuild = @('-Rebuild')
                down    = @('-Down')
            }
            Example        = 'nornir-docker/deploy/examples/example.nornir-dashboard.run.env'
            Required       = @()
            GeneratedSecrets = @('NORNIR_DASHBOARD_TOKEN')
            Secrets        = @()
            HealthUrl      = 'http://127.0.0.1:8087/'
            Images         = @('nornir-dashboard:latest', 'eclipse-mosquitto:2')
            Ports          = @(1883, 8087)
            Os             = @('linux', 'windows')
        }
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
