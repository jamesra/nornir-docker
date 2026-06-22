#!/usr/bin/env bash
# Prepare /workspace (bind mount or volume): optional clone/update, then editable pip installs
# (same order as nornir-docker/dev/Dockerfile).
# NORNIR_WORKSPACE_STRATEGY=mounted (default): bind-mounted checkout - git fetch only unless NORNIR_SYNC_REMOTE=1.
# NORNIR_WORKSPACE_STRATEGY=clone: named volume / appliance - clone if empty; refresh branch when .git exists.
# NORNIR_CURSOR_DEV_SETUP_ONLY=1: pip install -e only (used by cursor-worker-entry.sh after git prep).
set -euo pipefail

export GIT_TERMINAL_PROMPT=0

install_editables() {
  local script="/usr/local/bin/install-monorepo-editables.sh"
  if [[ ! -x "${script}" ]]; then
    script="/workspace/nornir-docker/install-monorepo-editables.sh"
  fi
  if [[ ! -f "${script}" ]]; then
    echo "cursor-dev-entry: missing install-monorepo-editables.sh" >&2
    exit 1
  fi
  NORNIR_MONOREPO_ROOT=/workspace bash "${script}"
}

if [[ "${NORNIR_CURSOR_DEV_SETUP_ONLY:-0}" == "1" ]]; then
  install_editables
  if [[ $# -gt 0 ]]; then
    exec "$@"
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

clone_shallow_or_full() {
  local d="${NORNIR_CLONE_DEPTH:-1}"
  if [[ "${d}" == "0" || "${d}" == "full" ]]; then
    git clone --branch "${NORNIR_CLONE_BRANCH}" "${NORNIR_CLONE_URL}" /workspace
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

  git submodule sync --recursive 2>/dev/null || true
  git submodule update --init --recursive 2>/dev/null || true
}

prepare_mounted_workspace() {
  if [[ ! -d /workspace/.git ]]; then
    if workspace_nonempty; then
      echo "ERROR: /workspace is not empty but is not a git repo; refusing to clone into it." >&2
      exit 2
    fi
    clone_shallow_or_full
    cd /workspace
    git submodule sync --recursive 2>/dev/null || true
    git submodule update --init --recursive 2>/dev/null || true
    return 0
  fi

  cd /workspace
  git fetch --prune origin

  if [[ "${NORNIR_SYNC_REMOTE:-}" == "1" ]]; then
    git checkout "${NORNIR_CLONE_BRANCH}"
    git pull --ff-only origin "${NORNIR_CLONE_BRANCH}" || {
      echo "cursor-dev-entry: NORNIR_SYNC_REMOTE=1 but git pull --ff-only failed." >&2
      exit 1
    }
  fi

  git submodule sync --recursive 2>/dev/null || true
  git submodule update --init --recursive 2>/dev/null || true
}

if [[ "${WORKSPACE_STRATEGY}" == "clone" ]]; then
  ensure_clone_strategy
else
  prepare_mounted_workspace
fi

install_editables
exec "$@"
