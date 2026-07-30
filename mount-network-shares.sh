#!/usr/bin/env bash
# Apply in-container CIFS/NFS mounts from /etc/nornir-net-mounts/nas-mounts.tsv.
# Enabled when NORNIR_NET_MOUNTS=1 (compose.net-mounts.override.yaml / -DevParityMounts).
# Requires CAP_SYS_ADMIN (+ typically DAC_READ_SEARCH) and cifs/nfsv4 on the shared WSL2 kernel.
set -euo pipefail

if [[ "${NORNIR_NET_MOUNTS:-}" != "1" ]]; then
  exit 0
fi

MANIFEST="${NORNIR_NET_MOUNTS_MANIFEST:-/etc/nornir-net-mounts/nas-mounts.tsv}"
if [[ ! -f "${MANIFEST}" ]]; then
  echo "mount-network-shares: NORNIR_NET_MOUNTS=1 but manifest missing: ${MANIFEST}" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "mount-network-shares: must run as root to call mount(2) (got uid=$(id -u))" >&2
  exit 1
fi

# mount.cifs(8) rejects credential files that are group/world-readable. Bind mounts from
# Windows hosts often appear as 0777 inside the container; copy to a root-only dir with 0600.
NET_CREDS_SRC="${NORNIR_NET_CREDS_SRC:-/run/secrets/net-creds}"
NET_CREDS_SECURE="${NORNIR_NET_CREDS_SECURE:-/run/nornir-cifs-creds}"
prepare_secure_credentials() {
  if [[ ! -d "${NET_CREDS_SRC}" ]]; then
    echo "mount-network-shares: credentials dir missing: ${NET_CREDS_SRC}" >&2
    return 1
  fi
  mkdir -p "${NET_CREDS_SECURE}"
  chmod 700 "${NET_CREDS_SECURE}"
  local copied=0
  shopt -s nullglob
  for cred in "${NET_CREDS_SRC}"/*.cred; do
    local base
    base="$(basename "${cred}")"
    sed 's/\r$//' "${cred}" > "${NET_CREDS_SECURE}/${base}"
    chmod 600 "${NET_CREDS_SECURE}/${base}"
    copied=1
  done
  shopt -u nullglob
  if [[ "${copied}" -eq 0 ]]; then
    echo "mount-network-shares: no *.cred files under ${NET_CREDS_SRC}" >&2
    return 1
  fi
  return 0
}

rewrite_credentials_path() {
  local opts="$1"
  if [[ "${opts}" == *"credentials=${NET_CREDS_SRC}/"* ]]; then
    opts="${opts//credentials=${NET_CREDS_SRC}\//credentials=${NET_CREDS_SECURE}/}"
  fi
  printf '%s' "${opts}"
}

diagnose_mount_failure() {
  local source="$1"
  local target="$2"
  local opts="$3"
  local cred_path=""
  if [[ "${opts}" =~ credentials=([^,]+) ]]; then
    cred_path="${BASH_REMATCH[1]}"
  fi
  echo "mount-network-shares: diagnose ${source} -> ${target}" >&2
  if [[ -n "${cred_path}" ]]; then
    if [[ -f "${cred_path}" ]]; then
      ls -la "${cred_path}" >&2 || true
      if [[ -r "${cred_path}" ]] && [[ "$(stat -c '%a' "${cred_path}" 2>/dev/null || echo '?')" != "600" ]]; then
        echo "mount-network-shares: credential file must be mode 0600 for mount.cifs (Windows bind mounts often need the secure copy under ${NET_CREDS_SECURE})" >&2
      fi
    else
      echo "mount-network-shares: credentials file not found: ${cred_path}" >&2
      echo "mount-network-shares: expected basename to match a file in ${NET_CREDS_SRC} (referenced from nas-mounts.tsv)" >&2
    fi
  fi
  echo "mount-network-shares: check username/password/domain in .cred, SMB version (vers=), and share ACLs on the server" >&2
}

if ! prepare_secure_credentials; then
  exit 1
fi

uid_opt="uid=$(id -u)"
gid_opt="gid=$(id -g)"
# Prefer the container's primary user if running as root but a login user exists.
if [[ -n "${SUDO_UID:-}" ]]; then
  uid_opt="uid=${SUDO_UID}"
  gid_opt="gid=${SUDO_GID:-${SUDO_UID}}"
fi

mounted_any=0
while IFS=$'\t' read -r fstype source target options || [[ -n "${fstype:-}" ]]; do
  # Strip CR from Windows-edited TSV lines.
  fstype="${fstype%$'\r'}"
  source="${source%$'\r'}"
  target="${target%$'\r'}"
  options="${options%$'\r'}"

  [[ -z "${fstype}" || "${fstype}" =~ ^# ]] && continue
  if [[ -z "${source}" || -z "${target}" ]]; then
    echo "mount-network-shares: skipping incomplete row (fstype=${fstype})" >&2
    continue
  fi

  if findmnt -n "${target}" >/dev/null 2>&1; then
    existing_fstype="$(findmnt -no FSTYPE "${target}" 2>/dev/null || true)"
    existing_source="$(findmnt -no SOURCE "${target}" 2>/dev/null || true)"
    # Idempotent when the desired share is already mounted. If Docker already bind-mounted
    # a slow host path (9p/drvfs/overlay) at the same target, mount CIFS/NFS over it.
    if [[ "${existing_fstype}" == "${fstype}" ]]; then
      echo "mount-network-shares: already mounted ${target} (${existing_fstype} ${existing_source})"
      mounted_any=1
      continue
    fi
    echo "mount-network-shares: ${target} currently ${existing_fstype} (${existing_source}); mounting ${fstype} over it"
  fi

  mkdir -p "${target}"

  opts="${options:-}"
  opts="$(rewrite_credentials_path "${opts}")"
  if [[ -n "${opts}" ]]; then
    opts="${opts},${uid_opt},${gid_opt}"
  else
    opts="${uid_opt},${gid_opt}"
  fi

  echo "mount-network-shares: mount -t ${fstype} ${source} ${target}"
  if ! mount -t "${fstype}" "${source}" "${target}" -o "${opts}"; then
    echo "mount-network-shares: FAILED mounting ${source} -> ${target}" >&2
    diagnose_mount_failure "${source}" "${target}" "${opts}"
    echo "mount-network-shares: check CAP_SYS_ADMIN, cifs/nfs modules (grep cifs /proc/filesystems), and credentials under ${NET_CREDS_SRC}" >&2
    exit 1
  fi
  mounted_any=1
  findmnt -no FSTYPE,SOURCE,TARGET "${target}" || true
done < "${MANIFEST}"

if [[ "${mounted_any}" -eq 0 ]]; then
  echo "mount-network-shares: no mount rows in ${MANIFEST} (only comments/blank?)" >&2
fi
