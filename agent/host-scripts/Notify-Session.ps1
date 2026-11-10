<#
.SYNOPSIS
  Send text to a Claude session by name through a one-shot headless claude run (host side, no polling).
.DESCRIPTION
  Runs `claude -p` limited to SendMessage, ListAgents and ToolSearch, asks it to send -Text to -Session, and appends a
  line to the notify log. Exits 0 when the headless run replied OK.
  Log: $env:NORNIR_NOTIFY_LOG, else <NORNIR_DOCKER_USER_ROOT>\Logs\nornir-build\notify.log (D:\Docker by default).
.PARAMETER Session
  Name of the session to message.
.PARAMETER Text
  The message.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Session,
    [Parameter(Mandatory, Position = 1)][string]$Text
)
$ErrorActionPreference = 'Stop'
$root = if ($env:NORNIR_DOCKER_USER_ROOT) { $env:NORNIR_DOCKER_USER_ROOT } else { 'D:\Docker' }
$log = if ($env:NORNIR_NOTIFY_LOG) { $env:NORNIR_NOTIFY_LOG } else { Join-Path $root 'Logs\nornir-build\notify.log' }
$null = New-Item -ItemType Directory -Force -Path (Split-Path $log)

$prompt = "Use the SendMessage tool to send this exact text to the session named `"$Session`" (run ListAgents first if the name does not resolve). Text:`n$Text`nReply with only OK or the error."
Push-Location ([System.IO.Path]::GetTempPath())
try {
    $job = Start-Job { param($p) & claude -p $p --allowedTools 'SendMessage,ListAgents,ToolSearch' 2>&1 | Out-String } -ArgumentList $prompt
    if (-not (Wait-Job $job -Timeout 300)) { Stop-Job $job; $out = 'timeout after 300 s' }
    else { $out = (Receive-Job $job) -join ' ' }
    Remove-Job $job -Force
}
finally { Pop-Location }
$line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Session, ($Text -replace "`n", ' '), ($out -replace "`r?`n", ' ')
Add-Content -Path $log -Value $line
if ($out.TrimStart().StartsWith('OK')) { exit 0 } else { exit 1 }
