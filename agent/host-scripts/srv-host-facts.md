<!-- srv-specific facts from srv ~/.claude/CLAUDE.md (2026-11-10). Not deployed into the image: they describe the host. -->
# srv — Nornir build host

This machine (srv) is the lab's only build machine for EM volumes. These rules apply to every session
on it.

## Host map

- `stack` → `pwsh -NoLogo -NoProfile -File /srv/docker/stack.ps1` (it forwards to
  `/srv/connectomes-deploy/stack.ps1`). Run `stack` alone to list the stacks.
  - `nornir-build` is the production build container.
  - `nornir-dashboard` is the MQTT broker plus the dashboard.
  - `up` is idempotent and also starts a stopped container. `status` exits 0 even when a container is
    stopped, so don't branch on it. `exec` always adds `-it`, so from an agent shell use
    `docker exec <container> bash -c '...'` instead.
  - Use `bash -c`, never `bash -lc`: a login shell resets PATH and loses `/root/scripts` and `/opt/venv/bin`.
  - Start `nornir-dashboard` first.
- Build dashboard: http://10.226.68.253/ (container port 80; `NORNIR_DASHBOARD_BIND_HOST`/`NORNIR_DASHBOARD_HOST_PORT` in the dashboard run.env; `stack` HealthUrl uses them). No `NORNIR_DASHBOARD_TOKEN`: James removed it and would use the identity
  server for auth if it's ever needed, so don't regenerate the token. (2026-11-01)
- MQTT broker: the dashboard stack's Mosquitto (`nornir-dashboard-mosquitto-1`), on loopback only
  (`127.0.0.1:1883`). Only the dashboard is on the LAN (James). `nornir-build.run.env` sets
  `NORNIR_MQTT_HOST=mosquitto` and `NORNIR_DOCKER_EXTRA_ARGS=--network nornir-dashboard_default`, because
  the launcher's automatic network join fell back to `host.docker.internal`. So `stack nornir-dashboard up`
  must run before the build container is created. `mosquitto.connectomes.pitt.edu` is NXDOMAIN. The snap
  `mosquitto` is disabled because it held port 1883; don't re-enable it. (2026-11-01)
- Layout root: `/srv/docker`. jamesan can write to `Work/` and `Logs/`, but not to `/srv` itself.
  - `Logs/nornir-build` appears in the container as `/var/log/nornir`.
  - Each container's `/workspace` is `Work/<session>/`.
  - `stack.ps1 prune` deletes Work folders older than 14 days unless a running container mounts them.
- Nornir source: `/srv/src/nornir`. Its `CLAUDE.md` is written for Windows; on this host, build
  through the container. Viking source: `/srv/src/Viking`.
- NAS volumes: `/storage1` through `/storage5` and `/dropbox`, from
  `/srv/docker/Run/nornir-net-mounts/net-mounts/nas-mounts.tsv`, at the same paths in the container
  and on the host.
  - CIFS is slow for metadata. Never `find` across a whole volume (it takes more than 10 minutes on
    RC3); glob known paths instead.
- Local disk: `/` has about 1.8 TB free. `/build` is Docker's data root and isn't writable.
- Hardware: 128 cores, 750 GB RAM (about 5.9 GB per core at the default `MAX_PYTHON_THREADS`), and an
  RTX 4500 Ada (24 GB).
- Peer agents (use ListAgents, then SendMessage):
  - **Nornir RC** — pipelines and code. Ask it before guessing at stage arguments or behaviour.
  - **Viking Server RC** — annotation servers and OData.
- **Long jobs notify; sessions don't poll** (James, 2026-11-10). Start `watch_job.sh` in tmux (see
  `nornir-build-run` §4). On failure or completion it messages your session by name. Don't keep Monitor
  or ScheduleWakeup loops running for build progress. Shared scripts are in `/srv/docker/Logs/nornir-build/scripts/`
  (`/var/log/nornir/scripts` in the container; see its README).
- Existing nornir skills worth reusing: `deploy-connectomes`, `docker-machine-layout`,
  `docker-publish-ghcr`, `nornir-debug-profiling` (in `/srv/src/nornir/.cursor/skills/`).

## Known issues (image nornir:cupy, revision 1e38e5e, digest 8d2fbdbc, pulled 2026-11-01; -start-at/-stop-after STEP, -GpuWorkers available)

- **Windows-built prune scores (#268), masked overlap crash (#269), old checksum format (#271):** fixed
  in 13d5b57.
- **Offline NAS share:** fixed in image `815dd69` (2026-10-31). An unreachable share is mounted as an
  empty read-only tmpfs and listed in `/run/nornir-offline-mounts`; the container keeps running. Don't
  bind-mount the host's `mount-network-shares.sh` over the image's copy (that override was removed from
  `nornir-build.run.env`).
- **Grid refine quality (#270):** fixed in 13d5b57: within ±5% of the 2022 C++ build on RC3.
- **Translate layout on difficult sections (regression):** current translate (815dd69, 13d5b57) misjoins
  RC3 1637. A ~300-tile block is moved ~4800 px; overlaps across the join score NCC ~0, against 0.34 median
  for the 2022 layout. 1619 is fragmented and poor in both. Seam scores on a fixed pair list don't catch
  this; check cross-join overlap NCC. Don't rebuild C++-built mosaics until this is fixed.

Skills: `nornir-volume-status` (read-only; run it first), `nornir-volume-backup`,
`nornir-volume-rollback`, `nornir-build-run`.
- **StosBrute speed:** JIT fixed in f60ed38f (33 s → 19 s per pair). 1e38e5e adds GPU worker processes:
  `-GpuWorkers 0` (default) = auto, one per core capped at ~1.5 GB GPU each (~14 here); `1` = old serial.
  Tested ~6-8x faster, byte-identical results across N.
  To profile a live build: `pip install --target /tmp/pyspy py-spy` in the container, then
  `/tmp/pyspy/bin/py-spy dump|record --pid <pid>`. The launcher adds CAP_SYS_PTRACE (nornir-docker 3e9e147).
- **StosBrute pose regression on RC3 (found 2026-11-01; FIXED in 1e38e5e, buildmanager ade970b: the scale
  factor was Control/Mapped, so mixed-resolution pairs failed). Brute/Grid files written by images up to
  f60ed38f on mixed-resolution pairs are suspect. Refine colinear crash also fixed (855415d). Original note:** the current log-polar
  StosBrute returns a wrong pose (more than 300 px at ds32 from the trusted Grid32) for about a third of RC3
  pairs where the 2022 brute was right. Don't regenerate or replace existing brute or Grid transforms on a
  volume until this is fixed. Judge brute quality by pose distance to a trusted Grid transform; masked Blob
  NCC is misleading because it penalizes coarse but correct poses.
