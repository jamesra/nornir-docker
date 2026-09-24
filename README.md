# nornir-docker

Docker images for the **headless** Nornir stack on Python 3.14 (no Pyre UI). Use `venv/pyre314` on the host for the PyQt-based Pyre UI.

Build-arg overrides (`build.env`, `.build.<id>.env`) are read from the directory where you run `docker-build.ps1`. Committed `example.*.build.env` files are templates. Run secrets stay under `NORNIR_DOCKER_USER_ROOT` (default `C:\Docker`, often `D:\Docker`) and are not committed.

## Documentation

- **Which role to run:** https://nornir.github.io/guides/run_the_stack.html
- **Host requirements:** https://nornir.github.io/host_requirements.html
- **Docker overview:** https://nornir.github.io/docker/index.html
- **Image catalogue and build:** https://nornir.github.io/docker/images.html
- **nd-build:** https://nornir.github.io/docker/nd_build.html
- **Cursor dev shell:** https://nornir.github.io/docker/cursor_dev.html
- **Cursor worker:** https://nornir.github.io/docker/cursor_worker.html
- **Production appliance:** https://nornir.github.io/docker/remote_deployment.html
- **Dashboard:** https://nornir.github.io/docker/dashboard.html
- **Windows D:\\ layout:** https://nornir.github.io/docker/windows_cursor_layout.html
