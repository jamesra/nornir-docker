#!/usr/bin/env bash
# Self-hosted Cursor cloud agent worker: prepare /workspace, editable pip installs, agent worker start.
# NORNIR_WORKSPACE_STRATEGY=clone (default): clone or pull into /workspace (empty volume / first run).
# NORNIR_WORKSPACE_STRATEGY=mounted: host bind-mount at /workspace. Empty mount -> clone+submodules (same as clone path).
# Existing .git -> git fetch; optional checkout+pull when NORNIR_SYNC_REMOTE=1.
# Override: docker run ... nornir:cursor-worker -- bash -lc '...'
set -euo pipefail

export GIT_TERMINAL_PROMPT=0

WORKSPACE=/workspace
CLONE_URL="${NORNIR_CLONE_URL:-https://github.com/jamesra/nornir.git}"
CLONE_BRANCH="${NORNIR_CLONE_BRANCH:-dev}"

# Normalize strategy: clone | mounted
_ws_raw="${NORNIR_WORKSPACE_STRATEGY:-clone}"
WORKSPACE_STRATEGY="$(printf '%s' "${_ws_raw}" | tr '[:upper:]' '[:lower:]')"
if [[ "${WORKSPACE_STRATEGY}" != "clone" && "${WORKSPACE_STRATEGY}" != "mounted" ]]; then
  echo "cursor-worker-entry: NORNIR_WORKSPACE_STRATEGY must be 'clone' or 'mounted' (got: ${_ws_raw})" >&2
  exit 1
fi

gh_token() {
  printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"
}

configure_git_auth() {
  local token
  token="$(gh_token)"
  if [[ -n "${token}" ]]; then
    git config --global url."https://x-access-token:${token}@github.com/".insteadOf "https://github.com/"
    git config --global url."https://x-access-token:${token}@github.com/".insteadOf "git@github.com:"
  fi
}

wipe_workspace() {
  mkdir -p "${WORKSPACE}"
  find "${WORKSPACE}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

ensure_repo_clone_strategy() {
  configure_git_auth
  mkdir -p "${WORKSPACE}"

  if [[ "${NORNIR_CLONE_REFRESH:-}" == "1" ]]; then
    wipe_workspace
  fi

  if [[ -d "${WORKSPACE}/.git" ]]; then
    cd "${WORKSPACE}"
    git fetch origin
    git checkout "${CLONE_BRANCH}"
    git pull --ff-only "origin" "${CLONE_BRANCH}" || {
      echo "cursor-worker-entry: git pull --ff-only failed; set NORNIR_CLONE_REFRESH=1 to re-clone." >&2
      exit 1
    }
  else
    wipe_workspace
    local d="${NORNIR_CLONE_DEPTH:-1}"
    if [[ "${d}" == "0" || "${d}" == "full" ]]; then
      git clone -b "${CLONE_BRANCH}" "${CLONE_URL}" "${WORKSPACE}"
    else
      git clone --depth "${d}" -b "${CLONE_BRANCH}" "${CLONE_URL}" "${WORKSPACE}"
    fi
    cd "${WORKSPACE}"
  fi

  git submodule sync --recursive 2>/dev/null || true
  git submodule update --init --recursive
}

prepare_mounted_workspace() {
  configure_git_auth
  mkdir -p "${WORKSPACE}"

  if [[ ! -d "${WORKSPACE}/.git" ]]; then
    ensure_repo_clone_strategy
    return 0
  fi

  cd "${WORKSPACE}"
  git fetch origin

  if [[ "${NORNIR_SYNC_REMOTE:-}" == "1" ]]; then
    git checkout "${CLONE_BRANCH}"
    git pull --ff-only "origin" "${CLONE_BRANCH}" || {
      echo "cursor-worker-entry: NORNIR_SYNC_REMOTE=1 but git pull --ff-only failed." >&2
      exit 1
    }
  fi

  git submodule sync --recursive 2>/dev/null || true
  git submodule update --init --recursive
}

install_editable_from_workspace() {
  local entry="${WORKSPACE}/nornir-docker/cursor-dev-entry.sh"
  local bundled="/usr/local/lib/nornir-docker/cursor-dev-entry.sh"
  if [[ ! -f "${entry}" ]]; then
    if [[ -f "${bundled}" ]]; then
      echo "cursor-worker-entry: using image-bundled cursor-dev-entry.sh (${WORKSPACE}/nornir-docker missing or empty; check nornir-docker submodule / NORNIR_CLONE_DEPTH)." >&2
      entry="${bundled}"
    else
      echo "cursor-worker-entry: missing ${WORKSPACE}/nornir-docker/cursor-dev-entry.sh (expected monorepo root at /workspace)." >&2
      echo "cursor-worker-entry: nornir-docker is a submodule; try NORNIR_CLONE_DEPTH=0 or full, ensure GITHUB_TOKEN can fetch submodules, or fix .gitmodules URLs." >&2
      exit 1
    fi
  fi
  NORNIR_CURSOR_DEV_WORK="${WORKSPACE}" NORNIR_CURSOR_DEV_SETUP_ONLY=1 bash "${entry}"
}

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  echo "cursor-worker-entry: CURSOR_API_KEY is not set. Set it in the environment or use a .env file." >&2
  exit 1
fi

if [[ "${WORKSPACE_STRATEGY}" == "mounted" ]]; then
  prepare_mounted_workspace
else
  ensure_repo_clone_strategy
fi

install_editable_from_workspace

exec agent worker start
