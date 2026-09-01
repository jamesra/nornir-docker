#!/usr/bin/env bash
# Prepare /workspace (bind mount or volume): optional clone/update, then editable pip installs
# (same order as nornir-docker/dev/Dockerfile).
# NORNIR_WORKSPACE_STRATEGY=mounted (default): bind-mounted checkout - git fetch only unless NORNIR_SYNC_REMOTE=1.
#   Submodule sync: init missing submodules only; preserves existing checkouts (see submodule-sync.sh).
#   Set NORNIR_SUBMODULE_UPDATE=1 to checkout umbrella-recorded submodule SHAs (after pointer bumps).
# NORNIR_WORKSPACE_STRATEGY=clone: named volume / appliance - clone if empty; refresh branch when .git exists.
# NORNIR_CURSOR_DEV_SETUP_ONLY=1: pip install -e only (used by cursor-worker-entry.sh after git prep).
# NORNIR_NET_MOUNTS=1: apply /etc/nornir-net-mounts/nas-mounts.tsv (CIFS/NFS) via mount-network-shares.sh.
# After successful mounts, CAP_SYS_ADMIN is dropped before the final exec when setpriv/capsh exist.
set -euo pipefail

ulimit -n 65536 2>/dev/null || true

export GIT_TERMINAL_PROMPT=0

NORNIR_NET_MOUNTS_APPLIED=0

apply_network_shares() {
  local script="/usr/local/bin/mount-network-shares.sh"
  if [[ ! -f "${script}" ]]; then
    script="/usr/local/lib/nornir-docker/mount-network-shares.sh"
  fi
  if [[ ! -f "${script}" ]]; then
    script="/workspace/nornir-docker/mount-network-shares.sh"
  fi
  if [[ "${NORNIR_NET_MOUNTS:-}" == "1" ]]; then
    if [[ ! -f "${script}" ]]; then
      echo "cursor-dev-entry: NORNIR_NET_MOUNTS=1 but mount-network-shares.sh not found" >&2
      exit 1
    fi
    bash "${script}"
    NORNIR_NET_MOUNTS_APPLIED=1
  fi
}

exec_after_mounts() {
  local helper="/usr/local/bin/drop-sys-admin-after-mounts.sh"
  if [[ ! -f "${helper}" ]]; then
    helper="/usr/local/lib/nornir-docker/drop-sys-admin-after-mounts.sh"
  fi
  if [[ ! -f "${helper}" ]]; then
    helper="/workspace/nornir-docker/drop-sys-admin-after-mounts.sh"
  fi
  if [[ "${NORNIR_NET_MOUNTS_APPLIED}" -eq 1 && -f "${helper}" ]]; then
    # shellcheck source=/dev/null
    source "${helper}"
    drop_sys_admin_after_mounts -- "$@"
  fi
  exec "$@"
}

install_editables() {
  local script="/usr/local/bin/install-monorepo-editables.sh"
  if [[ ! -f "${script}" ]]; then
    script="/workspace/nornir-docker/install-monorepo-editables.sh"
  fi
  if [[ ! -f "${script}" ]]; then
    echo "cursor-dev-entry: missing install-monorepo-editables.sh" >&2
    exit 1
  fi
  NORNIR_MONOREPO_ROOT=/workspace bash "${script}"
}

sync_home_scripts() {
  local src="/workspace/nornir-buildmanager/scripts"
  local dst="${HOME:-/root}/scripts"
  local f
  local base
  if [[ -d "${src}" ]]; then
    mkdir -p "${dst}"
    # TEM* → extensionless on PATH; keep _nornir_tem_common.sh for source paths.
    rm -f "${dst}"/TEM*.sh
    for f in "${src}"/TEM*.sh; do
      [[ -e "${f}" ]] || continue
      base="$(basename "${f}")"
      cp -f "${f}" "${dst}/${base%.sh}"
      chmod +x "${dst}/${base%.sh}"
    done
    if [[ -f "${src}/_nornir_tem_common.sh" ]]; then
      cp -f "${src}/_nornir_tem_common.sh" "${dst}/"
      chmod +x "${dst}/_nornir_tem_common.sh"
    fi
  fi
  if [[ -d "${dst}" ]]; then
    case ":${PATH}:" in
      *":${dst}:"*) ;;
      *) export PATH="${dst}:${PATH}" ;;
    esac
  fi
}

# Mounts before SETUP_ONLY so worker/dev attach paths also get /storage4 when caps+binds are present.
apply_network_shares

if [[ "${NORNIR_CURSOR_DEV_SETUP_ONLY:-0}" == "1" ]]; then
  install_editables
  sync_home_scripts
  if [[ $# -gt 0 ]]; then
    exec_after_mounts "$@"
  fi
  exit 0
fi

cd /workspace

NORNIR_CLONE_URL="${NORNIR_CLONE_URL:-https://github.com/jamesra/nornir.git}"
NORNIR_CLONE_BRANCH="${NORNIR_CLONE_BRANCH:-dev}"

_ws_raw="${NORNIR_WORKSPACE_STRATEGY:-mounted}"
WORKSPACE_STRATEGY="$(printf '%s' "${_ws_raw}" | tr '[:upper:]' '[:lower:]')"
if [[ "${WORKSPACE_STRATEGY}" != "clone" && "${WORKSPACE_STRATEGY}" != "mounted" ]]; then
  echo "cursor-dev-entry: NORNIR_WORKSPACE_STRATEGY must be 'clone' or 'mounted' (got: ${_ws_raw})" >&2
  exit 1
fi

wipe_workspace() {
  mkdir -p /workspace
  find /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

workspace_nonempty() {
  [[ -n "$(ls -A /workspace 2>/dev/null || true)" ]]
}

source_submodule_sync() {
  local script
  for script in \
    /usr/local/lib/nornir-docker/submodule-sync.sh \
    /workspace/nornir-docker/submodule-sync.sh; do
    if [[ -f "${script}" ]]; then
      # shellcheck source=submodule-sync.sh
      source "${script}"
      return 0
    fi
  done
  echo "cursor-dev-entry: missing submodule-sync.sh" >&2
  exit 1
}

repair_broken_submodule_gitdirs() {
  [[ -d /workspace/.git ]] || return 0
  cd /workspace || return 0
  local path mod_git
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    mod_git=".git/modules/${path}"
    if [[ -f "${path}/.git" ]] && grep -qF "${mod_git}" "${path}/.git" 2>/dev/null; then
      if [[ ! -e "${mod_git}/HEAD" ]]; then
        echo "cursor-dev-entry: repairing broken submodule metadata for ${path}" >&2
        git submodule deinit -f "${path}" 2>/dev/null || true
        rm -rf "${mod_git}" 2>/dev/null || true
      fi
    fi
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
}

clone_shallow_or_full() {
  source_submodule_sync
  _submodule_sync_configure_git
  local d="${NORNIR_CLONE_DEPTH:-1}"
  if [[ "${WORKSPACE_STRATEGY}" == "clone" && "${d}" != "0" && "${d}" != "full" ]]; then
    d="0"
    echo "cursor-dev-entry: cursor-dev-clone uses full clone depth for submodule checkout (NORNIR_CLONE_DEPTH=0)." >&2
  fi
  if [[ "${d}" == "0" || "${d}" == "full" ]]; then
    git clone --recurse-submodules --branch "${NORNIR_CLONE_BRANCH}" "${NORNIR_CLONE_URL}" /workspace
  else
    git clone --depth "${d}" --branch "${NORNIR_CLONE_BRANCH}" "${NORNIR_CLONE_URL}" /workspace
  fi
}

ensure_clone_strategy() {
  if [[ "${NORNIR_CLONE_REFRESH:-}" == "1" ]]; then
    wipe_workspace
  fi

  if [[ -d /workspace/.git ]]; then
    cd /workspace
    repair_broken_submodule_gitdirs
    git fetch --prune origin
    git checkout "${NORNIR_CLONE_BRANCH}"
    git pull --ff-only origin "${NORNIR_CLONE_BRANCH}" || {
      echo "cursor-dev-entry: git pull --ff-only failed; set NORNIR_CLONE_REFRESH=1 to re-clone." >&2
      exit 1
    }
  else
    if workspace_nonempty; then
      echo "ERROR: /workspace is not empty but is not a git repo; refusing to clone into it." >&2
      echo "Either wipe /workspace or set up a repo at /workspace." >&2
      exit 2
    fi
    clone_shallow_or_full
    cd /workspace
  fi

  source_submodule_sync
  submodule_sync_full
}

prepare_mounted_workspace() {
  source_submodule_sync
  if [[ ! -d /workspace/.git ]]; then
    if workspace_nonempty; then
      echo "ERROR: /workspace is not empty but is not a git repo; refusing to clone into it." >&2
      exit 2
    fi
    clone_shallow_or_full
    cd /workspace
    submodule_sync_full
    return 0
  fi

  cd /workspace
  repair_broken_submodule_gitdirs
  git fetch --prune origin

  if [[ "${NORNIR_SYNC_REMOTE:-}" == "1" ]]; then
    git checkout "${NORNIR_CLONE_BRANCH}"
    git pull --ff-only origin "${NORNIR_CLONE_BRANCH}" || {
      echo "cursor-dev-entry: NORNIR_SYNC_REMOTE=1 but git pull --ff-only failed." >&2
      exit 1
    }
  fi

  submodule_sync_mounted
}

if [[ "${WORKSPACE_STRATEGY}" == "clone" ]]; then
  ensure_clone_strategy
else
  prepare_mounted_workspace
fi

install_editables
sync_home_scripts
exec_after_mounts "$@"
