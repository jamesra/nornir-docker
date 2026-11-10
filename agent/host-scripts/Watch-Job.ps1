<#
.SYNOPSIS
  Watch a long job's logs and message a Claude session ONCE, on the first failure or when the job is done.
.DESCRIPTION
  Every 60 s: a failure signature in any log sends one FAILED message (up to 3 matching lines) and exits 1; done sends
  one ENDED message (each log's last line, plus -Note) and exits 0. Done = the -DoneCheck command succeeds, or
  -Marker lines across all logs reach -Count (parallel lanes each print the marker when finished; give -DoneCheck '-').
  Logs are files or globs, re-expanded each pass. By default only lines written after start count; -FromStart scans
  whole files (fresh logs only; not for logs appended across runs).
  Run it in its own console (Windows Terminal tab or Start-Process) on the HOST; it calls Notify-Session.ps1.
.EXAMPLE
  .\Watch-Job.ps1 -Session 'Build2 RC RC1' -Label 'grid32' -DoneCheck '-' -Marker LANE-DONE -Count 4 -Logs 'D:\Docker\Logs\nornir-build\lane*.log'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Session,
    [Parameter(Mandatory, Position = 1)][string]$Label,
    [Parameter(Mandatory, Position = 2)][string]$DoneCheck,
    [Parameter(Position = 3, ValueFromRemainingArguments)][string[]]$Logs,
    [string]$Marker = '',
    [int]$Count = 0,
    [switch]$FromStart,
    [string]$Note = ''
)
$fail = 'STOPPED|FAILED|Traceback|OCI runtime|Error response|No such container|Killed|MemoryError'
$notify = Join-Path $PSScriptRoot 'Notify-Session.ps1'
$pos = @{}

function Get-WatchedLogs { $Logs | ForEach-Object { Get-ChildItem -Path $_ -File -ErrorAction SilentlyContinue } | Sort-Object FullName -Unique }
function Get-NewText([string]$path) {
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = if ($pos.ContainsKey($path)) { [Math]::Min($pos[$path], $fs.Length) } else { 0 }
        $fs.Seek($start, 'Begin') | Out-Null
        $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
        $pos[$path] = $fs.Length
        $text
    }
    finally { $fs.Dispose() }
}

if (-not $FromStart) { foreach ($f in Get-WatchedLogs) { $pos[$f.FullName] = $f.Length } }

while ($true) {
    $hits = @()
    foreach ($f in Get-WatchedLogs) {
        $new = Get-NewText $f.FullName
        $hits += ($new -split "`r?`n" | Where-Object { $_ -match $fail } | Select-Object -First 3 | ForEach-Object { "$($f.Name): $_" })
    }
    if ($hits.Count -gt 0) {
        $msg = ($hits | Select-Object -First 3 | ForEach-Object { $_.Substring(0, [Math]::Min(250, $_.Length)) }) -join ' '
        & $notify $Session "[watch $Label] FAILED at $(Get-Date -Format 'HH:mm:ss'): $msg"
        exit 1
    }
    if ($Marker) {
        $c = 0
        foreach ($f in Get-WatchedLogs) { $c += @(Select-String -Path $f.FullName -SimpleMatch -Pattern $Marker -ErrorAction SilentlyContinue).Count }
        $done = $c -ge $Count
    }
    else {
        $done = $false
        if ($DoneCheck -ne '-') { try { $null = & pwsh -NoProfile -Command $DoneCheck 2>&1; $done = ($LASTEXITCODE -eq 0) } catch { $done = $false } }
    }
    if ($done) {
        $tail = ''
        foreach ($f in Get-WatchedLogs) {
            $last = (Get-Content -Path $f.FullName -Tail 1 -ErrorAction SilentlyContinue)
            if ($last) { $tail += " | $($f.Name): $($last.Substring(0, [Math]::Min(150, $last.Length)))" }
        }
        if ($tail.Length -gt 800) { $tail = $tail.Substring(0, 800) }
        $next = if ($Note) { " Next: $Note" } else { '' }
        & $notify $Session "[watch $Label] ENDED at $(Get-Date -Format 'HH:mm:ss').$tail$next"
        exit 0
    }
    Start-Sleep -Seconds 60
}
