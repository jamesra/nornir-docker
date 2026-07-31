# In-container CIFS (path B) — machine-local layout

**Preferred shared layout (all roles):** `<NORNIR_DOCKER_USER_ROOT>\Run\nornir-net-mounts\`  
(default root `C:\Docker` when `NORNIR_DOCKER_USER_ROOT` is unset). Used by **`start-nornir-build.ps1`**, cursor-dev net mounts, and worker `-DevParityMounts`.

Legacy programmer-only path `Run\nornir-dev\` still works as a fallback for the same net-mounts files. Migrate by copying `net-mounts\`, `secrets\net-creds\`, and pointing env at the new tree (see `Initialize-NornirBuildAppliance.ps1`).

**Primary NAS path:** in-container CIFS/NFS from `nas-mounts.tsv` (SMB direct). Host/WSL bind-mounts of the NAS share are not used.

Committed **templates** live under `nornir-docker/dev/example.*` and `nornir-docker/example.nornir-net-mounts.run.env`.

---

## One-time setup

### 1. Layout folder

```text
C:\Docker\Run\nornir-net-mounts\
  net-mounts\nas-mounts.tsv
  secrets\net-creds\*.cred
  .run.nornir-net-mounts.env
  compose.net-mounts.override.yaml   # for cursor-dev / compose only
```

### 2. Copy templates from the repo

| Copy from (repo) | To (machine-local) |
|------------------|-------------------|
| `nornir-docker/dev/example.compose.net-mounts.override.yaml` | `C:\Docker\Run\nornir-net-mounts\compose.net-mounts.override.yaml` (or `Run\nornir-dev\…`) |
| `nornir-docker/dev/example.nas-mounts.tsv` | `C:\Docker\Run\nornir-net-mounts\net-mounts\nas-mounts.tsv` |
| `nornir-docker/example.nornir-net-mounts.run.env` | `C:\Docker\Run\nornir-net-mounts\.run.nornir-net-mounts.env` |
| `nornir-docker/dev/example.modules-load.net-shares.conf` | WSL `/etc/modules-load.d/net-shares.conf` |

Put CIFS credentials in a secure host folder (e.g. `C:\Users\<you>\.nornir\secrets\net-creds\storage4.cred`) with a tight ACL. Point `NORNIR_NET_CREDS_DIR_HOST` at that folder. Do not commit secrets.

Windows user env:

- `NORNIR_MONOREPO_ROOT` — e.g. `D:\src\git\nornir`
- `NORNIR_DOCKER_USER_ROOT` — `C:\Docker` (or `D:\Docker`)

### 3. Load CIFS on the WSL2 host kernel

Containers share the WSL2 kernel. After copying `modules-load.net-shares.conf` into the distro:

```bash
# In WSL, with systemd=true in /etc/wsl.conf:
sudo cp /mnt/c/Docker/Run/nornir-net-mounts/modules-load.net-shares.conf /etc/modules-load.d/net-shares.conf
sudo modprobe cifs
grep cifs /proc/filesystems
```

### 4. Env vars

In **`.run.nornir-net-mounts.env`** (and `nornir-docker/.env` for Compose substitution when using cursor-dev):

```env
# Prefer Windows paths for PowerShell / Docker Desktop (no WSL UNC required for config binds)
NORNIR_NET_MOUNTS_DIR_HOST=C:\Docker\Run\nornir-net-mounts\net-mounts
NORNIR_NET_CREDS_DIR_HOST=C:\Users\<you>\.nornir\secrets\net-creds
```

Both keys must be set when overriding the default tree under `Run\nornir-net-mounts\`.

### 5. Rebuild the image (once)

The image needs `cifs-utils`, `mount-network-shares.sh`, and `drop-sys-admin-after-mounts.sh`:

```powershell
# from monorepo root
docker build -f nornir-docker/prod/Dockerfile -t nornir:prod .
# or for cursor-dev:
docker build -f nornir-docker/dev/Dockerfile --build-arg INSTALL_MONOREPO_EDITABLES=0 -t nornir:dev-cursor-base .
```

---

## Start container

**Build appliance**

```powershell
.\nornir-docker\start-nornir-build.ps1
```

Grants `CAP_SYS_ADMIN` for the mount phase; entrypoint drops it after mounts succeed when `setpriv`/`capsh` are available.

**cursor-dev**

With `NORNIR_DOCKER_USER_ROOT` set, `run-cursor-dev.ps1` auto-adds `compose.net-mounts.override.yaml` from `Run\nornir-net-mounts\` (or legacy `Run\nornir-dev\`) when present.

```powershell
docker compose `
  -f nornir-docker/compose.cursor-dev.yaml `
  -f C:/Docker/Run/nornir-net-mounts/compose.net-mounts.override.yaml `
  run --rm --gpus all cursor-dev
```

---

## Verify

Inside the container:

```bash
echo "$NORNIR_NET_MOUNTS"          # expect 1
ls /etc/nornir-net-mounts
ls /run/secrets/net-creds
findmnt -no FSTYPE,SOURCE /storage4
# expect: cifs  //server/share
ls /storage4 | head
# After entry: CAP_SYS_ADMIN should be cleared when setpriv/capsh worked
capsh --print 2>/dev/null | head -5 || true
```

Use e.g. `/storage4/RC2/TEM` in launch configs.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `/storage4` empty | Override / `NORNIR_NET_MOUNTS` not applied; check compose `-f` list and rebuild |
| `NORNIR_NET_MOUNTS` unset | Override missing or wrong path |
| `mount: ... Operation not permitted` | Missing `SYS_ADMIN` (override / launcher not used) |
| `mount error(2)` for cifs | `cifs` not in `/proc/filesystems` on WSL host |
| `mount error(13): Permission denied` | Bad/missing `.cred`, wrong password, or share ACL. Windows bind mounts often show `0777`; current `mount-network-shares.sh` copies `*.cred` to `/run/nornir-cifs-creds` with `0600` (rebuild image). Match `credentials=/run/secrets/net-creds/<name>.cred` in `nas-mounts.tsv` |
| Remount fails after shell starts | Expected — `CAP_SYS_ADMIN` was dropped; restart the container to remount |
