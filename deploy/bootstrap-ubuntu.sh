#!/usr/bin/env bash
# bootstrap-ubuntu.sh - one-time prerequisites for a Nornir/Viking Docker host on Ubuntu (24.04/26.04).
#
# Installs what stack.ps1 needs before any PowerShell can run:
#   git, curl, openssh-server, cifs-utils, ufw
#   Docker Engine + compose plugin (Docker's apt repo; falls back to Ubuntu's docker.io + docker-compose-v2)
#   PowerShell 7 (Microsoft apt repo; falls back to snap, then the GitHub tarball)
#   NVIDIA container toolkit (only with --gpu, or when nvidia-smi is present)
# and prepares /srv/docker (layout root) and /srv/src (git checkouts) owned by the deploy user.
#
# Safe to re-run. It never disables SSH password login unless --harden-ssh is given AND the deploy
# user already has ~/.ssh/authorized_keys (so you cannot lock yourself out).
#
# Usage (as a sudo-capable user, e.g. the account you deploy as):
#   curl -fsSL https://raw.githubusercontent.com/jamesra/nornir-docker/main/deploy/bootstrap-ubuntu.sh -o bootstrap-ubuntu.sh
#   sudo bash bootstrap-ubuntu.sh --user deploy [--gpu] [--open-web] [--harden-ssh]
#
#   --user NAME     deploy user (default: $SUDO_USER)
#   --gpu           install the NVIDIA container toolkit (driver must already be installed: ubuntu-drivers install)
#   --open-web      ufw allow 80/tcp and 443/tcp (the web/proxy host)
#   --harden-ssh    key-only SSH (PasswordAuthentication no, PermitRootLogin no)
#   --root DIR      layout root (default /srv/docker)
set -euo pipefail

DEPLOY_USER="${SUDO_USER:-}"
WANT_GPU=0
OPEN_WEB=0
HARDEN_SSH=0
LAYOUT_ROOT=/srv/docker
SRC_ROOT=/srv/src
PWSH_VERSION="${PWSH_VERSION:-7.4.6}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) DEPLOY_USER="$2"; shift 2 ;;
    --gpu) WANT_GPU=1; shift ;;
    --open-web) OPEN_WEB=1; shift ;;
    --harden-ssh) HARDEN_SSH=1; shift ;;
    --root) LAYOUT_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then echo "run with sudo" >&2; exit 1; fi
if [[ -z "$DEPLOY_USER" ]]; then echo "pass --user <deploy-user>" >&2; exit 1; fi
id "$DEPLOY_USER" >/dev/null 2>&1 || { echo "user $DEPLOY_USER does not exist" >&2; exit 1; }

# shellcheck disable=SC1091
. /etc/os-release
echo "== Ubuntu $VERSION_ID ($VERSION_CODENAME); deploy user: $DEPLOY_USER"
export DEBIAN_FRONTEND=noninteractive

echo "== base packages"
apt-get update -y
apt-get install -y ca-certificates curl gnupg git openssh-server cifs-utils ufw jq

echo "== Docker Engine"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  if curl -fsSL "https://download.docker.com/linux/ubuntu/dists/${VERSION_CODENAME}/Release" -o /dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    echo "   Docker's repo has no '${VERSION_CODENAME}' yet; using Ubuntu packages"
    apt-get install -y docker.io docker-compose-v2 docker-buildx || apt-get install -y docker.io docker-compose-v2
  fi
fi
systemctl enable --now docker
usermod -aG docker "$DEPLOY_USER"
docker compose version

echo "== PowerShell 7"
if ! command -v pwsh >/dev/null 2>&1; then
  ok=0
  deb="/tmp/packages-microsoft-prod.deb"
  if curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -o "$deb"; then
    dpkg -i "$deb" && apt-get update -y && apt-get install -y powershell && ok=1 || true
  fi
  if [[ $ok -eq 0 ]] && command -v snap >/dev/null 2>&1; then
    snap install powershell --classic && ok=1 || true
  fi
  if [[ $ok -eq 0 ]]; then
    arch="x64"; [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    tgz="/tmp/powershell-${PWSH_VERSION}.tar.gz"
    curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arch}.tar.gz" -o "$tgz"
    mkdir -p /opt/microsoft/powershell/7
    tar -xzf "$tgz" -C /opt/microsoft/powershell/7
    chmod +x /opt/microsoft/powershell/7/pwsh
    ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
  fi
fi
pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

if [[ $WANT_GPU -eq 1 ]] || command -v nvidia-smi >/dev/null 2>&1; then
  echo "== NVIDIA container toolkit"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "   WARNING: no NVIDIA driver (nvidia-smi). Install it first: sudo ubuntu-drivers install && reboot" >&2
  fi
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -y
    apt-get install -y nvidia-container-toolkit
  fi
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

echo "== layout folders"
mkdir -p "$LAYOUT_ROOT" "$SRC_ROOT"
chown "$DEPLOY_USER":"$DEPLOY_USER" "$LAYOUT_ROOT" "$SRC_ROOT"

echo "== firewall (ufw)"
ufw allow OpenSSH
if [[ $OPEN_WEB -eq 1 ]]; then ufw allow 80/tcp; ufw allow 443/tcp; fi
ufw --force enable
ufw status
echo "   NOTE: ports published by Docker bypass ufw. stack configs bind internal ports to 127.0.0.1;"
echo "   restrict cross-host ports (e.g. segmentation 40443-40447 from the web host) in the DOCKER-USER chain."

echo "== sshd"
systemctl enable --now ssh
if [[ $HARDEN_SSH -eq 1 ]]; then
  home_dir="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
  if [[ -s "$home_dir/.ssh/authorized_keys" ]]; then
    cat > /etc/ssh/sshd_config.d/60-nornir-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
    sshd -t && systemctl reload ssh
    echo "   key-only SSH enabled"
  else
    echo "   SKIPPED --harden-ssh: $home_dir/.ssh/authorized_keys is empty (add your key first: ssh-copy-id $DEPLOY_USER@<host>)" >&2
  fi
fi

cat <<EOF

Done. Log out and back in (docker group), then as $DEPLOY_USER:
  git clone --recurse-submodules https://github.com/jamesra/nornir.git $SRC_ROOT/nornir
  git clone --recurse-submodules https://github.com/jamesra/Viking.git $SRC_ROOT/Viking     # Viking hosts
  pwsh $SRC_ROOT/nornir/nornir-docker/deploy/Initialize-DockerHost.ps1 -Root $LAYOUT_ROOT -Role <compute|web> -VikingRepoRoot $SRC_ROOT/Viking -SetUserEnv
EOF
