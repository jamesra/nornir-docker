# Standard `D:\` layout for nornir-cursor-worker

This layout keeps **secrets and env** under a fixed Windows path while the **repo launcher** stays a single file in git (no duplicate copies of `start-cursor-worker.ps1`).

## Symlinks are not automatic

**Git clone and Docker do not create these links.** Run [`Initialize-NornirCursorWorkerLayout.ps1`](Initialize-NornirCursorWorkerLayout.ps1) once (from the repo), or run the manual snippet under [Thin launcher (symlink)](#thin-launcher-symlink) below. Creating symlinks usually needs **Windows Developer Mode** or an **elevated** PowerShell/cmd.

```powershell
& 'D:\src\git\nornir\nornir-docker\windows-docker-layout\Initialize-NornirCursorWorkerLayout.ps1' -MonorepoRoot 'D:\src\git\nornir'
```

Use **`-LayoutRoot 'D:\your\path'`** if you keep the layout somewhere other than the default.

**Folder name:** the documented layout root is **`D:\Docker\Builds\nornir-cursor-worker`** (folder **`Builds`**, plural). If you only created `D:\Docker\Build\...` (singular **Build**), that is a different path; either use `Builds` or pass **`-LayoutRoot`** to the initializer to match your tree.

## Recommended directories

| Path | Purpose |
|------|---------|
| `D:\Docker\Builds\nornir-cursor-worker\` | **Layout root**: `.env.cursor-worker` (copy from `nornir-docker/.env.cursor-worker.example`), optional symlink to the thin launcher below. |
| `D:\Docker\mounted-configs\nornir-cursor-worker\` | **Default parent** for **per-run unique** workspace folders (`nornir-cursor-worker-<timestamp>-<guid>`). Each run bind-mounts an empty folder at `/workspace`; **`start-cursor-worker.ps1` sets `NORNIR_WORKSPACE_STRATEGY=clone`** so the entrypoint clones into it (overrides `mounted` in `.env` if present). |

Optional: set `-WorkspaceRunParent` to a subfolder (e.g. `...\runs`) if you want run folders grouped under a dedicated directory.

## Thin launcher (symlink)

From an elevated PowerShell (symlinks may require admin) or with Developer Mode enabled:

```powershell
$Target = 'D:\src\git\nornir\nornir-docker\windows-docker-layout\start-nornir-cursor-worker.ps1'
$Link   = 'D:\Docker\Builds\nornir-cursor-worker\start-nornir-cursor-worker.ps1'
New-Item -ItemType Directory -Force -Path (Split-Path $Link) | Out-Null
if (Test-Path $Link) { Remove-Item $Link -Force }
New-Item -ItemType SymbolicLink -Path $Link -Target $Target
```

Place **`D:\Docker\Builds\nornir-cursor-worker\.env.cursor-worker`** next to the symlink (same folder as `$PSScriptRoot` for the thin script). Set **`NORNIR_MONOREPO_ROOT`** (User or Machine env) to your clone root, e.g. `D:\src\git\nornir`, or pass **`-RepoRoot`** every time.

## What the thin launcher does

- Calls `nornir-docker/start-cursor-worker.ps1` with **`-LiveMount -UseUniqueWorkspaceFolder`** and **`-WorkspaceRunParent D:\Docker\mounted-configs\nornir-cursor-worker`** (override as needed), which sets **`NORNIR_WORKSPACE_STRATEGY=clone`** for the container.
- Each run creates **`D:\Docker\mounted-configs\nornir-cursor-worker\nornir-cursor-worker-<stamp>-<guid>`**, bind-mounted to **`/workspace`**. The entrypoint **clones** into that empty directory.

## Compose

From the monorepo, you can point compose at a specific env file:

```powershell
$env:NORNIR_CURSOR_WORKER_ENV_FILE = 'D:\Docker\Builds\nornir-cursor-worker\.env.cursor-worker'
docker compose -f nornir-docker/compose.cursor-worker.yaml run --rm nornir-cursor-worker
```

Default remains **`nornir-docker/.env.cursor-worker`** when the variable is unset.
