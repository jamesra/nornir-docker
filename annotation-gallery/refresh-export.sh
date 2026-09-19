#!/usr/bin/env bash
# Weekly / on-demand AnnotationCrops export for gallery volumes.
#
# Run this on nornir:prod (or cursor-dev), NOT in the slim gallery container.
# The gallery HTTP process must never spawn nornir-build.
#
# Registry child name = Identity volume name; child target = volume root.
# For each child: ExportAnnotationCrops -Output {root}/AnnotationCrops
#
# Cron example (on the build appliance, after nornir:prod is available):
#   15 3 * * 0 GALLERY_VOLUME_DIR=/gallery-volumes \
#     GALLERY_ODATA_TEMPLATE='https://websvc.codepharm.net/{volume}/OData' \
#     /opt/nornir/annotation-gallery/refresh-export.sh
set -euo pipefail

REGISTRY="${GALLERY_VOLUME_DIR:-/gallery-volumes}"
TEMPLATE="${GALLERY_ODATA_TEMPLATE:-https://websvc.codepharm.net/{volume}/OData}"
NORNIR_BUILD="${NORNIR_BUILD:-nornir-build}"

if [[ ! -d "$REGISTRY" ]]; then
  echo "refresh-export: missing registry $REGISTRY" >&2
  exit 1
fi

for child in "$REGISTRY"/*; do
  [[ -e "$child" ]] || continue
  name="$(basename "$child")"
  case "$name" in
    .*|*'..'*) echo "refresh-export: skip $name" >&2; continue ;;
  esac
  if [[ "$name" == *'/'* ]]; then
    continue
  fi
  target="$(readlink -f "$child")"
  output="$target/AnnotationCrops"
  odata="${TEMPLATE//\{volume\}/$name}"
  echo "refresh-export: $name -> $output ($odata)"
  "$NORNIR_BUILD" ExportAnnotationCrops "$target" \
    -OData "$odata" \
    -Output "$output"
done
