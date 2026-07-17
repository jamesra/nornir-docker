# NAS volumes and in-container CIFS (machine-local)

**Preferred shared layout (all roles):** `<NORNIR_DOCKER_USER_ROOT>\Run\nornir-net-mounts\`  
(default root `C:\Docker` when `NORNIR_DOCKER_USER_ROOT` is unset). Used by **`start-nornir-build.ps1`**, cursor-dev net mounts, and worker `-DevParityMounts`.

Legacy programmer-only path `Run\nornir-dev\` still works as a fallback. Migrate by copying `net-mounts\`, `secrets\net-creds\`, and pointing env at the new tree (see `Initialize-NornirBuildAppliance.ps1`).

Committed **templates** live under `nornir-docker/dev/example.*` and `nornir-docker/example.nornir-net-mounts.run.env`.

There are **two** ways to see NAS data in the container:

| Path | Mechanism | Speed | Env / files |
|------|-----------|-------|-------------|
| `/volumes` | Bind-mount a **WSL host** mount (`NORNIR_VOLUMES_HOST`) | Often slow (9p/drvfs) | `mount-volumes-wsl.sh` + `NORNIR_VOLUMES_HOST` |
| `/storage4` | **In-container CIFS** from `nas-mounts.tsv` | Fast (SMB direct) | `compose.net-mounts.override.yaml` + `NORNIR_NET_MOUNTS_*` |

Compose also bind-mounts `NORNIR_VOLUMES_HOST` at `/storage4` as a legacy alias of `/volumes`. When CIFS is enabled, `mount-network-shares.sh` mounts the real share **over** that bind so `/storage4` becomes native CIFS.

---

## One-time setup

### 1. Layout folder

```text
D:\Docker\Run\nornir-dev\
```

### 2. Copy templates from the repo

| Copy from (repo) | To (machine-local) |
|------------------|-------------------|
| `nornir-docker/dev/example.compose.net-mounts.override.yaml` | `D:\Docker\Run\nornir-dev\compose.net-mounts.override.yaml` |
| `nornir-docker/dev/example.nas-mounts.tsv` | `D:\Docker\Run\nornir-dev\net-mounts\nas-mounts.tsv` |
| `nornir-docker/dev/example.nornir-dev.net-mounts.devcontainer.json` | `D:\Docker\Run\nornir-dev\devcontainer.json` |
| `nornir-docker/dev/example.mount-volumes-wsl.sh` | `D:\Docker\Run\nornir-dev\mount-volumes-wsl.sh` |
| `nornir-docker/dev/example.modules-load.net-shares.conf` (if present) or `Run\...\modules-load.net-shares.conf` | WSL `/etc/modules-load.d/net-shares.conf` |

Put CIFS credentials in **`D:\Docker\Run\nornir-dev\secrets\net-creds\storage4.cred`** (`chmod 600` / tight Windows ACL). Do not commit them.

Windows user env (Dev Containers):

- `NORNIR_MONOREPO_ROOT` — e.g. `D:\src\git\nornir`
- `NORNIR_DOCKER_USER_ROOT` — `D:\Docker`

### 3. Load CIFS on the WSL2 host kernel

Containers share the WSL2 kernel. After copying `modules-load.net-shares.conf` into the distro:

```bash
# In WSL, with systemd=true in /etc/wsl.conf:
sudo cp /mnt/d/Docker/Run/nornir-dev/modules-load.net-shares.conf /etc/modules-load.d/net-shares.conf
sudo modprobe cifs
grep cifs /proc/filesystems
```

### 4. Env vars for Compose

Add to **`nornir-docker/.env`** (Compose substitution for the override) **and** merge into **`D:\Docker\Run\nornir-dev\.run.nornir-dev.env`**:

```env
NORNIR_NET_MOUNTS_DIR_HOST=\\wsl.localhost\Ubuntu\mnt\d\Docker\Run\nornir-dev\net-mounts
NORNIR_NET_CREDS_DIR_HOST=\\wsl.localhost\Ubuntu\mnt\d\Docker\Run\nornir-dev\secrets\net-creds
```

(WSL-only Compose can use `/mnt/d/Docker/Run/nornir-dev/...` instead.)

Optional slow bind for `/volumes`:

```env
NORNIR_VOLUMES_HOST=\\wsl.localhost\Ubuntu\mnt\nornir-volumes
```

### 5. Rebuild the image (once)

The image needs `cifs-utils` and `/usr/local/bin/mount-network-shares.sh`:

```powershell
# from monorepo root
docker build -f nornir-docker/dev/Dockerfile --build-arg INSTALL_MONOREPO_EDITABLES=0 -t nornir:dev-cursor-base .
```

---

## Start container (fast `/storage4`)

**Option A — Dev Container**

Command palette → **Dev Containers: Open Folder in Container…** →  
`D:\Docker\Run\nornir-dev\devcontainer.json`  
(or Rebuild Container after changing compose/env)

**Option B — `run-cursor-dev.ps1`**

With `NORNIR_DOCKER_USER_ROOT=D:\Docker`, the script auto-adds  
`D:\Docker\Run\nornir-dev\compose.net-mounts.override.yaml` when that file exists.

**Option C — manual compose**

```powershell
docker compose `
  -f nornir-docker/compose.cursor-dev.yaml `
  -f D:/Docker/Run/nornir-dev/compose.net-mounts.override.yaml `
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
# expect: cifs  //192.168.0.199/Data/Volumes
ls /storage4 | head
```

Use e.g. `/storage4/RC2/TEM` (or `/volumes/...` for the slow bind) in launch configs.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `/storage4` is empty / placeholder | Override not applied; check compose `-f` list and rebuild Dev Container |
| `NORNIR_NET_MOUNTS` unset | Override missing or wrong path in `devcontainer.json` |
| `mount: ... Operation not permitted` | Missing `SYS_ADMIN` (override not used) |
| `mount error(2): No such file or directory` for cifs | `cifs` not in `/proc/filesystems` on WSL host |
| `mount error(13): Permission denied` | Bad/missing `.cred` or world-readable credentials file |
| Still `9p` / `drvfs` on `/storage4` | Entry script not run / old image without `mount-network-shares.sh` — rebuild image |
