#!/bin/bash
# usage: watch_job.sh [-m MARKER -n COUNT] [-s] [-t NOTE] "<session>" "<label>" "<done-check cmd>|-" [<log or 'glob'> ...]
# Run in tmux on the HOST. Every 60 s:
#  - a failure signature in any log -> ONE message: FAILED, with up to 3 matching lines (file: line), then exit 1;
#  - done -> ONE message: ENDED, with each log's last line and NOTE, then exit 0.
# Done = the done-check command succeeds, or (-m/-n) MARKER lines across all logs reach COUNT
# (e.g. -m LANE-DONE -n 4: every lane prints LANE-DONE when finished). Use "-" as the done-check with -m.
# Logs: files or quoted globs, re-expanded each pass (lane logs created later are picked up).
# By default only lines written after start count; -s scans whole files (fresh logs; catches failures
# that happened before the watcher started). Don't use -s on logs appended across runs.
MARK=""; CNT=0; FROMSTART=0; NOTE=""
while getopts "m:n:st:" o; do case $o in m) MARK=$OPTARG;; n) CNT=$OPTARG;; s) FROMSTART=1;; t) NOTE=$OPTARG;; *) exit 2;; esac; done
shift $((OPTIND-1))
S=$1; L=$2; DONE=$3; shift 3; PATTERNS=("$@")
[ -n "$S" ] && [ -n "$L" ] && [ -n "$DONE" ] || { echo "usage: see header" >&2; exit 2; }
FAIL='STOPPED|FAILED|Traceback|OCI runtime|Error response|No such container|Killed|MemoryError'
N=/srv/docker/Logs/nornir-build/scripts/notify_session.sh
declare -A pos
logs(){ local p f; for p in "${PATTERNS[@]}"; do for f in $p; do [ -f "$f" ] && echo "$f"; done; done | sort -u; }
[ $FROMSTART = 1 ] || while IFS= read -r f; do pos[$f]=$(stat -c %s "$f"); done < <(logs)
done_now(){
  if [ -n "$MARK" ]; then
    local c=0 f; while IFS= read -r f; do c=$((c + $(grep -c -- "$MARK" "$f"))); done < <(logs)
    [ "$c" -ge "$CNT" ]
  else bash -c "$DONE" >/dev/null 2>&1; fi
}
while true; do
  hits=""
  while IFS= read -r f; do
    h=$(tail -c +$(( ${pos[$f]:-0} + 1 )) "$f" | grep -E "$FAIL" | head -3 | sed "s|^|$(basename "$f"): |")
    pos[$f]=$(stat -c %s "$f"); [ -n "$h" ] && hits+="$h"$'\n'
  done < <(logs)
  if [ -n "$hits" ]; then
    "$N" "$S" "[watch $L] FAILED at $(date +%T): $(echo "$hits" | head -3 | cut -c1-250 | tr '\n' ' ')"; exit 1
  fi
  if done_now; then
    t=""; while IFS= read -r f; do t+=" | $(basename "$f"): $(tail -1 "$f" | cut -c1-150)"; done < <(logs)
    "$N" "$S" "[watch $L] ENDED at $(date +%T).${t:0:800}${NOTE:+ Next: $NOTE}"; exit 0
  fi
  sleep 60
done
