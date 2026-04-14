# nornir-docker

Docker images for the **headless** Nornir stack on **Python 3.14** (no Pyre). Use **`venv/pyre314` on the host** for the PyQt-based Pyre UI.

## Documentation

- **Full manual (umbrella):** [https://nornir.github.io/](https://nornir.github.io/)
- **Related overview:** [Other packages](https://nornir.github.io/packages/other_packages.html)

| Image tag    | Dockerfile                         | Notes                          |
|-------------|-------------------------------------|--------------------------------|
| `nornir:dev`   | [dev/Dockerfile](dev/Dockerfile)   | **CuPy** (`cupy-cuda13x` by default) + `pytest`; use `--gpus all` / `nd-build -Gpu` when you want the GPU |
| `nornir:prod`  | [prod/Dockerfile](prod/Dockerfile)  | **CPU-only** production (`INSTALL_CUPY=0`, default) |
| `nornir:cupy`  | [prod/Dockerfile](prod/Dockerfile)  | **Production + CuPy** — same file with `--build-arg INSTALL_CUPY=1` |
| `nornir:dev-cursor-base` | [dev/Dockerfile](dev/Dockerfile) with `INSTALL_MONOREPO_EDITABLES=0` | **CuPy** + `pytest` + venv **without** baking monorepo under `/opt/nornir`; base for **`nornir:cursor-worker`** |
| `nornir:cursor-worker` | [Dockerfile.cursor-worker](Dockerfile.cursor-worker) | **`nornir:dev-cursor-base` + Cursor lab agent CLI**; Nornir packages come from **`/workspace`** via [cursor-dev-entry.sh](cursor-dev-entry.sh) (see workspace strategy below) |

Packages baked into **`nornir:dev`**, **`nornir:prod`**, and **`nornir:cupy`** (from the monorepo at build time): `nornir_shared`, `nornir_pools`, `nornir_imageregistration`, `dm4`, `nornir_buildmanager`. **`nornir:cursor-worker`** does **not** bake those; it installs editables from `/workspace` at container start.

## Monorepo version and package map

- **[../VERSION](../VERSION)** — Single-line **Nornir monorepo release id** (e.g. `1.7.0`). Release tags use `v` + that value (e.g. `v1.7.0`).
- **[../release/package-versions.yaml](../release/package-versions.yaml)** — Bill of materials: each **distribution** version and whether it is included in headless Docker (`docker: true` / `false`).
- **[../release/README.md](../release/README.md)** — Release checklist and **`python release/verify_package_versions.py`** (requires `pip install pyyaml`).

## Build (from monorepo root)

**Recommended (OCI labels + BOM JSON on images):** run [`docker-build.ps1`](docker-build.ps1) or [`build.cmd`](build.cmd) from `nornir-docker`. This reads `VERSION`, `git rev-parse HEAD`, UTC build time, and passes **base64(minified JSON)** of docker-included packages from `release/package-versions.yaml` as `PACKAGE_VERSIONS_JSON_B64` (needs **PyYAML** on the host: `pip install pyyaml`).

Manual `docker build` (defaults use `0.0.0-dev` / `unknown` / `{}` for labels unless you pass args):

```bash
docker build -f nornir-docker/dev/Dockerfile -t nornir:dev .
docker build -f nornir-docker/prod/Dockerfile -t nornir:prod .
docker build -f nornir-docker/prod/Dockerfile --build-arg INSTALL_CUPY=1 -t nornir:cupy .
```

Override the CuPy wheel (default `cupy-cuda13x`) for **dev** or **production + CuPy**:

```bash
docker build -f nornir-docker/dev/Dockerfile --build-arg CUPY_PACKAGE=cupy-cuda12x -t nornir:dev .
docker build -f nornir-docker/prod/Dockerfile --build-arg INSTALL_CUPY=1 --build-arg CUPY_PACKAGE=cupy-cuda12x -t nornir:cupy .
```

### OCI image labels

Images declare [OCI annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md), including `org.opencontainers.image.version` (monorepo `VERSION`), `org.opencontainers.image.revision` (git SHA), `org.opencontainers.image.source`, `org.opencontainers.image.created`, `org.nornir.variant` (`dev` / `prod` / `prod-cupy`), and `org.nornir.package_versions.json.base64` (base64-encoded minified JSON map of docker-included packages; base64 avoids shell quoting issues on Windows).

Inspect (PowerShell):

```powershell
docker image inspect nornir:dev --format '{{json .Config.Labels}}'
```

Decode the BOM JSON (PowerShell):

```powershell
$b64 = (docker image inspect nornir:dev --format '{{index .Config.Labels "org.nornir.package_versions.json.base64"}}')
[System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
```

Compose:

```bash
docker compose -f nornir-docker/compose.yaml build
```

You can set `NORNIR_RELEASE`, `SOURCE_REVISION`, and `BUILD_DATE` in the environment before `compose build`. Compose does not pass `PACKAGE_VERSIONS_JSON_B64`; the BOM label is empty unless you extend the compose file. Use **docker-build.ps1** for a populated BOM label without editing compose.

The `nornir-prod` service uses `prod/Dockerfile` with default `INSTALL_CUPY=0`. The `nornir-cupy` service sets `INSTALL_CUPY=1` and `CUPY_PACKAGE`.

## `nd-build` vs `nornir-build`

| Command        | Where it runs |
|----------------|---------------|
| `nornir-build` | Local install / venv on the host |
| `nd-build`     | Same CLI **inside** Docker; current directory is mounted at `/work` |

Default Docker image is **`nornir:dev`** (includes CuPy). Use **`NORNIR_DOCKER_IMAGE=nornir:prod`** when you want a **CPU-only** container (no CuPy). For GPU acceleration, keep `nornir:dev` or use `nornir:cupy` and pass GPUs (see below).

Host scripts (not on `PATH` unless you add them): [`nd-build.ps1`](nd-build.ps1), [`nd-build.cmd`](nd-build.cmd), [`nd-build.sh`](nd-build.sh).

Examples:

```powershell
cd D:\path\to\your\volume
D:\src\git\nornir\nornir-docker\nd-build.ps1 -- --help
```

GPU (works with `nornir:dev` or `nornir:cupy`; requires [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)):

```powershell
.\nornir-docker\nd-build.ps1 -Gpu -- --help
```

Or explicitly use the production CuPy image:

```powershell
$env:NORNIR_DOCKER_IMAGE = 'nornir:cupy'
.\nornir-docker\nd-build.ps1 -Gpu -- --help
```

Environment:

- **`NORNIR_DOCKER_IMAGE`** — default `nornir:dev` (CuPy + pytest); set to `nornir:prod` for CPU-only production
- **`NORNIR_DOCKER_GPU=1`** — same as `-Gpu` (PowerShell) / use `--gpu` as first arg in `nd-build.sh`
- **`NORNIR_DOCKER_EXTRA_ARGS`** — optional extra `docker run` tokens (space-separated; avoid spaces inside paths)

## Constraints / pyre314 alignment

[`constraints-headless.txt`](constraints-headless.txt) uses **exact pins** for most pure-Python deps, **minimum versions** (`>=`) for the scientific stack, and **`pydantic>=2.12`** plus **`typing_extensions>=4.14`** so pip selects **prebuilt `pydantic-core` wheels for cp314** (older `pydantic` / `typing_extensions` combinations can force a Rust source build that fails on 3.14). Refresh versions when your host `pyre314` environment changes.

## GPU runtime

Use **`nd-build -Gpu`** / **`NORNIR_DOCKER_GPU=1`** or `docker run --gpus all` so the container can see NVIDIA devices. Installing CuPy in the image does not require a GPU at build time; without `--gpus all`, GPU code paths may not run.

## Compose alternative to `nd-build`

```bash
docker compose -f nornir-docker/compose.yaml run --rm -v "$PWD:/work" -w /work nornir nornir-build --help
```

Add `--gpus all` when you want the GPU with the dev image. For CPU-only production, use service `nornir-prod` instead of `nornir`.

## Cursor / local agent dev shell

[`compose.cursor-dev.yaml`](compose.cursor-dev.yaml) defines a **`cursor-dev`** service for a **local** Docker shell that matches the layout used in [`.cursor/environment.json`](../.cursor/environment.json): monorepo at **`/work`**, read-only test input at **`/nornir-testdata`**, and **`TESTINPUTPATH` / `TESTOUTPUTPATH`** set the same way as in that file. This is for **manual** `docker compose run` workflows; the in-IDE Cursor Agent still uses the **host** terminal unless you adopt Dev Containers or Remote.

On start, [`cursor-dev-entry.sh`](cursor-dev-entry.sh) reinstalls editable packages from **`/work`** in the same order as [dev/Dockerfile](dev/Dockerfile), so edits on the host are what Python imports (the image alone still points editable installs at **`/opt/nornir`** from build time).

**Build** the dev image (from monorepo root):

```bash
docker compose -f nornir-docker/compose.cursor-dev.yaml build nornir
```

**Run** an interactive shell:

```bash
docker compose -f nornir-docker/compose.cursor-dev.yaml run --rm cursor-dev
```

**GPU** (optional; requires [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)):

```bash
docker compose -f nornir-docker/compose.cursor-dev.yaml run --rm --gpus all cursor-dev
```

**Test data host path:** by default the compose file bind-mounts **`D:/nornir-testdata`** → `/nornir-testdata` read-only. Override with **`NORNIR_TESTDATA_HOST`** (see [`.env.cursor-dev.example`](.env.cursor-dev.example)). Ensure Docker Desktop **file sharing** allows that drive.

## Cursor self-hosted cloud agent worker (`nornir:cursor-worker`)

This is **not** the same as **`cursor-dev`** or the [Dev Container](../.devcontainer/devcontainer.json): those give you an **interactive dev shell** in Docker. The **worker** image is for Cursor’s **self-hosted cloud agent** process: it connects **outbound** to Cursor and runs **`agent worker start`** after preparing `/workspace`.

- **[Dockerfile.cursor-worker](Dockerfile.cursor-worker)** — `FROM nornir:dev-cursor-base` (venv + CuPy, **no** monorepo snapshot under `/opt/nornir`). Installs **`git`**, **`curl`**, and the Cursor **lab** `agent-cli-package` (pinned version; bump **`CURSOR_AGENT_VERSION`** when Cursor releases a new build).
- **[cursor-worker-entry.sh](cursor-worker-entry.sh)** — Requires **`CURSOR_API_KEY`** (unless you override the entrypoint). **`NORNIR_WORKSPACE_STRATEGY`**:
  - **`clone`** (default): empty **`/workspace`** → clone from **`NORNIR_CLONE_URL`** (default **`https://github.com/jamesra/nornir.git`**) branch **`NORNIR_CLONE_BRANCH`** (default **`dev`**); existing **`.git`** → fetch/checkout/pull. Then submodules and editable **`pip install -e`** via [cursor-dev-entry.sh](cursor-dev-entry.sh). **`NORNIR_CLONE_REFRESH=1`** wipes **`/workspace`**. **`NORNIR_CLONE_DEPTH`** / **`full`** as before.
  - **`mounted`**: host bind-mount at **`/workspace`** with an **existing** checkout. **Empty mount** (no **`.git`**) → same clone + submodules as **`clone`** (container fills the folder). **Existing repo** → **`git fetch`**; optional **`NORNIR_SYNC_REMOTE=1`** for **`git pull --ff-only`**. Then submodules + pip. [`start-cursor-worker.ps1`](start-cursor-worker.ps1) sets **`mounted`** for live mount of a **fixed** path (e.g. **`RepoRoot`**) and for isolated host clone under **`D:\agents`** and smoke test; **`-LiveMount -UseUniqueWorkspaceFolder`** sets **`clone`** (empty folder per run under **`D:\Docker\mounted-configs\nornir-cursor-worker`**); **`‑UseNamedDockerVolume`** uses default **`clone`** (named volume starts empty).
- If **`GITHUB_TOKEN`** or **`GH_TOKEN`** is set, the entry script configures `git` `insteadOf` for `https://github.com/` and `git@github.com:` so submodules can fetch over HTTPS.

**Environment file:** copy [`.env.cursor-worker.example`](.env.cursor-worker.example) to **`nornir-docker/.env.cursor-worker`** (gitignored). Set at least **`CURSOR_API_KEY`**; set **`GITHUB_TOKEN`** for private submodules or rate limits.

**Build** (from monorepo root):

```bash
docker build -f nornir-docker/dev/Dockerfile --build-arg INSTALL_MONOREPO_EDITABLES=0 -t nornir:dev-cursor-base .
docker build -f nornir-docker/Dockerfile.cursor-worker -t nornir:cursor-worker .
```

**Compose** (build **slim base** then worker; named volume for **`/workspace`** defaults to **clone** strategy; optional **`.env.cursor-worker`**):

```bash
docker compose -f nornir-docker/compose.cursor-worker.yaml build nornir-cursor-base nornir-cursor-worker
docker compose -f nornir-docker/compose.cursor-worker.yaml run --rm nornir-cursor-worker
```

If you **bind-mount** a host repo at **`/workspace`** instead of the named volume, set **`NORNIR_WORKSPACE_STRATEGY=mounted`** in **`.env.cursor-worker`** (and optionally **`NORNIR_SYNC_REMOTE=1`**).

Set **`NORNIR_CURSOR_WORKER_ENV_FILE`** to point compose at a Windows path (e.g. **`D:\Docker\Builds\nornir-cursor-worker\.env.cursor-worker`**); otherwise the compose file uses **`nornir-docker/.env.cursor-worker`**.

Compose keeps a **single shared named volume** for **`/workspace`** when you use the default compose file. For **one folder per worker run** on the host (isolation like **`D:\agents`** host-clone or **`D:\Docker\mounted-configs\nornir-cursor-worker`** per-run folders), use PowerShell below.

**Standard `D:\` layout** (env next to a symlinked launcher, unique workspace parent): see [windows-docker-layout/CONFIG_LAYOUT.md](windows-docker-layout/CONFIG_LAYOUT.md). Optional initializer: [`Initialize-NornirCursorWorkerLayout.ps1`](windows-docker-layout/Initialize-NornirCursorWorkerLayout.ps1).

**PowerShell** (from repo): [`start-cursor-worker.ps1`](start-cursor-worker.ps1)

- **Default:** host **`git clone`** into a unique directory under **`D:\agents`** (override parent with **`-AgentCloneParent`**), bind-mount at **`/workspace`**, pass **`NORNIR_WORKSPACE_STRATEGY=mounted`**. Container runs submodules + pip only (no redundant clone/pull unless **`NORNIR_SYNC_REMOTE=1`** in **`.env.cursor-worker`**). Host clone uses **`GITHUB_TOKEN` / `GH_TOKEN`** read from the file for the URL only (with **`credential.helper=`** disabled).
- **`-LiveMount`:** bind-mount **`WorkspaceMountPath`** or **`RepoRoot`** at **`/workspace`**, **`mounted`** strategy.
- **`-LiveMount -UseUniqueWorkspaceFolder`:** create an **empty** unique folder per run under **`WorkspaceRunParent`** (default **`D:\Docker\mounted-configs\nornir-cursor-worker`**, name pattern **`nornir-cursor-worker-<stamp>-<guid>`**), mount it at **`/workspace`**, pass **`NORNIR_WORKSPACE_STRATEGY=clone`** (overrides **`mounted`** in **`.env.cursor-worker`** if set). The container **clones** into it. Use **`-RemoveCloneAfter`** to delete that folder after exit.
- **`-EnvFilePath`** / **`NORNIR_CURSOR_WORKER_ENV_FILE`:** location of **`.env.cursor-worker`** (defaults to **`nornir-docker/.env.cursor-worker`** next to the script).
- **`-UseNamedDockerVolume`:** Docker volume at **`/workspace`**, **`clone`** strategy (first run clones inside the container).
- **`-RemoveCloneAfter`:** delete the isolated host clone directory or the **per-run unique** live-mount folder after the worker exits.
- **`-CloneUrl` / `-CloneBranch`:** isolated host clone only (defaults: **`origin`** and current branch).
- **`-Rebuild`** builds **`nornir:dev-cursor-base`** then **`nornir:cursor-worker`**; **`-Gpu`**, **`-SmokeTest`**.

Thin launcher (delegates with **`-LiveMount -UseUniqueWorkspaceFolder`**): [`windows-docker-layout/start-nornir-cursor-worker.ps1`](windows-docker-layout/start-nornir-cursor-worker.ps1).

The script loads **`.env.cursor-worker`** into the host process for keys like **`CURSOR_API_KEY`**, but **never** loads **`GITHUB_TOKEN` / `GH_TOKEN`** on the host (they are passed only via **`--env-file`** into the container).

**Submodule caveat:** [.gitmodules](../.gitmodules) mixes HTTPS and SSH URLs; the entry script rewrites **`git@github.com:`** when a token is present. Your token still needs access to every submodule repo. Shallow clones (**`NORNIR_CLONE_DEPTH=1`**) can break some submodule histories; use **`full`** if needed. **`nornir-docker`** is itself a submodule: if **`/workspace/nornir-docker`** is empty after clone, the worker image falls back to a **bundled** **`cursor-dev-entry.sh`** so editable installs still run from **`/workspace`** (rebuild **`nornir:cursor-worker`** after this change).
