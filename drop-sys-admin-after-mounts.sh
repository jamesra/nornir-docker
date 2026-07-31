#!/usr/bin/env bash
# Drop CAP_SYS_ADMIN after Path-B mounts succeed, then exec the remaining arguments.
# Usage: drop_sys_admin_after_mounts [--] cmd [args...]
# Prefer setpriv (util-linux); fall back to capsh (libcap2-bin); else warn and exec unchanged.
set -euo pipefail

drop_sys_admin_after_mounts() {
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  if [[ $# -eq 0 ]]; then
    echo "drop_sys_admin_after_mounts: missing command to exec" >&2
    return 1
  fi

  if command -v setpriv >/dev/null 2>&1; then
    echo "drop_sys_admin_after_mounts: dropping CAP_SYS_ADMIN via setpriv" >&2
    # setpriv wants names without the CAP_ prefix (capabilities(7)).
    exec setpriv \
      --bounding-set=-sys_admin \
      --inh-caps=-sys_admin \
      --ambient-caps=-sys_admin \
      -- "$@"
  fi

  if command -v capsh >/dev/null 2>&1; then
    echo "drop_sys_admin_after_mounts: dropping CAP_SYS_ADMIN via capsh" >&2
    # After --, capsh runs a login shell with the remaining args.
    exec capsh --drop=cap_sys_admin -- -c 'exec "$@"' -- "$@"
  fi

  echo "drop_sys_admin_after_mounts: warning: setpriv/capsh not found; retaining CAP_SYS_ADMIN" >&2
  exec "$@"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  drop_sys_admin_after_mounts "$@"
fi
