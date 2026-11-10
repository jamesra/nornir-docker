# Shared build-session scripts

The **host** scripts in this folder (`install_image.sh`, `watch_job.sh`, `notify_session.sh` and the PowerShell
equivalents) run on the build host, from a nornir checkout (`<checkout>/nornir-docker/agent/host-scripts`). They call
`claude`, docker and `stack.ps1`, so they cannot run inside the container. The **container** scripts (`ncc_pairs.py`,
`manual_variants.py`, `refine_variants.py`) are in the image at `/opt/nornir/agent/container-scripts`; run them with
`docker exec <container> bash -c 'cd /opt/nornir/agent/container-scripts && VOL=<volume root> python -Xfrozen_modules=off <script> ...'`.
They need `VOL` set (no default volume). Examples below use srv paths (`/storage2/RC3`, `/srv/docker`); use your own.

| Script | Where | What |
|---|---|---|
| `install_image.sh <sha256:digest>` | host | Install a new nornir image into nornir-build: idle check, `stack nornir-build pull`, verify the digest is in RepoDigests, rebuild (one retry: the first rebuild sometimes fails with a `docker run`/`OCI ... ns/ipc` error), wait for the mounts, then print the Work folder, offline/CIFS mounts and GPU to send to the requester. Aborts without touching the container if anything is running or the digest doesn't match. Skill: `nornir-image-install`. |
| `ncc_pairs.py <pair> ...` | container | Masked NCC of StosBrute64 (ds64) and Grid32 (ds32) for each pair. `FILTER=Blob` (default; on RC3 0.13 = registered; calibrate per volume) or `FILTER=Leveled` (Grid32 only). `VOL=/storage2/RC3` default. Read-only. |
| `manual_variants.py <pair> ...` | container | Scores `StosBrute64/Manual` hand poses as saved and with the transform direction reversed (checks for a saved-backwards transform). Read-only. |
| `refine_variants.py <pair> ...` | container | Scratch Grid32 refine of the current StosBrute64 input: A = 512 px cells, 5 iterations; B (if A < 0.13) = A plus angles -15..15 deg. Writes only `/tmp/rvar` in the container. |

Pair names are `<mapped>-<control>` (e.g. `565-566` maps 565 onto 566). See the `nornir-stos-check`
skill for how to read the scores.

## Notify instead of polling (host side)

| Script | What |
|---|---|
| `watch_job.sh [-m MARKER -n COUNT] [-s] [-t NOTE] "<session>" "<label>" "<done-check>"\|- [<log or 'glob'> ...]` | Run in tmux. One message on the first failure lines in any log, or when done (done-check succeeds, or MARKER lines reach COUNT across all lane logs), then exit. Usage is in the script header. |
| `Watch-Job.ps1`, `Notify-Session.ps1` | PowerShell 7 equivalents of the two scripts above, for Windows hosts. Same behaviour and messages; the log defaults to `<NORNIR_DOCKER_USER_ROOT>\Logs\nornir-build\notify.log` (`D:\Docker`). |
| `notify_session.sh "<session>" "<text>"` | Sends text to a Claude session by name through a headless `claude -p` limited to SendMessage/ListAgents. Logged to `../notify.log`. |

Tested 2026-11-10 (from RC1's pattern). See the `nornir-build-run` skill, section 4.
