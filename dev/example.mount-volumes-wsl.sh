#!/usr/bin/env bash
# Template — copy to D:\Docker\Run\nornir-dev\mount-volumes-wsl.sh and run on the WSL2 host (not inside the container).
# Mounts \\192.168.0.199\Data\Volumes for Docker bind mounts via NORNIR_VOLUMES_HOST.
set -euo pipefail

MOUNT_POINT="${NORNIR_VOLUMES_MOUNT:-/mnt/nornir-volumes}"
UNC_WINDOWS='\\192.168.0.199\Data\Volumes'
CIFS_SOURCE='//192.168.0.199/Data/Volumes'

sudo mkdir -p "${MOUNT_POINT}"

if mountpoint -q "${MOUNT_POINT}"; then
  echo "Already mounted: ${MOUNT_POINT}"
  ls -la "${MOUNT_POINT}" | head -5
  exit 0
fi

echo "Attempting drvfs mount of ${UNC_WINDOWS} -> ${MOUNT_POINT}"
if sudo mount -t drvfs "${UNC_WINDOWS}" "${MOUNT_POINT}"; then
  echo "Mounted via drvfs."
  ls -la "${MOUNT_POINT}" | head -5
  exit 0
fi

echo "drvfs failed; attempting CIFS mount of ${CIFS_SOURCE}"
CIFS_OPTS="uid=$(id -u),gid=$(id -g),file_mode=0644,dir_mode=0755"
if [[ -n "${CIFS_USER:-}" ]]; then
  CIFS_OPTS="${CIFS_OPTS},username=${CIFS_USER}"
  if [[ -n "${CIFS_PASS:-}" ]]; then
    CIFS_OPTS="${CIFS_OPTS},password=${CIFS_PASS}"
  fi
else
  CIFS_OPTS="${CIFS_OPTS},guest"
fi

sudo mount -t cifs "${CIFS_SOURCE}" "${MOUNT_POINT}" -o "${CIFS_OPTS}"
echo "Mounted via CIFS."
ls -la "${MOUNT_POINT}" | head -5
