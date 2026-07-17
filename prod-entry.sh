#!/usr/bin/env bash
# Production image entry: optional in-container CIFS/NFS (NORNIR_NET_MOUNTS=1), then exec CMD.
# Requires CAP_SYS_ADMIN (+ typically DAC_READ_SEARCH) and apparmor:unconfined when mounts are enabled.
set -euo pipefail

ulimit -n 65536 2>/dev/null || true

if [[ "${NORNIR_NET_MOUNTS:-}" == "1" ]]; then
  script="/usr/local/bin/mount-network-shares.sh"
  if [[ ! -f "${script}" ]]; then
    echo "prod-entry: NORNIR_NET_MOUNTS=1 but mount-network-shares.sh not found" >&2
    exit 1
  fi
  bash "${script}"
fi

if [[ $# -gt 0 ]]; then
  exec "$@"
fi
exec bash
