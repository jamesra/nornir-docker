# Shared .env parsing for nornir-docker PowerShell scripts.
# Dot-source:  . (Join-Path $PSScriptRoot 'NornirDotEnv.ps1')

function Parse-NornirEnvLine {
    param([string]$Line)
    $Line = $Line.TrimEnd()
    if (-not $Line.Trim() -or $Line.TrimStart().StartsWith('#')) {
        return $null
    }
    $eq = $Line.IndexOf('=')
    if ($eq -lt 1) { return $null }
    $key = $Line.Substring(0, $eq).Trim()
    if (-not $key) { return $null }
    $raw = $Line.Substring($eq + 1).TrimStart()
    if (-not $raw) {
        return @{ Key = $key; Value = '' }
    }
    $value = $null
    if ($raw.StartsWith('"')) {
        $end = $raw.IndexOf('"', 1)
        if ($end -lt 0) {
            throw "Unclosed double quote in env line: $Line"
        }
        $value = $raw.Substring(1, $end - 1)
    }
    elseif ($raw.StartsWith("'")) {
        $end = $raw.IndexOf("'", 1)
        if ($end -lt 0) {
            throw "Unclosed single quote in env line: $Line"
        }
        $value = $raw.Substring(1, $end - 1)
    }
    else {
        $value = $raw.Trim() -replace '\r$', ''
    }
    return @{ Key = $key; Value = $value }
}

function Read-NornirDotEnvFile {
    param([string]$Path)
    $out = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $out
    }
    Get-Content -LiteralPath $Path -Encoding utf8 | ForEach-Object {
        $pair = Parse-NornirEnvLine $_
        if ($null -ne $pair) {
            $out[$pair.Key] = $pair.Value
        }
    }
    return $out
}

function Get-NornirDotEnvValue {
    <#
    .SYNOPSIS
      Return the first non-empty value for Key from the given env files (in order).
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string[]]$Paths
    )
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($entry in (Read-NornirDotEnvFile $path).GetEnumerator()) {
            if ($entry.Key -eq $Key -and -not [string]::IsNullOrWhiteSpace($entry.Value)) {
                return $entry.Value
            }
        }
    }
    return $null
}

function Import-NornirDotEnvFile {
    <#
    .SYNOPSIS
      Load KEY=VALUE pairs into the current process environment (skip keys already set).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludeFromHostProcess = @('GITHUB_TOKEN', 'GH_TOKEN')
    )
    $exclude = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $ExcludeFromHostProcess) { [void]$exclude.Add($x) }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($entry in (Read-NornirDotEnvFile $Path).GetEnumerator()) {
        $name = $entry.Key
        if ($exclude.Contains($name)) { continue }
        $existing = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrEmpty($existing)) {
            [Environment]::SetEnvironmentVariable($name, $entry.Value, 'Process')
        }
    }
}
