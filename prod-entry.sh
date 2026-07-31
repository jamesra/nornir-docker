#!/usr/bin/env bash
# Production image entry: optional in-container CIFS/NFS (NORNIR_NET_MOUNTS=1), then exec CMD.
# Requires CAP_SYS_ADMIN (+ typically DAC_READ_SEARCH) and apparmor:unconfined when mounts are enabled.
# After successful mounts, drops CAP_SYS_ADMIN before the workload when setpriv/capsh are available.
set -euo pipefail

ulimit -n 65536 2>/dev/null || true

DROPPED_MOUNTS=0
if [[ "${NORNIR_NET_MOUNTS:-}" == "1" ]]; then
  script="/usr/local/bin/mount-network-shares.sh"
  if [[ ! -f "${script}" ]]; then
    echo "prod-entry: NORNIR_NET_MOUNTS=1 but mount-network-shares.sh not found" >&2
    exit 1
  fi
  bash "${script}"
  DROPPED_MOUNTS=1
fi

_drop_helper="/usr/local/bin/drop-sys-admin-after-mounts.sh"
_exec_workload() {
  if [[ "${DROPPED_MOUNTS}" -eq 1 && -f "${_drop_helper}" ]]; then
    # shellcheck source=/dev/null
    source "${_drop_helper}"
    drop_sys_admin_after_mounts -- "$@"
  fi
  exec "$@"
}

if [[ $# -gt 0 ]]; then
  _exec_workload "$@"
fi
_exec_workload bash
