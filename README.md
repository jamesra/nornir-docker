# nornir-docker

Docker images and deployment tooling for the **headless** Nornir stack (Python 3.14, no Pyre UI;
use `venv/pyre314` on the host for Pyre), plus the shared `stack.ps1` tooling that also deploys
the Viking server stacks.

- **Deploy and operate:** `deploy/stack.ps1` (one command for every stack, local or `-Target <host>`),
  `deploy/Initialize-DockerHost.ps1` (one-time host layout), `deploy/examples/` (copy-and-fill templates).
- **Build images:** `docker-build.ps1`; push or pull through GHCR with `docker-push.ps1` / `docker-pull.ps1`.
- **Machine-local files** (env, secrets, certs, data) live under `NORNIR_DOCKER_USER_ROOT`:
  `D:\Docker` on Windows, `/srv/docker` on Ubuntu. They are never committed.

## Documentation

- **Deployment & Configuration (start here):** https://nornir.github.io/deployment/index.html
- **Image catalogue and build:** https://nornir.github.io/docker/images.html
