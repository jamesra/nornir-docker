#!/usr/bin/env bash
# Shared submodule sync for cursor-dev and cursor-worker entry scripts.
# Sourced, not executed directly.
#
# Mounted workspace (bind-mount of the host checkout):
#   - Default: init missing submodules only; do not move existing checkouts.
#   - Warn when a submodule is ahead of the umbrella pointer (+ in git submodule status).
#   - NORNIR_SUBMODULE_UPDATE=1: full update --init --recursive (checkout recorded SHAs).
#
# Clone / first-time empty workspace:
#   - Always use submodule_sync_full (umbrella pointers are authoritative).

_submodule_sync_configure_git() {
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "${token}" ]]; then
    git config --global url."https://x-access-token:${token}@github.com/".insteadOf "https://github.com/"
    git config --global url."https://x-access-token:${token}@github.com/".insteadOf "git@github.com:"
  else
    git config --global url."https://github.com/".insteadOf "git@github.com:" 2>/dev/null || true
  fi
}

submodule_sync_full() {
  _submodule_sync_configure_git
  git submodule sync --recursive 2>/dev/null || true
  if ! git submodule update --init --recursive 2>/dev/null; then
    echo "nornir-docker: warning: submodule update had errors (private repos may need GITHUB_TOKEN in the container env)." >&2
  fi
}

submodule_sync_mounted() {
  _submodule_sync_configure_git
  git submodule sync --recursive 2>/dev/null || true
  git submodule init --recursive 2>/dev/null || true

  if [[ "${NORNIR_SUBMODULE_UPDATE:-}" == "1" ]]; then
    echo "nornir-docker: NORNIR_SUBMODULE_UPDATE=1 — checking out umbrella-recorded submodule pointers." >&2
    if ! git submodule update --init --recursive 2>/dev/null; then
      echo "nornir-docker: warning: submodule update had errors (private repos may need GITHUB_TOKEN in the container env)." >&2
    fi
    return 0
  fi

  local had_ahead=0
  local line path
  while IFS= read -r line; do
    [[ "${line}" == +* ]] || continue
    had_ahead=1
    path="$(printf '%s\n' "${line#+}" | awk '{print $1}')"
    [[ -n "${path}" ]] || continue
    echo "nornir-docker: submodule checkout ahead of umbrella pointer: ${path}" >&2
  done < <(git submodule status 2>/dev/null || true)

  if [[ "${had_ahead}" -eq 1 ]]; then
    echo "nornir-docker: skipping submodule update to preserve local commits. Commit in each submodule, bump the umbrella pointer, then set NORNIR_SUBMODULE_UPDATE=1 on recreate if checkouts must match recorded SHAs." >&2
  fi

  while IFS= read -r line; do
    [[ "${line}" == -* ]] || continue
    path="$(printf '%s\n' "${line#-}" | awk '{print $1}')"
    [[ -n "${path}" ]] || continue
    echo "nornir-docker: initializing missing submodule ${path}" >&2
    if ! git submodule update --init "${path}" 2>/dev/null; then
      echo "nornir-docker: warning: failed to init submodule ${path} (private repos may need GITHUB_TOKEN)." >&2
    fi
  done < <(git submodule status 2>/dev/null || true)
}
