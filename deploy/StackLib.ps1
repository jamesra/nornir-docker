<#
.SYNOPSIS
  Shared helpers for stack.ps1: host layout, stack registries, env merging, compose/ssh invocation.

.DESCRIPTION
  Dot-sourced by stack.ps1, Initialize-DockerHost.ps1, and DockerHostCerts.ps1. Written for
  PowerShell 7 on Windows and Ubuntu: paths are built with Join-Path segments (never literal
  backslashes) and OS-specific behaviour branches on Test-NornirWindowsHost.

  Host layout (root = NORNIR_DOCKER_USER_ROOT; D:\Docker on Windows, /srv/docker on Linux):
    Run/_host/host.env, Run/_host/targets.psd1, Run/<stack>/<stack>.run.env, Run/<stack>/secrets/,
    Builds/<stack>/, Data/<stack>/, Certs/<cert-name>/, Work/, Logs/<stack>/
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'NornirDotEnv.ps1')

function Test-NornirWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Get-DockerHostRoot {
    <#
    .SYNOPSIS
      Resolve the machine-local Docker root (NORNIR_DOCKER_USER_ROOT; D:\Docker or /srv/docker).
    #>
    param([string]$Root = '')
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root.Trim() }
    if ($env:NORNIR_DOCKER_USER_ROOT -and $env:NORNIR_DOCKER_USER_ROOT.Trim()) {
        return $env:NORNIR_DOCKER_USER_ROOT.Trim()
    }
    if (Test-NornirWindowsHost) { return 'D:\Docker' }
    return '/srv/docker'
}

function Join-DockerHostPath {
    <#
    .SYNOPSIS
      Join a root with any number of path segments using the platform separator.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(ValueFromRemainingArguments)][string[]]$Segments
    )
    $p = $Root
    foreach ($s in $Segments) {
        foreach ($part in ($s -split '[\\/]')) {
            if ($part) { $p = Join-Path $p $part }
        }
    }
    return $p
}

function ConvertTo-DockerBindPath {
    <#
    .SYNOPSIS
      Forward-slash form of a host path for compose interpolation (Docker Desktop accepts D:/x).
    #>
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -replace '\\', '/')
}

function Get-DockerHostLayout {
    param([string]$Root = '')
    $r = Get-DockerHostRoot -Root $Root
    return [ordered]@{
        Root     = $r
        HostDir  = Join-DockerHostPath $r 'Run' '_host'
        HostEnv  = Join-DockerHostPath $r 'Run' '_host' 'host.env'
        HostSecretsEnv = Join-DockerHostPath $r 'Run' '_host' 'secrets' 'secrets.env'
        Targets  = Join-DockerHostPath $r 'Run' '_host' 'targets.psd1'
        Run      = Join-DockerHostPath $r 'Run'
        Builds   = Join-DockerHostPath $r 'Builds'
        Data     = Join-DockerHostPath $r 'Data'
        Certs    = Join-DockerHostPath $r 'Certs'
        Work     = Join-DockerHostPath $r 'Work'
        Logs     = Join-DockerHostPath $r 'Logs'
    }
}

function Get-StackDirs {
    param(
        [Parameter(Mandatory)][string]$Stack,
        [string]$Root = ''
    )
    $l = Get-DockerHostLayout -Root $Root
    $run = Join-DockerHostPath $l.Run $Stack
    return [ordered]@{
        Run        = $run
        RunEnv     = Join-DockerHostPath $run "$Stack.run.env"
        Secrets    = Join-DockerHostPath $run 'secrets'
        SecretsEnv = Join-DockerHostPath $run 'secrets' 'secrets.env'
        Data       = Join-DockerHostPath $l.Data $Stack
        Logs       = Join-DockerHostPath $l.Logs $Stack
        Builds     = Join-DockerHostPath $l.Builds $Stack
    }
}

function Read-HostEnv {
    <#
    .SYNOPSIS
      Merge Run/_host/host.env and Run/_host/secrets/secrets.env (later wins) into a hashtable.
    #>
    param([string]$Root = '')
    $l = Get-DockerHostLayout -Root $Root
    $merged = @{}
    foreach ($p in @($l.HostEnv, $l.HostSecretsEnv)) {
        foreach ($e in (Read-NornirDotEnvFile $p).GetEnumerator()) { $merged[$e.Key] = $e.Value }
    }
    return $merged
}

function Get-RepoRootFromEnv {
    <#
    .SYNOPSIS
      Resolve a repo root from process env, then host.env, with legacy fallbacks.
    #>
    param(
        [Parameter(Mandatory)][string]$VarName,
        [hashtable]$HostEnv = @{}
    )
    $legacy = @{
        'NORNIR_REPO_ROOT_HOST' = @('NORNIR_MONOREPO_ROOT')
        'VIKING_REPO_ROOT_HOST' = @()
    }
    $names = @($VarName) + @($legacy[$VarName] | Where-Object { $_ })
    foreach ($n in $names) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ([string]::IsNullOrWhiteSpace($v) -and $HostEnv.ContainsKey($n)) { $v = $HostEnv[$n] }
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            if ($n -ne $VarName) { Write-Warning "$n is deprecated for the host repo path; set $VarName in host.env." }
            return $v.Trim()
        }
    }
    if ($VarName -eq 'NORNIR_REPO_ROOT_HOST') {
        # This file lives in <repo>/nornir-docker/deploy.
        return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    }
    return $null
}

function Import-StackRegistry {
    <#
    .SYNOPSIS
      Load nornir-docker/deploy/stacks.psd1 plus Viking/deploy/stacks.psd1 (when present).

    .OUTPUTS
      Ordered hashtable stack-key -> entry; each entry gains RepoRoot and RegistryPath.
    #>
    param([hashtable]$HostEnv = @{})
    $out = [ordered]@{}
    $sources = @(
        @{ Var = 'NORNIR_REPO_ROOT_HOST'; Rel = @('nornir-docker', 'deploy', 'stacks.psd1') },
        @{ Var = 'VIKING_REPO_ROOT_HOST'; Rel = @('deploy', 'stacks.psd1') }
    )
    foreach ($src in $sources) {
        $repo = Get-RepoRootFromEnv -VarName $src.Var -HostEnv $HostEnv
        if (-not $repo) { continue }
        $path = Join-DockerHostPath $repo ($src.Rel -join '/')
        if (-not (Test-Path -LiteralPath $path)) {
            if ($src.Var -eq 'VIKING_REPO_ROOT_HOST') { Write-Verbose "No Viking registry at $path" }
            continue
        }
        $data = Import-PowerShellDataFile -LiteralPath $path
        foreach ($k in ($data.Stacks.Keys | Sort-Object)) {
            $entry = @{} + $data.Stacks[$k]
            $entry.Key = $k
            $entry.RepoRoot = $repo
            $entry.RepoRootVar = if ($entry.RepoRootVar) { $entry.RepoRootVar } else { $src.Var }
            $entry.RegistryPath = $path
            $out[$k] = $entry
        }
    }
    return $out
}

function Get-VikingHostnameDefaults {
    <#
    .SYNOPSIS
      Derive VIKING_HOSTNAME_<SERVICE> = <sub>.<VIKING_DOMAIN> for any that are unset.
    #>
    param([hashtable]$Env)
    $subs = [ordered]@{
        IDENTITY         = 'identity'
        WEBSVC           = 'websvc'
        ANNOTATION       = 'annotation'
        CORRECTIONS      = 'corrections'
        SEGMENTATION     = 'segmentation'
        SEGMENTATIONDEMO = 'segmentationdemo'
        SEG_V3           = 'segmentation-v3'
        SEG_V4           = 'segmentation-v4'
        SEG_SEM_V1       = 'segmentation-sem-v1'
        GALLERY          = 'gallery'
        TEM_GALLERY      = 'gallery-tem'
        SEM_GALLERY      = 'gallery-sem'
    }
    $domain = $Env['VIKING_DOMAIN']
    $result = [ordered]@{}
    foreach ($k in $subs.Keys) {
        $name = "VIKING_HOSTNAME_$k"
        $v = $Env[$name]
        if ([string]::IsNullOrWhiteSpace($v) -and -not [string]::IsNullOrWhiteSpace($domain)) {
            $v = "$($subs[$k]).$domain"
        }
        if ($v) { $result[$name] = $v }
    }
    return $result
}

function Get-StackEnvironment {
    <#
    .SYNOPSIS
      Build the full env (host.env + host secrets + stack run.env + stack secrets.env + contract vars).

    .DESCRIPTION
      Later files win. Contract variables (STACK_*, DOCKER_CERTS_DIR, repo roots, derived
      VIKING_HOSTNAME_*, TLS_CERT_NAME) are added when not already set.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [string]$Root = ''
    )
    $layout = Get-DockerHostLayout -Root $Root
    $dirs = Get-StackDirs -Stack $Entry.Key -Root $Root
    $envMap = Read-HostEnv -Root $Root
    foreach ($p in @($dirs.RunEnv, $dirs.SecretsEnv)) {
        foreach ($e in (Read-NornirDotEnvFile $p).GetEnumerator()) { $envMap[$e.Key] = $e.Value }
    }
    $contract = [ordered]@{
        NORNIR_DOCKER_USER_ROOT = $layout.Root
        STACK_NAME              = $Entry.Key
        STACK_RUN_DIR           = $dirs.Run
        STACK_SECRETS_DIR       = $dirs.Secrets
        STACK_DATA_DIR          = $dirs.Data
        STACK_LOGS_DIR          = $dirs.Logs
        DOCKER_CERTS_DIR        = $layout.Certs
        DOCKER_WORK_DIR         = $layout.Work
    }
    foreach ($k in $contract.Keys) {
        $envMap[$k] = ConvertTo-DockerBindPath $contract[$k]
    }
    foreach ($var in @('NORNIR_REPO_ROOT_HOST', 'VIKING_REPO_ROOT_HOST')) {
        if ([string]::IsNullOrWhiteSpace($envMap[$var])) {
            $r = Get-RepoRootFromEnv -VarName $var -HostEnv $envMap
            if ($r) { $envMap[$var] = $r }
        }
    }
    foreach ($e in (Get-VikingHostnameDefaults -Env $envMap).GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($envMap[$e.Key])) { $envMap[$e.Key] = $e.Value }
    }
    if ([string]::IsNullOrWhiteSpace($envMap['TLS_CERT_NAME']) -and $envMap['VIKING_DOMAIN']) {
        $envMap['TLS_CERT_NAME'] = $envMap['VIKING_DOMAIN']
    }
    return $envMap
}

function Get-StackEnvFileArgs {
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [string]$Root = ''
    )
    $layout = Get-DockerHostLayout -Root $Root
    $dirs = Get-StackDirs -Stack $Entry.Key -Root $Root
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($layout.HostEnv, $layout.HostSecretsEnv, $dirs.RunEnv, $dirs.SecretsEnv)) {
        if (Test-Path -LiteralPath $p) {
            $list.Add('--env-file'); $list.Add($p)
        }
    }
    return , $list.ToArray()
}

function Expand-StackTemplate {
    <#
    .SYNOPSIS
      Replace {VAR} tokens in a registry string (e.g. HealthUrl) from an env map.
    #>
    param([string]$Text, [hashtable]$Env)
    if (-not $Text) { return $Text }
    return [regex]::Replace($Text, '\{([A-Z0-9_]+)\}', {
            param($m)
            $v = $Env[$m.Groups[1].Value]
            if ($null -eq $v) { return $m.Value }
            return $v
        })
}

function Test-PlaceholderValue {
    <#
    .SYNOPSIS
      True when a value is empty or still an example placeholder (REPLACE_ME / REPLACE_WITH_...).
    #>
    param([string]$Value)
    return ([string]::IsNullOrWhiteSpace($Value) -or $Value -match 'REPLACE_(ME|WITH)')
}

function Set-EnvFileValue {
    <#
    .SYNOPSIS
      Replace KEY=... in an env file (first uncommented occurrence); return $false when the key is absent.
    #>
    param([string]$Path, [string]$Key, [string]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $lines = @(Get-Content -LiteralPath $Path)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = "$Key=$Value"
            Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
            return $true
        }
    }
    return $false
}

function Test-StackRequired {
    <#
    .SYNOPSIS
      Return a list of problems (missing run.env, empty REQUIRED keys, missing secret files).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [Parameter(Mandatory)][hashtable]$Env,
        [string]$Root = ''
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $dirs = Get-StackDirs -Stack $Entry.Key -Root $Root
    $example = if ($Entry.Example) { Join-DockerHostPath $Entry.RepoRoot $Entry.Example } else { $null }
    if ($Entry.Example -and -not (Test-Path -LiteralPath $dirs.RunEnv)) {
        $problems.Add("missing $($dirs.RunEnv) (copy from $example)")
    }
    foreach ($k in @($Entry.Required)) {
        if (-not $k) { continue }
        if (Test-PlaceholderValue $Env[$k]) {
            $problems.Add("$k is empty or a placeholder (Run/$($Entry.Key)/$($Entry.Key).run.env, its secrets/secrets.env, or host.env)")
        }
    }
    foreach ($s in @($Entry.Secrets)) {
        if (-not $s) { continue }
        $sp = Join-DockerHostPath $dirs.Secrets $s
        if (-not (Test-Path -LiteralPath $sp)) { $problems.Add("missing secret file $sp") }
    }
    return , $problems.ToArray()
}

function Invoke-WithProcessEnv {
    <#
    .SYNOPSIS
      Run a scriptblock with extra process environment variables, then restore.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Env,
        [Parameter(Mandatory)][scriptblock]$Script
    )
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$Env[$k], 'Process')
    }
    try { & $Script }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

function Get-StackComposeBaseArgs {
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [string[]]$ExtraProfiles = @(),
        [string]$Root = ''
    )
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add('compose')
    $project = if ($Entry.ComposeProject) { $Entry.ComposeProject } else { $Entry.Key }
    $a.Add('-p'); $a.Add($project)
    foreach ($x in (Get-StackEnvFileArgs -Entry $Entry -Root $Root)) { $a.Add($x) }
    foreach ($f in @($Entry.ComposeFiles)) {
        if (-not $f) { continue }
        $a.Add('-f'); $a.Add((Join-DockerHostPath $Entry.RepoRoot $f))
    }
    foreach ($p in (@($Entry.Profiles) + @($ExtraProfiles -split ",") | Where-Object { $_ } | Select-Object -Unique)) {
        $a.Add('--profile'); $a.Add($p)
    }
    return , $a.ToArray()
}

function Invoke-Docker {
    <#
    .SYNOPSIS
      Run docker with the console attached (no stdout capture); exit code in $script:Rc.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    Write-Host ("docker " + (($Arguments | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' ')) -ForegroundColor DarkGray
    & docker @Arguments
    # Exit code goes to $script:Rc (not the output stream) so docker keeps the console/TTY.
    $script:Rc = $LASTEXITCODE
}

function Import-DockerTargets {
    <#
    .SYNOPSIS
      Load Run/_host/targets.psd1 (remote deploy targets). Returns @{} when absent.
    #>
    param([string]$Root = '')
    $l = Get-DockerHostLayout -Root $Root
    if (-not (Test-Path -LiteralPath $l.Targets)) { return @{} }
    $data = Import-PowerShellDataFile -LiteralPath $l.Targets
    return $data.Targets
}

function ConvertTo-RemoteArg {
    <#
    .SYNOPSIS
      Single-quote an argument for a remote pwsh/bash command line.
    #>
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-RemotePwshCommand {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][string[]]$StackArgs
    )
    $root = $Target.Root
    $sep = if ($Target.Os -eq 'windows') { '\' } else { '/' }
    $launcher = "$root$sep" + 'stack.ps1'
    $quoted = ($StackArgs | ForEach-Object { ConvertTo-RemoteArg $_ }) -join ' '
    return "pwsh -NoLogo -NoProfile -File $(ConvertTo-RemoteArg $launcher) $quoted"
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][string]$Command,
        [switch]$Tty
    )
    $a = [System.Collections.Generic.List[string]]::new()
    if ($Tty) { $a.Add('-t') }
    foreach ($o in @($Target.SshOptions)) { if ($o) { $a.Add($o) } }
    $a.Add($Target.Ssh)
    $a.Add($Command)
    Write-Host ("ssh " + ($a -join ' ')) -ForegroundColor DarkGray
    & ssh @a
    $script:Rc = $LASTEXITCODE
}
