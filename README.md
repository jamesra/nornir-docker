# nornir-docker

Docker images for the **headless** Nornir stack on Python 3.14 (no Pyre UI). Use ``venv/pyre314`` on the host for the PyQt-based Pyre UI.

## Build vs run layout

- **Build phase (image tags):** committed **templates** use the pattern ``example.<tag-with-hyphens>.build.env`` (always ending in ``.env``), co-located with the relevant Dockerfile (e.g. ``dev/example.nornir-dev.build.env``, ``prod/example.nornir-cupy.build.env``, ``example.nornir-cursor-worker.build.env`` at the submodule root). Shared template: ``example._shared.build.env``. **Build script:** ``docker-build.ps1`` reads **only** optional overrides from the **invocation directory**: ``build.env`` (shared) and ``.build.<id>.env`` per image (``<id>`` = tag with ``:`` → ``-``). It does **not** merge those committed ``example.*`` files; copy from them into the CWD files if you want the same build-args.
- **Run phase (Compose / stacks):** committed run templates use ``example.<stack-or-service>.run.env`` next to the same docs (e.g. ``dev/example.cursor-dev.run.env``, ``example.nornir-cursor-worker.run.env``). **Run helpers:** ``run-cursor-dev.ps1`` for cursor-dev (optional ``-Clone`` for cursor-dev-clone); ``start-cursor-worker.ps1`` for the self-hosted worker; raw ``docker compose`` works too.

### Env file naming

Copy a committed ``example.*.run.env`` to a **non-example** filename for local Compose use (e.g. ``nornir-docker/.env``, ``.env.cursor-worker``), or place run overrides under ``$NORNIR_DOCKER_USER_ROOT`` with the same relative layout but **without** the ``example.`` prefix. For **``docker-build.ps1``** build-args, use ``build.env`` and ``.build.<id>.env`` in the directory from which you run the script (see script header). Real secrets and machine-specific paths stay **out of git**.

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
| ``run-cursor-dev.ps1`` | Run | ``docker compose … run`` for **cursor-dev** (bind-mounted repo) or **cursor-dev-clone** with ``-Clone``; optional ``-Gpu``. Requires ``nornir-docker/.env`` or ``NORNIR_TESTDATA_HOST`` (template: ``dev/example.cursor-dev.run.env``). |
| ``start-sample.ps1`` | Mixed | Samples: **Build** → ``docker-build.ps1``; **CursorDev** → ``run-cursor-dev.ps1``; **NornirBuild** → compose ``nornir-build``. |
| ``nd-build.ps1`` / ``nd-build.cmd`` | Run | Run ``nornir-build`` in a container with cwd mounted at ``/workspace``. |
| ``start-cursor-worker.ps1`` | Run | Windows launcher for the self-hosted Cursor worker (bind mounts, env files, GPU, cleanup). |

## Quick build (from monorepo root)

```bash
docker build -f nornir-docker/dev/Dockerfile -t nornir:dev .
docker build -f nornir-docker/prod/Dockerfile -t nornir:prod .
```

For full build options (OCI labels, BOM JSON), use ``docker-build.ps1`` or ``build.cmd`` in ``nornir-docker/``, or run ``.\nornir-docker\start-sample.ps1 -Sample Build`` from the repo root.
