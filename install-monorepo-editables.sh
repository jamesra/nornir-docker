#!/usr/bin/env bash
# Install monorepo Python packages in editable mode without resolving git sibling deps.
# Sibling packages use git URLs in pyproject.toml; --no-deps keeps /workspace sources authoritative.
set -euo pipefail

MONOREPO_ROOT="${NORNIR_MONOREPO_ROOT:-/workspace}"
cd "${MONOREPO_ROOT}"

readonly PACKAGES=(
  nornir-shared
  nornir-pools
  nornir-imageregistration
  dm4
  nornir-buildmanager
)

for pkg in "${PACKAGES[@]}"; do
  if [[ ! -d "./${pkg}" ]]; then
    echo "install-monorepo-editables: missing ./${pkg} under ${MONOREPO_ROOT}" >&2
    exit 1
  fi
  echo "install-monorepo-editables: pip install -e --no-deps ./${pkg}"
  pip install --no-cache-dir --no-deps -e "./${pkg}"
done

echo "install-monorepo-editables: done (${#PACKAGES[@]} packages)"
