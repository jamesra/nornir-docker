# Shared build-session scripts (srv)

This folder is `/srv/docker/Logs/nornir-build/scripts` on the host and `/var/log/nornir/scripts` in
every nornir-build container, current and future (the Logs folder is bind-mounted into each one).
Use these instead of rewriting them. Python scripts run **inside** the container:
`docker exec nornir-build bash -c 'cd /var/log/nornir/scripts && python -Xfrozen_modules=off <script> ...'`.
The shell script runs on the **host**.

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
| `notify_session.sh "<session>" "<text>"` | Sends text to a Claude session by name through a headless `claude -p` limited to SendMessage/ListAgents. Logged to `../notify.log`. |

Tested 2026-11-10 (from RC1's pattern). See the `nornir-build-run` skill, section 4.
