# Standard `D:\` layout for nornir-cursor-worker



Per **docker-machine-layout**, machine-local Docker state lives under **`D:\Docker`**. Committed templates stay in the repo (`nornir-docker/example.*`).



## One-time initializer



**Git clone and Docker do not create these paths.** Run [`Initialize-NornirCursorWorkerLayout.ps1`](Initialize-NornirCursorWorkerLayout.ps1) once (Developer Mode or elevated shell for symlinks):



```powershell

& 'D:\src\git\nornir\nornir-docker\windows-docker-layout\Initialize-NornirCursorWorkerLayout.ps1' `

  -ScriptsRepoRoot 'D:\src\git\nornir' `

  -DockerUserRoot 'D:\Docker'

```



(`-ScriptsRepoRoot` alias: `-MonorepoRoot`.)



## Directory layout



| Path | Purpose |

|------|---------|

| `D:\Docker\Builds\nornir\` | Shared image **build** env: `build.env`, `.build.nornir-dev-cursor-base.env`, `.build.nornir-cursor-worker.env`; optional `build-nornir-images.ps1` → `docker-build.ps1` |

| `D:\Docker\Builds\nornir-cursor-worker\` | Thin launcher symlink only (`start-nornir-cursor-worker.ps1`) |

| `D:\Docker\Run\nornir-cursor-worker\` | **Run secrets**: `nornir-cursor-worker.run.env` (`CURSOR_API_KEY`, `GITHUB_TOKEN`, clone settings) |

| `D:\Docker\mounted-configs\nornir-cursor-worker\` | Per-run agent clone workspaces (`nornir-cursor-worker-<stamp>-<guid>\`) bind-mounted at `/workspace` |



Set user env:



- `NORNIR_DOCKER_USER_ROOT=D:\Docker`

- `NORNIR_MONOREPO_ROOT=D:\src\git\nornir` (locates host scripts; **not** the agent workspace by default)

- Optional: `NORNIR_CURSOR_WORKER_ENV_FILE=D:\Docker\Run\nornir-cursor-worker\nornir-cursor-worker.run.env`



## Build then run



```powershell

cd D:\Docker\Builds\nornir

.\build-nornir-images.ps1    # or ..\..\..\src\git\nornir\nornir-docker\docker-build.ps1



# Edit run env first:

notepad D:\Docker\Run\nornir-cursor-worker\nornir-cursor-worker.run.env



& D:\Docker\Builds\nornir-cursor-worker\start-nornir-cursor-worker.ps1

```



## What the thin launcher does



- Calls `nornir-docker/start-cursor-worker.ps1` with **`-LiveMount -UseUniqueWorkspaceFolder`**.

- Creates an **empty** folder under `mounted-configs\`, mounts it at `/workspace`, sets **`NORNIR_WORKSPACE_STRATEGY=clone`**; the entrypoint **clones** from GitHub (not your dev monorepo).

- Default run env: `D:\Docker\Run\nornir-cursor-worker\nornir-cursor-worker.run.env`.



## Dev-container mount parity (opt-in)



To give the worker the same `/volumes`, `/nornir-testdata`, etc. as **cursor-dev**, configure [`NORNIR_DEV_VOLUMES.md`](NORNIR_DEV_VOLUMES.md) under `D:\Docker\Run\nornir-dev\` first, then either:



- Set `NORNIR_WORKER_DEV_PARITY_MOUNTS=1` in the worker run env, or

- Pass **`-DevParityMounts`** to `start-cursor-worker.ps1`.



Mount paths are read from `Run/nornir-dev/.run.nornir-dev.env` and `nornir-docker/.env` (not duplicated in the worker run file).



## Compose



```powershell

$env:NORNIR_CURSOR_WORKER_ENV_FILE = 'D:\Docker\Run\nornir-cursor-worker\nornir-cursor-worker.run.env'

docker compose -f nornir-docker/compose.cursor-worker.yaml run --rm nornir-cursor-worker

```



Compose does not include dev parity mounts; use `start-cursor-worker.ps1 -DevParityMounts` for NAS/testdata paths.



## Legacy



Older layouts used `D:\Docker\Builds\nornir-cursor-worker\.env.cursor-worker`; `start-cursor-worker.ps1` still discovers that path as a fallback.


