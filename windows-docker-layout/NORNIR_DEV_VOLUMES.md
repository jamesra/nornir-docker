# NAS `/volumes` mount for cursor-dev (machine-local)

Per the **docker-machine-layout** rule, **runtime** Docker config lives under **`D:\Docker\Run\nornir-dev\`** (existing layout folder). Committed **templates** live under `nornir-docker/dev/example.*`.

## One-time setup

### 1. Layout folder (already exists)

```text
D:\Docker\Run\nornir-dev\
```

### 2. Copy or update templates from the repo

| Copy from (repo) | To (machine-local) |
|------------------|-------------------|
| `nornir-docker/dev/example.compose.volumes.override.yaml` | `D:\Docker\Run\nornir-dev\compose.volumes.override.yaml` |
| `nornir-docker/dev/example.nornir-dev.volumes.devcontainer.json` | `D:\Docker\Run\nornir-dev\devcontainer.json` |
| `nornir-docker/dev/example.nornir-dev.volumes.run.env` | merge into `D:\Docker\Run\nornir-dev\.run.nornir-dev.env` |
| `nornir-docker/dev/example.mount-volumes-wsl.sh` | `D:\Docker\Run\nornir-dev\mount-volumes-wsl.sh` |

Set Windows user environment variables (Dev Containers / Compose):

- `NORNIR_MONOREPO_ROOT` — e.g. `D:\src\git\nornir`
- `NORNIR_DOCKER_USER_ROOT` — `D:\Docker` (used by `devcontainer.json` compose paths)

### 3. Mount NAS in WSL

From **WSL Ubuntu** (host, not inside the container):

```bash
bash /mnt/d/Docker/Run/nornir-dev/mount-volumes-wsl.sh
```

Default mount: `/mnt/nornir-volumes` → `\\192.168.0.199\Data\Volumes`

### 4. Set `NORNIR_VOLUMES_HOST`

Add this line to **`nornir-docker/.env`** (default Dev Container reads this file for Compose substitution):

```env
# Docker Desktop + WSL NAS mount (match your distro name; same style as NORNIR_TESTDATA_HOST):
NORNIR_VOLUMES_HOST=\\wsl.localhost\Ubuntu\mnt\nornir-volumes

# Or when running Compose from a WSL shell only:
# NORNIR_VOLUMES_HOST=/mnt/nornir-volumes
```

Also merge into **`D:\Docker\Run\nornir-dev\.run.nornir-dev.env`** when using `docker-run-nornir-dev.ps1`.

**Important:** Rebuilding the **image** does not add `/volumes`. You need this env var plus **Dev Containers: Rebuild Container** (or `docker compose … run`) so Compose applies the bind mount.

The bind is defined in **`compose.cursor-dev.yaml`** (placeholder when unset). The optional **`compose.volumes.override.yaml`** under `D:\Docker\Run\nornir-dev\` is legacy/duplicate for the same mount when using a machine-local second compose file.

## Start container

**Option A — personal devcontainer**

Command palette → **Dev Containers: Open Folder in Container…** →  
`D:\Docker\Run\nornir-dev\devcontainer.json`

**Option B — compose**

`run-cursor-dev.ps1` picks up `D:\Docker\Run\nornir-dev\compose.volumes.override.yaml` automatically when present (requires `NORNIR_DOCKER_USER_ROOT=D:\Docker`).

Or manually:

```powershell
docker compose `
  -f nornir-docker/compose.cursor-dev.yaml `
  -f D:/Docker/Run/nornir-dev/compose.volumes.override.yaml `
  run --rm --gpus all cursor-dev
```

**Option C — `docker-run-nornir-dev.ps1`**

From `D:\Docker\Run\nornir-dev\` with `.run.nornir-dev.env` containing `NORNIR_VOLUMES_HOST`; the script bind-mounts it at `/volumes` (read-write).

## Verify

Inside the new container:

```bash
ls /volumes
```

Use e.g. `/volumes/RC2/TEM` as the volume path in launch configs.
