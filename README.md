# nornir-docker

Docker images for the **headless** Nornir stack (Python 3.14, no Pyre UI; use `venv/pyre314` on the
host for Pyre).

- **Deploy and operate:** the [connectomes-deploy](https://github.com/jamesra/connectomes-deploy) repo
  (`stack.ps1`, `Initialize-DockerHost.ps1`, templates). `deploy/` here is the old copy from before the
  move (2026-10-21); do not use or extend it.
- **Build images:** `docker-build.ps1`; push or pull through GHCR with `docker-push.ps1` / `docker-pull.ps1`.
- **Machine-local files** (env, secrets, certs, data) live under `NORNIR_DOCKER_USER_ROOT`:
  `D:\Docker` on Windows, `/srv/docker` on Ubuntu. They are never committed.

## Documentation

- **Deployment & Configuration (start here):** https://nornir.github.io/deployment/index.html
- **Image catalogue and build:** https://nornir.github.io/docker/images.html
