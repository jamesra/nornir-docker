#!/usr/bin/env bash
# Read-only status report for a Nornir volume. Usage: volume_status.sh /storageN/<Volume>
set -uo pipefail

VOL="${1:?usage: volume_status.sh /storageN/<Volume>}"
VOL="${VOL%/}"
[[ -d "$VOL" ]] || { echo "error: not a directory: $VOL" >&2; exit 1; }
NAME="$(basename "$VOL")"

echo "Volume       : $VOL"

code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://websvc.codepharm.net/${NAME}/OData/\$metadata")"
case "$code" in
  200) ann="YES (OData 200) - section .mosaic files are protected; lock the chain before any build" ;;
  404) ann="no (OData 404)" ;;
  *)   ann="UNKNOWN (OData http=$code) - treat as annotated and ask" ;;
esac
echo "Annotated    : $ann"

# Last build activity: StageTimings.json (2026-06+) or the last timestamp in Timing.txt.
# VolumeData.xml mtimes are unreliable (any save touches them).
last=""
if [[ -f "$VOL/StageTimings.json" ]]; then
  last="$(grep -o '"utc_timestamp": *"[^"]*"' "$VOL/StageTimings.json" | tail -1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi
if [[ -z "$last" && -f "$VOL/Timing.txt" ]]; then
  last="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$VOL/Timing.txt" | tail -1)"
fi
if [[ -n "$last" ]] && ts="$(date -d "$last" +%s 2>/dev/null)"; then
  days=$(( ( $(date +%s) - ts ) / 86400 ))
  stale=""; (( days > 90 )) && stale="  <- STALE: ask before building"
  echo "Last activity: $last (${days} days ago)${stale}"
  [[ -f "$VOL/Timing.txt" ]] && echo "  last stages: $(tail -c 2000 "$VOL/Timing.txt" | grep -oE '^\s*[A-Za-z]+ :' | tail -4 | tr -d ' \t:' | tr '\n' ' ')"
else
  echo "Last activity: unknown (no Timing.txt/StageTimings.json)"
fi

backup_root="$(dirname "$VOL")/_nornir_backups/$NAME"
if [[ -d "$backup_root" ]]; then
  echo "Latest backup: $(ls -1 "$backup_root" | sort | tail -1)"
else
  echo "Latest backup: none"
fi

echo
echo "Blocks / StosGroups (Manual = hand-fixed stos files):"
for block in "$VOL"/*/; do
  b="${block%/}"
  [[ -f "$b/VolumeData.xml" ]] || continue
  echo "  [$(basename "$b")]"
  for g in "$b"/*/; do
    g="${g%/}"
    gn="$(basename "$g")"
    [[ "$gn" =~ ^[0-9]+$ ]] && continue   # section folders
    if [[ -d "$g/Manual" ]] || ls "$g"/*.stos >/dev/null 2>&1; then
      printf '    %-28s stos=%-5s Manual=%s\n' "$gn" \
        "$(find "$g" -maxdepth 1 -name '*.stos' 2>/dev/null | wc -l)" \
        "$(find "$g/Manual" -maxdepth 1 -name '*.stos' 2>/dev/null | wc -l)"
    fi
  done
  maps="$(grep -o '<StosMap [^>]*Name="[^"]*"' "$b/VolumeData.xml" | sed 's/.*Name="\([^"]*\)"/\1/' | sort -u | tr '\n' ' ')"
  echo "    StosMaps: ${maps:-none}"
  dmg="$(python3 -c "import sys,xml.etree.ElementTree as E;print(','.join((e.text or '').strip() for e in E.parse(sys.argv[1]).getroot().iter('NonStosSectionNumbers')))" "$b/VolumeData.xml" 2>/dev/null)"
  echo "    Damaged (NonStosSectionNumbers): $(echo "$dmg" | tr ',' '\n' | grep -c '[0-9]') sections${dmg:+ -> $dmg}"
  nsec="$(find "$b" -maxdepth 1 -type d -regex '.*/[0-9]+' | wc -l)"
  echo "    Section folders: $nsec"
done

echo
echo "Mosaic chain (XML only; L=locked U=unlocked):"
for block in "$VOL"/*/; do
  b="${block%/}"; [[ -f "$b/VolumeData.xml" ]] || continue
  echo "  [$(basename "$b")]"
  python3 "$(dirname "$0")/mosaic_chain.py" "$b"
done

if [[ -f /run/nornir-offline-mounts ]]; then
  echo "Offline mounts: $(tr '\n' ' ' < /run/nornir-offline-mounts)"
fi

err="$(ls -t "$VOL"/logs/*-Errors.txt "$VOL"/*-Errors.txt "$VOL"/Logs/*rror* 2>/dev/null | head -1)"
if [[ -n "$err" ]]; then
  echo
  echo "Newest error log: $err ($(date -r "$err" '+%Y-%m-%d'))"
  tail -n 5 "$err" | cut -c1-200 | sed 's/^/    /'
fi
