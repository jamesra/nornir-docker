#Requires -Version 7.2
<#
.SYNOPSIS
  One command for every Nornir/Viking container stack, on this machine or a remote target.

.DESCRIPTION
  Solves "every service starts differently, and remote deploys are manual": stack.ps1 reads
  the stack registries (nornir-docker/deploy/stacks.psd1 and <Viking>/deploy/stacks.psd1),
  merges the machine-local env files from the host layout, and runs the right engine:

    compose stacks  docker compose -p <stack> --env-file host.env ... --env-file <stack>.run.env -f ...
    script stacks   the existing launcher (start-nornir-build.ps1, start-dashboard.ps1, ...)
    iis stacks      the Viking IIS deploy wrapper (Windows target)

  With -Target <name> (from Run/_host/targets.psd1) the same arguments are run on that host over
  SSH (pwsh <root>/stack.ps1 ...). -Sync first fast-forwards the target's git checkouts to what
  you pushed. Remote and local commands are therefore identical apart from -Target.

  Host layout root: NORNIR_DOCKER_USER_ROOT (default D:\Docker on Windows, /srv/docker on Linux).
  Create it with Initialize-DockerHost.ps1. Full docs: https://nornir.github.io/deployment/

.PARAMETER Stack
  Stack key (see `stack.ps1 list`), `all` (stacks in NORNIR_DOCKER_HOST_STACKS of the host), or a
  tool verb: list, doctor, certs, tunnel, prune, secrets, targets.

.PARAMETER Action
  For stacks: up, down, restart, rebuild, build, pull, push, logs, ps, status, exec, shell, config.
  For `certs`: status, manual, letsencrypt, acme-eab, push, reload, install-iis.
  For `secrets`: new.

.PARAMETER Target
  Remote target key from Run/_host/targets.psd1, or `all` for every target. Omit for this machine.

.PARAMETER Sync
  With -Target: verify local branches are pushed, then `git pull --ff-only` + submodule update on the target.

.PARAMETER Images
  With -Target: build (default; images are built on the target), ghcr (pull from GHCR on the
  target), or load (docker save here | ssh target docker load).

.PARAMETER Profile
  Extra compose profiles (e.g. segmentation model variants).

.PARAMETER Service
  Compose service for exec/shell/logs (default: the stack's DefaultService or first service).

.PARAMETER Follow
  logs -f.

.PARAMETER Tail
  Lines for logs (default 200).

.PARAMETER Force
  prune: actually delete. certs manual: overwrite even if the existing cert is newer.

.PARAMETER Days
  prune: age threshold in days for Work/ session folders (default 14).

.PARAMETER From
  certs push: fetch the certificate from this target first (lets you run the push from the dev box:
  `stack.ps1 certs push -From web`, which pushes to every target with CertPush = $true).

.PARAMETER Root
  Override the host layout root.

.PARAMETER Rest
  Remaining arguments: command for exec, files for certs manual (or use the named options), etc.

.EXAMPLE
  stack.ps1 list

.EXAMPLE
  stack.ps1 viking-identity up
  stack.ps1 viking-identity logs -Follow

.EXAMPLE
  stack.ps1 viking-segmentation rebuild -Target compute -Sync

.EXAMPLE
  stack.ps1 all up -Target web

.EXAMPLE
  stack.ps1 doctor -Target all

.EXAMPLE
  stack.ps1 certs manual -Cert .\connectomes.crt -Key .\connectomes.key -Chain .\incommon-chain.pem

.EXAMPLE
  stack.ps1 tunnel -Target compute
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)][string]$Stack = 'list',
    [Parameter(Position = 1)][string]$Action = '',
    [string]$Target = '',
    [switch]$Sync,
    [ValidateSet('build', 'ghcr', 'load')][string]$Images = 'build',
    [string[]]$Profile = @(),
    [string]$Service = '',
    [switch]$Follow,
    [int]$Tail = 200,
    [switch]$Force,
    [int]$Days = 14,
    [string]$Root = '',
    [string]$Cert = '',
    [string]$Key = '',
    [string]$Chain = '',
    [string]$PfxPassword = '',
    [string]$From = '',
    [Parameter(Position = 2, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StackLib.ps1')
. (Join-Path $PSScriptRoot 'DockerHostCerts.ps1')

$script:Layout = Get-DockerHostLayout -Root $Root
$script:HostEnv = Read-HostEnv -Root $Root
$script:Registry = Import-StackRegistry -HostEnv $script:HostEnv

$ToolVerbs = @('list', 'doctor', 'certs', 'tunnel', 'prune', 'secrets', 'targets')
$StackActions = @('up', 'down', 'restart', 'rebuild', 'build', 'pull', 'push', 'logs', 'ps', 'status', 'exec', 'shell', 'config', 'deploy')

#region remote

function Get-ForwardedArgs {
    <# Rebuild this invocation's arguments without -Target/-Sync/-Images (for the remote side). #>
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add($Stack)
    if ($Action) { $out.Add($Action) }
    $named = [ordered]@{
        Profile = $Profile; Service = $Service; Tail = $Tail; Days = $Days
        Cert = $Cert; Key = $Key; Chain = $Chain; PfxPassword = $PfxPassword
    }
    foreach ($k in $named.Keys) {
        if (-not $script:Bound.ContainsKey($k)) { continue }
        $v = $named[$k]
        if ($v -is [array]) { if ($v.Count) { $out.Add("-$k"); $out.Add(($v -join ',')) } }
        elseif ("$v" -ne '') { $out.Add("-$k"); $out.Add("$v") }
    }
    if ($Follow) { $out.Add('-Follow') }
    if ($Force) { $out.Add('-Force') }
    if ($Rest.Count) { $out.Add('--'); foreach ($r in $Rest) { $out.Add($r) } }
    return , $out.ToArray()
}

function Sync-TargetRepos {
    param([Parameter(Mandatory)][hashtable]$T, [string]$Name)
    foreach ($var in @($T.Repos.Keys)) {
        $remote = $T.Repos[$var]
        $local = Get-RepoRootFromEnv -VarName $var -HostEnv $script:HostEnv
        if ($local -and (Test-Path -LiteralPath $local)) {
            $branch = (& git -C $local rev-parse --abbrev-ref HEAD).Trim()
            $head = (& git -C $local rev-parse HEAD).Trim()
            $upstreamHead = (& git -C $local rev-parse '@{u}' 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $upstreamHead -or $upstreamHead.Trim() -ne $head) {
                throw "$var ($local) branch '$branch' is not pushed (HEAD != upstream). Push before -Sync."
            }
            $dirty = & git -C $local status --porcelain --ignore-submodules=none
            if ($dirty) { Write-Warning "$var ($local) has uncommitted changes; they will NOT reach $Name." }
            Write-Host "[$Name] $var -> $remote (local $branch @ $($head.Substring(0, 9)))"
        }
        $q = ConvertTo-RemoteArg $remote
        $cmd = "git -C $q pull --ff-only && git -C $q submodule update --init --recursive && git -C $q log -1 --oneline"
        if ($T.Os -eq 'windows') {
            $cmd = "git -C $q pull --ff-only; if (`$LASTEXITCODE -eq 0) { git -C $q submodule update --init --recursive; git -C $q log -1 --oneline }"
        }
        Invoke-Ssh -Target $T -Command $cmd; $code = $script:Rc
        if ($code -ne 0) { throw "[$Name] git sync of $remote failed (exit $code)" }
    }
}

function Send-ImagesToTarget {
    param([Parameter(Mandatory)][hashtable]$T, [string]$Name, [string[]]$StackKeys)
    $imgs = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $StackKeys) {
        $e = $script:Registry[$k]
        if (-not $e) { continue }
        if ($e.Engine -eq 'compose') {
            $envMap = Get-StackEnvironment -Entry $e -Root $Root
            $base = Get-StackComposeBaseArgs -Entry $e -ExtraProfiles $Profile -Root $Root
            $list = Invoke-WithProcessEnv -Env $envMap -Script { & docker @base config --images }
            foreach ($i in $list) { if ($i) { $imgs.Add($i.Trim()) } }
        }
        foreach ($i in @($e.Images)) { if ($i) { $imgs.Add($i) } }
    }
    foreach ($img in ($imgs | Select-Object -Unique)) {
        & docker image inspect $img 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Image $img not present locally; skipping"; continue }
        Write-Host "[$Name] docker save $img | ssh $($T.Ssh) docker load"
        & docker save $img | & ssh @($T.SshOptions | Where-Object { $_ }) $T.Ssh 'docker load'
        if ($LASTEXITCODE -ne 0) { throw "Transfer of $img to $Name failed" }
    }
}

function Invoke-OnTargets {
    $targets = Import-DockerTargets -Root $Root
    if (-not $targets.Count) {
        throw "No targets defined. Copy examples/example.targets.psd1 to $($script:Layout.Targets)."
    }
    $names = if ($Target -eq 'all') { @($targets.Keys | Sort-Object) } else { @($Target -split ',') }
    $worst = 0
    foreach ($n in $names) {
        $t = $targets[$n]
        if (-not $t) { throw "Unknown target '$n'. Known: $(($targets.Keys | Sort-Object) -join ', ')" }
        Write-Host "==== $n ($($t.Ssh)) ====" -ForegroundColor Cyan
        if ($Sync) { Sync-TargetRepos -T $t -Name $n }
        $stackKeys = if ($Stack -eq 'all') { @($t.Stacks) } elseif ($ToolVerbs -contains $Stack) { @() } else { @($Stack) }
        if ($Images -eq 'load' -and $stackKeys.Count) { Send-ImagesToTarget -T $t -Name $n -StackKeys $stackKeys }
        $fwd = Get-ForwardedArgs
        if ($Images -eq 'ghcr' -and $stackKeys.Count -and @('up', 'rebuild', 'restart') -contains $Action) {
            $pullArgs = @($fwd)
            $pullArgs[1] = 'pull'
            Invoke-Ssh -Target $t -Command (Get-RemotePwshCommand -Target $t -StackArgs $pullArgs)
        }
        if ($Stack -eq 'tunnel') { continue }
        $tty = @('shell', 'exec') -contains $Action -or ($Action -eq 'logs' -and $Follow)
        Invoke-Ssh -Target $t -Command (Get-RemotePwshCommand -Target $t -StackArgs $fwd) -Tty:$tty; $code = $script:Rc
        if ($code -ne 0) { $worst = $code; Write-Warning "[$n] exit $code" }
    }
    $script:Rc = $worst
}

function Start-Tunnel {
    $targets = Import-DockerTargets -Root $Root
    $t = $targets[$Target]
    if (-not $t) { throw "tunnel needs -Target <name> from $($script:Layout.Targets)" }
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add('-N')
    foreach ($o in @($t.SshOptions)) { if ($o) { $a.Add($o) } }
    foreach ($f in @($t.Tunnels)) {
        if (-not $f) { continue }
        $a.Add('-L'); $a.Add($f)
        $parts = $f -split ':'
        Write-Host "  localhost:$($parts[0])  ->  $($t.Ssh) $($parts[1..($parts.Count-1)] -join ':')"
    }
    $a.Add($t.Ssh)
    Write-Host "Tunnel open; Ctrl+C to close." -ForegroundColor Cyan
    & ssh @a
    $script:Rc = $LASTEXITCODE
}

#endregion

#region local stacks

function Get-HostStackKeys {
    $raw = $script:HostEnv['NORNIR_DOCKER_HOST_STACKS']
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "NORNIR_DOCKER_HOST_STACKS is empty in $($script:Layout.HostEnv); list the stacks this host runs (comma separated)."
    }
    return @($raw -split '[,\s]+' | Where-Object { $_ })
}

function Get-Entry {
    param([string]$Key)
    $e = $script:Registry[$Key]
    if (-not $e) {
        throw "Unknown stack '$Key'. Known: $(($script:Registry.Keys) -join ', '). (Viking stacks need VIKING_REPO_ROOT_HOST in host.env.)"
    }
    return $e
}

function Assert-StackReady {
    param([hashtable]$Entry, [hashtable]$EnvMap)
    $problems = Test-StackRequired -Entry $Entry -Env $EnvMap -Root $Root
    if ($problems.Count) {
        foreach ($p in $problems) { Write-Host "  [$($Entry.Key)] $p" -ForegroundColor Red }
        throw "Stack $($Entry.Key) is not configured. Fix the items above (stack.ps1 doctor lists everything)."
    }
}

function Initialize-StackDirs {
    param([hashtable]$Entry)
    $d = Get-StackDirs -Stack $Entry.Key -Root $Root
    foreach ($p in @($d.Data, $d.Logs, $d.Secrets, $script:Layout.Certs)) {
        if (-not (Test-Path -LiteralPath $p)) { $null = New-Item -ItemType Directory -Force -Path $p }
    }
}

function Test-StackHealth {
    param([hashtable]$Entry, [hashtable]$EnvMap)
    if (-not $Entry.HealthUrl) { return $true }
    $url = Expand-StackTemplate -Text $Entry.HealthUrl -Env $EnvMap
    try {
        $r = Invoke-WebRequest -Uri $url -SkipCertificateCheck -TimeoutSec 8 -MaximumRedirection 0 -SkipHttpErrorCheck
        $ok = $r.StatusCode -lt 500
        Write-Host ("  health {0} -> {1}" -f $url, $r.StatusCode) -ForegroundColor ($(if ($ok) { 'Green' } else { 'Red' }))
        return $ok
    }
    catch {
        Write-Host "  health $url -> $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Invoke-ComposeStack {
    param([hashtable]$Entry, [string]$Act)
    $envMap = Get-StackEnvironment -Entry $Entry -Root $Root
    if (@('up', 'rebuild', 'restart', 'build', 'config') -contains $Act) { Assert-StackReady -Entry $Entry -EnvMap $envMap }
    Initialize-StackDirs -Entry $Entry
    $base = Get-StackComposeBaseArgs -Entry $Entry -ExtraProfiles $Profile -Root $Root
    $svc = if ($Service) { $Service } elseif ($Entry.DefaultService) { $Entry.DefaultService } else { '' }
    $runs = @(switch ($Act) {
        'up' { , @('up', '-d', '--remove-orphans') }
        'down' { , @('down') }
        'restart' { , @('up', '-d', '--force-recreate', '--remove-orphans') }
        'rebuild' { @(@('build', '--pull'), @('up', '-d', '--force-recreate', '--remove-orphans')) }
        'build' { , @('build') }
        'pull' { , @('pull', '--ignore-buildable') }
        'logs' { , (@('logs', '--tail', "$Tail") + $(if ($Follow) { @('-f') } else { @() }) + $(if ($Service) { @($Service) } else { @() })) }
        'ps' { , @('ps') }
        'status' { , @('ps') }
        'config' { , @('config', '--quiet') }
        'exec' {
            if (-not $Rest.Count) { throw 'exec needs a command: stack.ps1 <stack> exec [-Service s] -- <cmd...>' }
            , (@('exec', $(if ($svc) { $svc } else { throw 'exec needs -Service (no DefaultService in registry)' })) + $Rest)
        }
        'shell' {
            if (-not $svc) { throw 'shell needs -Service (no DefaultService in registry)' }
            , @('exec', $svc, 'sh', '-c', 'command -v bash >/dev/null && exec bash || exec sh')
        }
        default { throw "Action '$Act' is not supported for compose stack $($Entry.Key)" }
    })
    $code = 0
    Push-Location $Entry.RepoRoot
    try {
        Invoke-WithProcessEnv -Env $envMap -Script {
            foreach ($r in $runs) {
                Invoke-Docker -Arguments (@($base) + @($r)); $script:lastCode = $script:Rc
                if ($script:lastCode -ne 0) { break }
            }
        }
        $code = $script:lastCode
    }
    finally { Pop-Location }
    if ($code -eq 0 -and @('up', 'restart', 'rebuild', 'status') -contains $Act -and $Entry.HealthUrl) {
        if ($Act -ne 'status') { Start-Sleep -Seconds 3 }
        $null = Test-StackHealth -Entry $Entry -EnvMap $envMap
    }
    $script:Rc = $code
}

function Invoke-PwshScript {
    param([string]$Path, [string[]]$Arguments, [hashtable]$EnvMap)
    $pwsh = (Get-Process -Id $PID).Path
    Write-Host ("pwsh -File $Path " + ($Arguments -join ' ')) -ForegroundColor DarkGray
    Invoke-WithProcessEnv -Env $EnvMap -Script { & $pwsh -NoLogo -NoProfile -File $Path @Arguments; $script:lastCode = $LASTEXITCODE }
    $script:Rc = $script:lastCode
}

function Test-ContainerState {
    param([string]$Name)
    $s = & docker inspect -f '{{.State.Status}}' $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return 'absent' }
    return "$s".Trim()
}

function Invoke-ScriptStack {
    param([hashtable]$Entry, [string]$Act)
    $envMap = Get-StackEnvironment -Entry $Entry -Root $Root
    Initialize-StackDirs -Entry $Entry
    $scriptPath = if ($Entry.Script) { Join-DockerHostPath $Entry.RepoRoot $Entry.Script } else { $null }
    $hasArgs = $Entry.ActionArgs -and $Entry.ActionArgs.ContainsKey($Act)
    $name = $Entry.Container

    if ($name -and $Act -eq 'up') {
        $state = Test-ContainerState $name
        if ($state -eq 'running') { Write-Host "$name is already running (use restart or shell)."; $script:Rc = 0; return }
        if ($state -ne 'absent') { Invoke-Docker -Arguments @('start', $name); return }
    }
    if ($name -and $Act -eq 'shell' -and (Test-ContainerState $name) -eq 'running') {
        Invoke-Docker -Arguments @('exec', '-it', $name, 'bash'); return
    }
    if ($name -and $Act -eq 'restart') {
        if ((Test-ContainerState $name) -eq 'absent') { $Act = 'up' } else { Invoke-Docker -Arguments @('restart', $name); return }
        $hasArgs = $Entry.ActionArgs.ContainsKey($Act)
    }
    if ($name -and $Act -eq 'rebuild') {
        if ((Test-ContainerState $name) -ne 'absent') { Invoke-Docker -Arguments @('rm', '-f', $name) }
        $Act = 'up'; $hasArgs = $true
    }
    if ($hasArgs) {
        if (@('up', 'restart', 'rebuild') -contains $Act) { Assert-StackReady -Entry $Entry -EnvMap $envMap }
        Invoke-PwshScript -Path $scriptPath -Arguments (@($Entry.ActionArgs[$Act]) + $Rest) -EnvMap $envMap
        $code = $script:Rc
        if ($code -eq 0 -and $Entry.HealthUrl -and $Act -ne 'down') { $null = Test-StackHealth -Entry $Entry -EnvMap $envMap }
        $script:Rc = $code
        return
    }
    if ($name) {
        switch ($Act) {
            'down' { Invoke-Docker -Arguments @('rm', '-f', $name); return }
            'logs' { Invoke-Docker -Arguments (@('logs', '--tail', "$Tail") + $(if ($Follow) { @('-f') } else { @() }) + @($name)); return }
            { $_ -in 'ps', 'status' } { Invoke-Docker -Arguments @('ps', '-a', '--filter', "name=^/$name$"); return }
            'exec' { Invoke-Docker -Arguments (@('exec', '-it', $name) + $Rest); return }
            'pull' { Invoke-PwshScript -Path (Join-DockerHostPath $Entry.RepoRoot 'nornir-docker/docker-pull.ps1') -Arguments @() -EnvMap $envMap; return }
            'push' { Invoke-PwshScript -Path (Join-DockerHostPath $Entry.RepoRoot 'nornir-docker/docker-push.ps1') -Arguments @() -EnvMap $envMap; return }
        }
    }
    if ($Entry.ComposeProject) {
        $proxy = @{} + $Entry
        $proxy.Engine = 'compose'
        Invoke-ComposeStack -Entry $proxy -Act $Act; return
    }
    throw "Action '$Act' is not supported for script stack $($Entry.Key)"
}

function Invoke-IisStack {
    param([hashtable]$Entry, [string]$Act)
    if (-not (Test-NornirWindowsHost)) { throw "$($Entry.Key) runs on a Windows IIS host; use -Target iis." }
    $envMap = Get-StackEnvironment -Entry $Entry -Root $Root
    if (@('deploy', 'up', 'rebuild') -notcontains $Act) { throw "IIS stack supports: deploy (alias up/rebuild)" }
    Assert-StackReady -Entry $Entry -EnvMap $envMap
    $deploy = Join-DockerHostPath $Entry.RepoRoot $Entry.Deploy
    Invoke-PwshScript -Path $deploy -Arguments $Rest -EnvMap $envMap; return
}

function Invoke-Stack {
    param([string]$Key, [string]$Act)
    $e = Get-Entry $Key
    Write-Host "---- $Key : $Act ----" -ForegroundColor Cyan
    switch ($e.Engine) {
        'compose' { Invoke-ComposeStack -Entry $e -Act $Act; return }
        'script' { Invoke-ScriptStack -Entry $e -Act $Act; return }
        'iis' { Invoke-IisStack -Entry $e -Act $Act; return }
        default { throw "Stack $Key has unknown Engine '$($e.Engine)'" }
    }
}

#endregion

#region tools

function Show-List {
    $hostStacks = @(($script:HostEnv['NORNIR_DOCKER_HOST_STACKS'] -split '[,\s]+') | Where-Object { $_ })
    $script:Registry.Values | ForEach-Object {
        [pscustomobject]@{
            Stack       = $_.Key
            Engine      = $_.Engine
            ThisHost    = if ($hostStacks -contains $_.Key) { 'yes' } else { '' }
            Description = $_.Description
        }
    } | Format-Table -AutoSize | Out-Host
    Write-Host "Layout root: $($script:Layout.Root)    host.env: $(if (Test-Path $script:Layout.HostEnv) { 'present' } else { 'MISSING' })"
    $script:Rc = 0; return
}

function Show-Targets {
    $t = Import-DockerTargets -Root $Root
    if (-not $t.Count) { Write-Host "No targets file at $($script:Layout.Targets)"; $script:Rc = 0; return }
    $t.GetEnumerator() | Sort-Object Key | ForEach-Object {
        [pscustomobject]@{ Target = $_.Key; Ssh = $_.Value.Ssh; Os = $_.Value.Os; Root = $_.Value.Root; Stacks = (@($_.Value.Stacks) -join ', ') }
    } | Format-Table -AutoSize | Out-Host
    $script:Rc = 0; return
}

function Write-Check {
    param([string]$Status, [string]$Message)
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$Status]
    Write-Host ("[{0,-4}] {1}" -f $Status, $Message) -ForegroundColor $color
    if ($Status -eq 'FAIL') { $script:DoctorFailures++ }
}

function Invoke-Doctor {
    $script:DoctorFailures = 0
    Write-Check INFO "host: $([System.Net.Dns]::GetHostName())  os: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)  pwsh: $($PSVersionTable.PSVersion)"
    Write-Check INFO "layout root: $($script:Layout.Root)"
    foreach ($d in @('Run', 'Data', 'Certs', 'Work', 'Logs')) {
        $p = $script:Layout[$d]
        if (Test-Path -LiteralPath $p) { Write-Check OK "$d/ exists" } else { Write-Check FAIL "$p missing (run Initialize-DockerHost.ps1)" }
    }
    if (Test-Path -LiteralPath $script:Layout.HostEnv) { Write-Check OK "host.env present" } else { Write-Check FAIL "$($script:Layout.HostEnv) missing (copy examples/example.host.env)" }

    $dv = $null
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Check FAIL 'docker CLI not installed (Ubuntu: bootstrap-ubuntu.sh; Windows: Docker Desktop)'
    }
    else {
        $dv = & docker version --format '{{.Server.Version}}' 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Check OK "docker engine $dv" } else { $dv = $null; Write-Check FAIL 'docker engine not reachable (is the service running / are you in the docker group?)' }
        $cv = & docker compose version --short 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Check OK "docker compose $cv" } else { Write-Check FAIL 'docker compose v2 plugin missing' }
    }

    $stacks = @()
    try { $stacks = Get-HostStackKeys } catch { Write-Check FAIL $_.Exception.Message }
    $needsGpu = $false
    $needsTls = $false
    foreach ($k in $stacks) {
        $e = $script:Registry[$k]
        if (-not $e) { Write-Check FAIL "stack '$k' in NORNIR_DOCKER_HOST_STACKS is not in any registry"; continue }
        if ($e.Gpu -or $k -in 'nornir-build', 'viking-segmentation') { $needsGpu = $true }
        if ($k -like 'viking-*') { $needsTls = $true }
        $envMap = Get-StackEnvironment -Entry $e -Root $Root
        $problems = Test-StackRequired -Entry $e -Env $envMap -Root $Root
        if ($problems.Count) { foreach ($p in $problems) { Write-Check FAIL "[$k] $p" } } else { Write-Check OK "[$k] configuration complete" }
        if ($e.Engine -eq 'compose' -and $dv) {
            $base = Get-StackComposeBaseArgs -Entry $e -ExtraProfiles $Profile -Root $Root
            Push-Location $e.RepoRoot
            try {
                $out = Invoke-WithProcessEnv -Env $envMap -Script { & docker @base config --quiet 2>&1 }
                if ($LASTEXITCODE -eq 0) { Write-Check OK "[$k] compose config valid" } else { Write-Check FAIL "[$k] compose config: $($out | Select-Object -First 3)" }
            }
            finally { Pop-Location }
        }
        if ($e.Script) {
            $sp = Join-DockerHostPath $e.RepoRoot $e.Script
            if (Test-Path -LiteralPath $sp) { Write-Check OK "[$k] launcher $($e.Script)" } else { Write-Check FAIL "[$k] launcher missing: $sp" }
        }
    }

    if ($needsGpu) {
        $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($smi) {
            $g = & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Check OK "GPU: $($g -join '; ')" } else { Write-Check WARN 'nvidia-smi present but failed' }
        }
        else { Write-Check WARN 'nvidia-smi not on PATH (GPU stacks fall back to CPU or fail)' }
        if ($dv) {
            $rt = (& docker info --format '{{json .Runtimes}}' 2>$null) | Out-String
            if ($rt -match 'nvidia' -or (Test-NornirWindowsHost)) { Write-Check OK 'docker GPU runtime available' }
            else { Write-Check WARN 'nvidia container runtime not registered with docker (install nvidia-container-toolkit; nvidia-ctk runtime configure --runtime=docker)' }
        }
    }

    if ($needsTls) {
        $envMap = Get-StackEnvironment -Entry (Get-Entry $stacks[0]) -Root $Root
        $names = @((Get-VikingHostnameDefaults -Env $envMap).Values)
        foreach ($c in (Test-DockerHostCertificate -CertsDir $script:Layout.Certs -CertName $envMap['TLS_CERT_NAME'] -Hostnames $names)) {
            Write-Check $c.Status $c.Message
        }
        foreach ($n in $names) {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($n) | ForEach-Object { $_.IPAddressToString }
                Write-Check OK "DNS $n -> $($ips -join ', ')"
            }
            catch { Write-Check WARN "DNS $n does not resolve yet" }
        }
    }

    if (-not (Test-NornirWindowsHost)) {
        $ufw = Get-Command ufw -ErrorAction SilentlyContinue
        if ($ufw) {
            Write-Check INFO 'ufw present: note Docker-published ports bypass ufw; bind internal ports to 127.0.0.1 or filter in the DOCKER-USER chain.'
        }
        $sshd = if (Get-Command systemctl -ErrorAction SilentlyContinue) { & systemctl is-active ssh 2>$null } else { '' }
        if ("$sshd".Trim() -eq 'active') { Write-Check OK 'sshd active' } else { Write-Check WARN 'sshd not active (remote deploys need it)' }
    }

    $targets = Import-DockerTargets -Root $Root
    if ($targets.Count) { Write-Check INFO "targets: $(($targets.Keys | Sort-Object) -join ', ')" }

    if ($script:DoctorFailures) { Write-Host "$($script:DoctorFailures) problem(s)." -ForegroundColor Red; $script:Rc = 1; return }
    Write-Host 'All checks passed.' -ForegroundColor Green
    $script:Rc = 0; return
}

function Invoke-Prune {
    $work = $script:Layout.Work
    $legacy = Join-DockerHostPath $script:Layout.Root 'mounted-configs'
    $inUse = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ids = & docker ps -q 2>$null
    foreach ($id in $ids) {
        $src = & docker inspect -f '{{range .Mounts}}{{.Source}}|{{end}}' $id 2>$null
        foreach ($s in ("$src" -split '\|')) { if ($s) { [void]$inUse.Add(($s -replace '\\', '/').TrimEnd('/')) } }
    }
    $cutoff = (Get-Date).AddDays(-$Days)
    $cands = foreach ($parent in @($work, $legacy)) {
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        Get-ChildItem -LiteralPath $parent -Directory | Where-Object { $_.Name -like 'nornir-build-*' -and $_.LastWriteTime -lt $cutoff }
    }
    $n = 0
    foreach ($d in $cands) {
        $norm = ($d.FullName -replace '\\', '/').TrimEnd('/')
        if ($inUse.Contains($norm)) { Write-Host "  keep (mounted): $($d.FullName)"; continue }
        if ($Force) { Remove-Item -LiteralPath $d.FullName -Recurse -Force; Write-Host "  removed $($d.FullName)" }
        else { Write-Host "  would remove $($d.FullName)  ($($d.LastWriteTime.ToString('yyyy-MM-dd')))" }
        $n++
    }
    if (-not $Force -and $n) { Write-Host "$n folder(s) older than $Days days. Re-run with -Force to delete." }
    if (-not $n) { Write-Host "Nothing older than $Days days." }
    $script:Rc = 0; return
}

function New-StackSecrets {
    $key = if ($Rest.Count) { $Rest[0] } else { throw 'secrets new <stack>' }
    $e = Get-Entry $key
    $envMap = Get-StackEnvironment -Entry $e -Root $Root
    $dirs = Get-StackDirs -Stack $key -Root $Root
    if (-not (Test-Path -LiteralPath $dirs.Secrets)) { $null = New-Item -ItemType Directory -Force -Path $dirs.Secrets }
    # Candidates: Required/GeneratedSecrets keys, keys still holding a REPLACE_WITH_GENERATED placeholder
    # in the stack's env files, and any keys named on the command line (secrets new <stack> KEY ...).
    # Empty optional keys are left alone: for several clients an empty secret means "disabled".
    $placeholders = foreach ($p in @($dirs.RunEnv, $dirs.SecretsEnv)) {
        (Read-NornirDotEnvFile $p).GetEnumerator() | Where-Object { $_.Value -match 'REPLACE_WITH_GENERATED' } | ForEach-Object { $_.Key }
    }
    $explicit = @($Rest | Select-Object -Skip 1)
    $want = @(@($e.Required) + @($e.GeneratedSecrets) | Where-Object { $_ -and $_ -match '(SECRET|TOKEN|PASSWORD)$' }) + @($placeholders) + $explicit | Where-Object { $_ } | Select-Object -Unique
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $want) {
        if (-not (Test-PlaceholderValue $envMap[$k])) { Write-Host "  $k already set; keeping"; continue }
        if ($k -match '^SQL_SERVER_PASSWORD$|ConnectionStrings') { Write-Host "  $k is an existing account's password: set it by hand" -ForegroundColor Yellow; continue }
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $v = [Convert]::ToBase64String($bytes).TrimEnd('=') -replace '\+', '-' -replace '/', '_'
        if ($k -match 'PASSWORD$') { $v = "Aa1!$v" }  # satisfy SQL Server complexity rules
        # Replace the placeholder where it lives (Viking compose files pass the run.env into the
        # container as env_file, so the value must be there); otherwise add it to secrets.env.
        if (Set-EnvFileValue -Path $dirs.SecretsEnv -Key $k -Value $v) { Write-Host "  generated $k (secrets.env)" }
        elseif (Set-EnvFileValue -Path $dirs.RunEnv -Key $k -Value $v) { Write-Host "  generated $k ($($key).run.env)" }
        else { $lines.Add("$k=$v"); Write-Host "  generated $k (secrets.env)" }
    }
    Write-Host '  Client secrets must match across stacks (e.g. viking-corrections IdentityServer__ClientSecret = viking-identity CORRECTION_SERVICE_CLIENT_SECRET); copy them after generating.' -ForegroundColor Yellow
    if ($lines.Count) {
        $header = if (Test-Path -LiteralPath $dirs.SecretsEnv) { @() } else { @("# Generated by stack.ps1 secrets new $key on $(Get-Date -Format s). Not in git.") }
        Add-Content -LiteralPath $dirs.SecretsEnv -Value (@($header) + $lines) -Encoding utf8
        if (-not (Test-NornirWindowsHost)) { & chmod 600 $dirs.SecretsEnv }
        Write-Host "Wrote $($dirs.SecretsEnv). Copy client secrets to the services that consume them (see accounts_and_tokens docs)."
    }
    else { Write-Host 'No empty *_SECRET / *_TOKEN / *_PASSWORD keys to generate.' }
    $script:Rc = 0; return
}

function Invoke-CertsTool {
    $act = if ($Action) { $Action } else { 'status' }
    $envMap = Read-HostEnv -Root $Root
    $hostStacks = @(($envMap['NORNIR_DOCKER_HOST_STACKS'] -split '[,\s]+') | Where-Object { $_ })
    $certsEntry = $script:Registry['viking-certs']
    if ($certsEntry) { $envMap = Get-StackEnvironment -Entry $certsEntry -Root $Root }
    elseif (-not $envMap['TLS_CERT_NAME'] -and $envMap['VIKING_DOMAIN']) { $envMap['TLS_CERT_NAME'] = $envMap['VIKING_DOMAIN'] }
    $certName = $envMap['TLS_CERT_NAME']
    if (-not $certName) { throw 'TLS_CERT_NAME (or VIKING_DOMAIN) must be set in host.env' }
    $names = @((Get-VikingHostnameDefaults -Env $envMap).Values)
    if ($envMap['TLS_HOSTNAMES']) { $names = @($envMap['TLS_HOSTNAMES'] -split '[,\s]+' | Where-Object { $_ }) }
    switch ($act) {
        'status' {
            foreach ($c in (Test-DockerHostCertificate -CertsDir $script:Layout.Certs -CertName $certName -Hostnames $names)) { Write-Check $c.Status $c.Message }
            $script:Rc = 0; return
        }
        'manual' {
            $c = if ($Cert) { $Cert } elseif ($Rest.Count -gt 0) { $Rest[0] } else { throw 'certs manual -Cert <cert.pem> -Key <key.pem> [-Chain <chain.pem>]' }
            $k = if ($Key) { $Key } elseif ($Rest.Count -gt 1) { $Rest[1] } else { throw 'certs manual needs -Key' }
            $ch = if ($Chain) { $Chain } elseif ($Rest.Count -gt 2) { $Rest[2] } else { '' }
            Install-DockerHostCertificate -CertsDir $script:Layout.Certs -CertName $certName -CertPath $c -KeyPath $k -ChainPath $ch -Hostnames $names -PfxPassword $PfxPassword -Force:$Force
            Restart-TlsReloadContainers; return
        }
        { $_ -in 'letsencrypt', 'acme-eab' } {
            if (-not $certsEntry) { throw 'viking-certs stack not found (set VIKING_REPO_ROOT_HOST in host.env)' }
            $envMap['TLS_MODE'] = $act
            $base = Get-StackComposeBaseArgs -Entry $certsEntry -Root $Root
            Push-Location $certsEntry.RepoRoot
            try {
                $svc = if ($certsEntry.DefaultService) { $certsEntry.DefaultService } else {
                    (Invoke-WithProcessEnv -Env $envMap -Script { & docker @base config --services } | Select-Object -First 1)
                }
                $code = 0
                Invoke-WithProcessEnv -Env $envMap -Script {
                    Invoke-Docker -Arguments (@($base) + @('run', '--rm', '-e', "TLS_MODE=$act", $svc, '--once')); $script:lastCode = $script:Rc
                    if ($script:lastCode -eq 0) { Invoke-Docker -Arguments (@($base) + @('up', '-d')); $script:lastCode = $script:Rc }
                }
                $code = $script:lastCode
            }
            finally { Pop-Location }
            if ($code -eq 0) {
                Write-Host "TLS_MODE=$act issued. Set TLS_MODE=$act in host.env so the renewer keeps using it." -ForegroundColor Yellow
            }
            $script:Rc = $code
            return
        }
        'reload' { Restart-TlsReloadContainers; return }
        'push' {
            $targets = Import-DockerTargets -Root $Root
            $dest = if ($Target) { @($Target -split ',') } else { @($targets.Keys | Where-Object { $targets[$_].CertPush }) }
            if (-not $dest.Count) { throw 'certs push: pass -Target <name> or set CertPush = $true on targets in targets.psd1' }
            if ($From) {
                # Run from the dev box: fetch the current cert from the issuing host (usually web) first.
                $src = $targets[$From]
                if (-not $src) { throw "certs push -From: unknown target '$From'" }
                Receive-DockerHostCertificate -Target $src -Name $From -CertsDir $script:Layout.Certs -CertName $certName
                $dest = @($dest | Where-Object { $_ -ne $From })
            }
            foreach ($n in $dest) {
                Send-DockerHostCertificate -Target $targets[$n] -Name $n -CertsDir $script:Layout.Certs -CertName $certName
            }
            $script:Rc = 0; return
        }
        'install-iis' {
            if (-not (Test-NornirWindowsHost)) { throw 'install-iis runs on the IIS host: stack.ps1 certs install-iis -Target iis' }
            $viking = Get-RepoRootFromEnv -VarName 'VIKING_REPO_ROOT_HOST' -HostEnv $envMap
            $installer = Join-DockerHostPath $viking 'deploy/Install-IisCertificate.ps1'
            $pfx = Join-DockerHostPath $script:Layout.Certs $certName 'cert.pfx'
            $hostHeader = $envMap['VIKING_HOSTNAME_WEBSVC']
            Invoke-PwshScript -Path $installer -Arguments @('-PfxPath', $pfx, '-HostHeader', $hostHeader) -EnvMap @{}; return
        }
        default { throw "certs actions: status, manual, letsencrypt, acme-eab, push, reload, install-iis" }
    }
}

#endregion

$script:Bound = $PSBoundParameters

# Accept both `stack.ps1 <stack> <action>` and `stack.ps1 <action> <stack>`.
if ($StackActions -contains $Stack -and $Action -and ($script:Registry.Contains($Action) -or $Action -eq 'all')) {
    $Stack, $Action = $Action, $Stack
}

# Remote dispatch (tunnel is local-side ssh; certs push runs here and reaches out itself).
if ($Target -and -not ($Stack -eq 'certs' -and $Action -eq 'push')) {
    $script:Rc = 0
    if ($Stack -eq 'tunnel') { Start-Tunnel } else { Invoke-OnTargets }
    exit $script:Rc
}

$script:Rc = 0
$exitCode = 0
switch ($Stack) {
    'list' { Show-List; $exitCode = $script:Rc }
    'targets' { Show-Targets; $exitCode = $script:Rc }
    'doctor' { Invoke-Doctor; $exitCode = $script:Rc }
    'prune' { Invoke-Prune; $exitCode = $script:Rc }
    'certs' { Invoke-CertsTool; $exitCode = $script:Rc }
    'secrets' {
        if ($Action -ne 'new') { throw 'secrets new <stack>' }
        New-StackSecrets; $exitCode = $script:Rc
    }
    'tunnel' { throw 'tunnel needs -Target <name>' }
    default {
        $act = if ($Action) { $Action } else { 'status' }
        if ($StackActions -notcontains $act) { throw "Unknown action '$act'. Actions: $($StackActions -join ', ')" }
        $keys = if ($Stack -eq 'all') { Get-HostStackKeys } else { @($Stack -split ',') }
        if ($Stack -eq 'all' -and $act -eq 'down') { [array]::Reverse($keys) }
        foreach ($k in $keys) {
            $script:Rc = 0
            Invoke-Stack -Key $k -Act $act
            $c = $script:Rc
            if ($c -ne 0) {
                $exitCode = $c
                if ($Stack -eq 'all' -and $act -ne 'status') { Write-Warning "$k failed (exit $c); stopping."; break }
            }
        }
    }
}
exit $exitCode
