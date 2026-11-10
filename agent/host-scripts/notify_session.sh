#!/bin/bash
# usage: notify_session.sh "<session name>" "<text>"
# Sends <text> to a Claude session by name via a one-shot headless claude run (host side, no polling).
# Logs to /srv/docker/Logs/nornir-build/notify.log. Exit 0 when the headless run replied OK.
S=$1; T=$2; LOG=/srv/docker/Logs/nornir-build/notify.log
[ -n "$S" ] && [ -n "$T" ] || { echo "usage: $0 <session> <text>" >&2; exit 2; }
cd /tmp || exit 1
out=$(timeout 300 claude -p "Use the SendMessage tool to send this exact text to the session named \"$S\" (run ListAgents first if the name doesn't resolve). Text:
$T
Reply with only OK or the error." --allowedTools 'SendMessage,ListAgents,ToolSearch' 2>&1)
printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$S" "${T//$'\n'/ }" "${out//$'\n'/ }" >> "$LOG"
echo "$out" | grep -q '^OK' 
