# nornir-docker

Docker images for the **headless** Nornir stack on Python 3.14 (no Pyre UI). Use ``venv/pyre314`` on the host for the PyQt-based Pyre UI.

## Documentation

Full operational documentation lives in the **Nornir monodoc**:

- **Docker overview:** <https://nornir.github.io/docker/index.html>
- **Image catalogue & build:** <https://nornir.github.io/docker/images.html>
- **nd-build:** <https://nornir.github.io/docker/nd_build.html>
- **Cursor dev shell:** <https://nornir.github.io/docker/cursor_dev.html>
- **Cursor worker:** <https://nornir.github.io/docker/cursor_worker.html>
- **Windows D:\ layout:** <https://nornir.github.io/docker/windows_cursor_layout.html>

## Quick build (from monorepo root)

```bash
docker build -f nornir-docker/dev/Dockerfile -t nornir:dev .
docker build -f nornir-docker/prod/Dockerfile -t nornir:prod .
```

For full build options (OCI labels, BOM JSON), see the [image catalogue](https://nornir.github.io/docker/images.html).
