# Remote deploy targets for `stack.ps1 ... -Target <name>`.
# Copy to <root>/Run/_host/targets.psd1 on the machine you deploy FROM (usually the dev box).
# Each target needs: an SSH login that works without a password prompt (authorized_keys),
# pwsh 7 on the target, and the target's own layout (Initialize-DockerHost.ps1 run there).
@{
    Targets = @{
        compute = @{
            Ssh        = 'deploy@compute.connectomes.pitt.edu'   # REQUIRED user@host, or a Host alias from ~/.ssh/config
            SshOptions = @()                                      # OPTIONAL e.g. @('-p', '2222') or @('-J', 'jump.example.edu')
            Os         = 'linux'                                  # linux | windows
            Root       = '/srv/docker'                            # that host's NORNIR_DOCKER_USER_ROOT
            Stacks     = @('nornir-build', 'nornir-dashboard', 'viking-segmentation')
            Repos      = @{                                       # checkouts that -Sync fast-forwards
                NORNIR_REPO_ROOT_HOST = '/srv/src/nornir'
                VIKING_REPO_ROOT_HOST = '/srv/src/Viking'
            }
            Tunnels    = @(                                       # stack.ps1 tunnel -Target compute
                '8087:127.0.0.1:8087'                             # nornir dashboard UI
                '5678:127.0.0.1:5678'                             # debugpy (NORNIR_DEBUGPY=1)
            )
            CertPush   = $true                                    # `stack.ps1 certs push` (run on web) copies the cert here
        }
        web = @{
            Ssh        = 'deploy@web.connectomes.pitt.edu'
            SshOptions = @()
            Os         = 'linux'
            Root       = '/srv/docker'
            Stacks     = @('viking-proxy', 'viking-certs', 'viking-identity', 'viking-annotation', 'viking-corrections')
            Repos      = @{
                NORNIR_REPO_ROOT_HOST = '/srv/src/nornir'
                VIKING_REPO_ROOT_HOST = '/srv/src/Viking'
            }
            Tunnels    = @(
                '4024:127.0.0.1:4024'                             # Identity .NET remote debugger
                '1433:sql-host.example.edu:1433'                  # SQL Server as seen from web (edit host)
            )
            CertPush   = $false
        }
        iis = @{
            Ssh        = 'administrator@iis-host.example.edu'     # Windows OpenSSH; its DefaultShell must be pwsh
            SshOptions = @()
            Os         = 'windows'
            Root       = 'D:\Docker'
            Stacks     = @('viking-iis')
            Repos      = @{
                NORNIR_REPO_ROOT_HOST = 'D:\src\git\nornir'
                VIKING_REPO_ROOT_HOST = 'D:\src\git\Viking'
            }
            Tunnels    = @()
            CertPush   = $true
        }
    }
}
