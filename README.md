# nornir-docker

Docker images for the **headless** Nornir stack on Python 3.14 (no Pyre UI). Use ``venv/pyre314`` on the host for the PyQt-based Pyre UI.

## Build vs run layout

- **Build phase (image tags):** committed **templates** use the pattern ``example.<tag-with-hyphens>.build.env`` (always ending in ``.env``), co-located with the relevant Dockerfile (e.g. ``dev/example.nornir-dev.build.env``, ``prod/example.nornir-cupy.build.env``, ``example.nornir-cursor-worker.build.env`` at the submodule root). Shared template: ``example._shared.build.env``. **Build script:** ``docker-build.ps1`` reads **only** optional overrides from the **invocation directory**: ``build.env`` (shared) and ``.build.<id>.env`` per image (``<id>`` = tag with ``:`` → ``-``). It does **not** merge those committed ``example.*`` files; copy from them into the CWD files if you want the same build-args.
- **Run phase (Compose / stacks):** committed run templates use ``example.<stack-or-service>.run.env`` next to the same docs (e.g. ``dev/example.cursor-dev.run.env``, ``example.nornir-cursor-worker.run.env``). **Run helpers:** ``run-cursor-dev.ps1`` for cursor-dev (optional ``-Clone`` for cursor-dev-clone); ``start-cursor-worker.ps1`` for the self-hosted worker; raw ``docker compose`` works too.

### Env file naming

Copy a committed ``example.*.run.env`` to a **non-example** filename for local Compose use (e.g. ``nornir-docker/.env``, ``.env.cursor-worker``), or place run overrides under ``$NORNIR_DOCKER_USER_ROOT/Run/<project-key>/`` with the same relative layout but **without** the ``example.`` prefix (e.g. ``D:\Docker\Run\nornir-dev\`` for cursor-dev NAS mounts — see ``windows-docker-layout/NORNIR_DEV_VOLUMES.md``). For **``docker-build.ps1``** build-args, use ``build.env`` and ``.build.<id>.env`` in the directory from which you run the script (see script header). Real secrets and machine-specific paths stay **out of git**.

## Documentation

Full operational documentation lives in the **Nornir monodoc**:

- **Docker overview:** <https://nornir.github.io/docker/index.html>
- **Image catalogue & build:** <https://nornir.github.io/docker/images.html>
- **nd-build:** <https://nornir.github.io/docker/nd_build.html>
- **Cursor dev shell:** <https://nornir.github.io/docker/cursor_dev.html>
- **Cursor worker:** <https://nornir.github.io/docker/cursor_worker.html>
- **Windows D:\ layout:** <https://nornir.github.io/docker/windows_cursor_layout.html>

## Scripts (short)

| Script | Phase | Purpose |
|--------|--------|---------|
| ``docker-build.ps1`` / ``build.cmd`` | Build | All images with OCI labels + BOM JSON from **monorepo root**. Optional build-args from **invocation directory** only: ``build.env`` then ``.build.<id>.env`` per image; logs each path as merged or not found (see script header). Committed ``example.*.build.env`` are templates, not read by the script. |
| ``run-cursor-dev.ps1`` | Run | ``docker compose … run`` for **cursor-dev** (bind-mounted repo) or **cursor-dev-clone** with ``-Clone``; optional ``-Gpu``. Auto-includes ``$NORNIR_DOCKER_USER_ROOT/Run/nornir-dev/compose.volumes.override.yaml`` when present. Requires ``nornir-docker/.env`` or ``NORNIR_TESTDATA_HOST`` (template: ``dev/example.cursor-dev.run.env``). Optional ``NORNIR_REPRO_DATA_HOST`` mounts repro data at ``/data`` with ``INPUT_NORNIR_DATA=/data``. Test output defaults to ``D:/nornir-test-output`` → ``/tmp/nornir-test-output`` (override with ``NORNIR_TESTOUTPUT_HOST``). |
| ``start-sample.ps1`` | Mixed | Samples: **Build** → ``docker-build.ps1``; **CursorDev** → ``run-cursor-dev.ps1``; **NornirBuild** → compose ``nornir-build``. |
| ``nd-build.ps1`` / ``nd-build.cmd`` | Run | Run ``nornir-build`` in a container with cwd mounted at ``/workspace``. |
| ``start-cursor-worker.ps1`` | Run | Windows launcher for the self-hosted Cursor worker (bind mounts, env files, GPU, cleanup). |
| ``cursor-dev-entry.sh`` | Run | Container entry: workspace git prep + ``install-monorepo-editables.sh``. |
| ``install-monorepo-editables.sh`` | Run | ``pip install -e --no-deps`` for headless monorepo packages from ``NORNIR_MONOREPO_ROOT`` (default ``/workspace``). |

## Quick build (from monorepo root)

```bash
docker build -f nornir-docker/dev/Dockerfile -t nornir:dev .
docker build -f nornir-docker/prod/Dockerfile -t nornir:prod .
```

For full build options (OCI labels, BOM JSON), use ``docker-build.ps1`` or ``build.cmd`` in ``nornir-docker/``, or run ``.\nornir-docker\start-sample.ps1 -Sample Build`` from the repo root.

## CUDA runtime in dev / prod images (GPU)

Headless images use ``pip install cupy-cuda13x`` (or another ``cupy-cudaNx`` wheel). That wheel still needs **NVIDIA user-mode libraries** on the system (e.g. cuBLAS / libcublasLt) so CuPy can load them at runtime.

- **Install path:** ``install-nvidia-cuda-runtime-apt.sh`` adds NVIDIA’s **Debian 12** repo and installs ``cuda-libraries-*`` plus **development** packages ``cuda-cudart-dev-*``, ``cuda-nvrtc-dev-*``, and ``cuda-cccl-*`` for the same ``NVIDIA_CUDA_APT_VERSION`` (default **``13-1``**). The extra packages supply headers such as ``cuda_fp16.h`` required for **NVRTC** compilation (e.g. ``cupyx.scipy.ndimage.map_coordinates``); runtime-only ``cuda-libraries-*`` alone is not enough. See https://docs.cupy.dev/en/stable/install.html and the CuPy note on ``NVRTC_ERROR_COMPILATION`` / missing ``vector_types.h`` or ``cuda_fp16.h``.
- **Build args:** ``NVIDIA_CUDA_APT_VERSION`` (default ``13-1``) must match the **CUDA major** of ``CUPY_PACKAGE`` (e.g. ``cupy-cuda12x`` with ``NVIDIA_CUDA_APT_VERSION=12-6``). The script fails if majors disagree.
- **Prod CPU image:** ``INSTALL_CUPY=0`` skips the script and CuPy. ``INSTALL_CUPY=1`` runs the script then installs the CuPy wheel.
- **Host:** You still need an NVIDIA driver, the Container Toolkit, and typically ``--gpus all`` for GPU work inside the container.

Compose can set ``NVIDIA_CUDA_APT_VERSION`` via environment (see ``compose.yaml`` and ``compose.cursor-dev.yaml`` ``build.args``).

When CuPy adds a new ``cupy-cudaNx`` default, bump ``CUPY_PACKAGE`` and ``NVIDIA_CUDA_APT_VERSION`` together and confirm all four package families exist on NVIDIA’s Debian 12 index for that suffix.
