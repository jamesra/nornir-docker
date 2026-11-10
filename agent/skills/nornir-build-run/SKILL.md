---
name: nornir-build-run
description: Run a Nornir build (TEMImport, TEMBuild, TEMAlign, or a custom nornir-build stage list) on a volume from the srv build host — gates, preflight, tmux launch in the nornir-build container, MQTT/log monitoring, success checks, and resuming a failed --then chain. Use when a request asks to build, mosaic, align, assemble, or rerun stages on a volume.
---

# Run a Nornir build on srv

Paths and commands below are srv's layout: `/srv/docker` is `$NORNIR_DOCKER_USER_ROOT` (`D:\Docker` on Windows),
`/storageN` are the NAS mounts, `stack` is `stack.ps1`. Substitute your host's values.

## 1. Gates (stop and ask if any fails)

1. The build is part of the user's request.
2. Run `nornir-volume-status`.
   - **Annotated:** no stage from the CLAUDE.md rule 3 denylist. Lock the mosaic chain first:
     `nornir-build SetTransformLock <vol> -Locked 1 -Sections <first>-<last> -Transform '^(Stage|Prune|Translated_Prune|Grid)$'`.
     After that, alignment (TEMAlign) is allowed.
   - **Stale:** ask.
   - **Duplicate Grid nodes:** ask.
   - **Unlocked Grids with chain checksum mismatches:** ask. A validating Select deletes them.
3. Check the stage list against CLAUDE.md rules 4 and 5, and the known-issues list (e.g. the translate
   regression: don't rebuild C++-built mosaics).
   - **Crushed and legacy sections can share a volume** (James, 2026-11-10): crushed tiles are in
     `Quantized`, legacy tiles in `Raw8`. `TEMBuild` runs `TEMBuildLegacy` and then `TEMBuildCrushed`;
     each skips the other kind, and both leave a `Leveled` filter for TEMAlign (assembled images only in
     crushed sections). A volume crushed before 2026-11-10 holds its codes in `Raw8`: see rule 15 of the
     build-agent rules before importing into it.
   - **Never pass `-CameraBpp` to a crush import** (James, 2026-11-10). Crush sets its step from measured
     noise and never reads it; Nornir is making it an error. It is only valid with `-NoCrush`.
4. Run `nornir-volume-backup` if this build will change the volume. It is skipped if a backup from the
   last 7 days exists, but only if that backup is a FULL one (all StosGroups' .stos, the Grid and
   SliceToVolume groups, and the XML). A partial ad-hoc backup (e.g. only StosBrute64) does not count:
   TEMAlign re-refines Grid32/Grid16 and rewrites SliceToVolume for any pair whose input changed.
   (2026-11-01: 364 April-2023 Grid32 transforms were lost this way.)

## 2. Preflight

```bash
stack nornir-dashboard up
stack nornir-build up            # idempotent; never branch on `status` (it always exits 0)
docker exec nornir-build bash -c 'echo $NORNIR_NET_MOUNTS $NORNIR_MQTT_HOST; findmnt -t cifs -o TARGET; cat /run/nornir-offline-mounts 2>/dev/null; ulimit -n; nvidia-smi -L'
```

- Use `docker exec ... bash -c`, not `stack exec` (it forces `-it`) and not `bash -lc` (it loses PATH).
- Expect: `1`, the shares listed, the target volume not offline, `65536`, and a GPU.
- An offline target share is a hard stop.
- If the container exits on startup, read `docker logs --tail 30 nornir-build` and see the
  known-issues list in CLAUDE.md. Don't edit mounts or credentials without asking.

## 3. Launch

Check each segment's pipeline name and arguments with `nornir-build help <Pipeline>`. It doesn't
validate values, and later `--then` segments are only parsed when they're reached.

```bash
RID=agent-<Session>-<Vol>-<Script>-$(date +%Y%m%d-%H%M%S)   # <Session> e.g. RC1, RC3, Host
tmux new-session -d -s "$RID" \
  "docker exec nornir-build bash -c 'NORNIR_RUN_ID=$RID TEMAlign /storageN/<Vol> 2>&1 | tee /var/log/nornir/$RID.log'"
# the host-side log is /srv/docker/Logs/nornir-build/$RID.log
```

- Always pass the volume path; the TEM scripts prompt with `read` when it's missing.
- Set `NORNIR_RUN_ID` per invocation only, never exported. Put your session name in it: the retained
  MQTT meta is the shared list of running jobs, and the run id is how others find the owner.
- A launcher (or lane loop) must print its own RID and the caller must keep it. Never work out "my" RID
  from a shared file or `tail -1` of a list; parallel lanes pick up each other's runs that way.
- A loop that `docker exec`s jobs must stop when an exec fails (container gone or rebuilt), not move on
  to the next item; otherwise it "finishes" the whole queue in seconds.
- Under `-debug` (all TEM scripts) a fatal traceback goes to stderr only, hence the `tee`.
- Scripts on PATH: `TEMImport`, `TEMBuild`, `TEMBuild-import`, `TEMAlign`. Their stage lists are in
  `/srv/src/nornir/nornir-buildmanager/scripts/*.sh`; `docs/guides/tem_scripts.rst` explains them.
- Custom stage list:
  `python -Xfrozen_modules=off -m nornir_buildmanager -debug -computational_library cupy <vol> <Stage> ... --then <Stage> ...`
- Restrict sections with `-Sections 1,3,5-7`; it must be repeated in every segment.
- Alignment without reviewed brute-force pairs: run only through `SelectBestRegistrationChain`,
  show the user the StosBrute overlays, then run the rest.
- Partial runs: the TEM scripts take `-start-at N -stop-after M` (step number). For TEMAlign, where to
  start depends on the level of the hand fix (StosBrute64, Grid32 or Grid16); see the table in the
  `nornir-stos-check` skill. Steps 9–16 rewrite SliceToVolume/ChannelToVolume/VikingXML/Registered: run
  them once, only after the user approves the pairs.
- Mosaic (grid step) with CuPy can run out of GPU memory (one CuPy Delaunay per pool worker in
  grid_prewarp; found 2026-11-10, reported to Nornir). Until it's fixed, run Mosaic with
  `-computational_library numpy`. With another GPU job running, cap `-GpuWorkers` for StosBrute.
- The container is shared with other sessions. Check `ps` in the container and `free -g` before a long
  run. Several parallel pipelines can fill RAM and swap. Never rebuild the container during someone
  else's job (see `nornir-image-install`).
- Multi-hour jobs that only read data and don't need the pipelines (audits, checksums) go in their own
  named container from the same image, with read-only data mounts, so image installs don't kill them.

## 4. Monitor

- Watch the host-side log with Monitor. Grep for `^EXIT|Traceback|Error|Killed|^(Mosaic|Assemble|...) :`,
  not every stage line.
- MQTT:
  `docker exec nornir-build bash -c 'mosquitto_sub -h "$NORNIR_MQTT_HOST" -t "nornir/run/<RID>/meta" -v -C 1'`
- Check `compute` in the meta: a failed CuPy probe falls back to NumPy silently.
- Never publish into `<RID>`.
- **Waiting: long jobs notify, sessions don't poll** (James, 2026-11-10). Each session wake re-reads the
  whole conversation, so a Monitor keepalive (30-min cap) or a 2-h poll costs dozens of wakes a day.
  Instead, start a watcher in tmux on the host that messages your session once, on failure or completion:
  ```bash
  tmux new-session -d -s watch-$RID "<nornir checkout>/nornir-docker/agent/host-scripts/watch_job.sh \
    '<your session name>' '$RID' '<done-check command>' /srv/docker/Logs/nornir-build/$RID.log"
  # done-check example: "grep -q '^EXIT' /srv/docker/Logs/nornir-build/$RID.log"
  #                  or "! docker exec nornir-build pgrep -f <unique arg>"
  ```
  `watch_job.sh` takes several logs or quoted globs (e.g. `'/tmp/lane*.log'`, re-expanded each pass), so
  parallel lanes need one watcher and send one notification. For lanes, have each lane print a marker
  line when it finishes and use `-m LANE-DONE -n <lanes>` with `-` as the done-check. `-s` scans whole
  logs (fresh logs only), and `-t "<next step>"` adds a next-step note to the done message. It checks every
  60 s and reports the first failure lines (Traceback, FAILED, OCI runtime, No such container, Killed, ...)
  or "ENDED" with each log's last line, then exits. It sends
  through `notify_session.sh "<session>" "<text>"`, a one-shot headless `claude -p` limited to
  SendMessage/ListAgents (logged in `$NORNIR_NOTIFY_LOG`, default `<docker root>/Logs/nornir-build/notify.log`). It sends no routine
  progress. Your session name is the one ListAgents shows for you. Then stop: no Monitor or
  ScheduleWakeup loop for build progress (at most one rare fallback). When you next start work,
  check `tmux has-session -t watch-$RID`: if the watcher died, failures go unnoticed.
  For short waits inside a turn, an until-loop on a condition is fine (a bare `sleep N` is blocked;
  Monitor pipes need `grep --line-buffered`). To wait for another session's job, ask that session to
  message you when it ends.
- Verify files a container job just wrote from inside the container (`docker exec`). The host's CIFS view
  can show the old content for ~10 s.
- After an import into an existing channel, check from inside the container that the new filter
  (e.g. Raw8) has its channel `Filter_Link`; an interrupted ImportMRC used to leave it unlinked.

## 5. Decide success

- **Failed** if any of: the meta status is `failed`, a stage has no entry in
  `<vol>/StageTimings.json`, or there's a traceback in the tee'd log.
- **Review before declaring success:** a non-empty `-Errors.txt`, or "did not match" lines. Both also
  appear in harmless cases.

Report the outcome with the last log lines.

Put any list the user must act on (sections, pairs, files to open in Pyre) inline in the chat, not
only in a file. For batch tests, report early results at about 5, 10 and 20 items, then N.

## 6. Resume a failed chain

Fix the cause, then rerun from the failed step with the script's `-start-at <step>`. For a custom
`--then` chain, rerun from the failed segment with the remaining segments.

- A full rerun also works (finished stages skip by checksum), but MosaicToVolume, SliceToVolume,
  CreateVikingXML and MosaicReport redo their work every time.
- When one section crashes a stage, rerun with `-Sections` leaving it out, and report the bug.

## 6a. Stopping and repairs

- Stop a job by explicit PID: find it with `docker exec nornir-build ps -eo pid,args | grep '[-]m nornir_buildmanager'`
  (or `[n]ornir-build `), then `docker exec nornir-build kill -INT <pids>`. Never `pkill -f` a pattern:
  it has matched the agent's own shell. tmux `C-c` doesn't reach a process inside `docker exec`.
  Prefer stopping at a section boundary (the next "Generating"/section line in the log).
- Data damaged by a bug is repaired with a throwaway script, or by deleting the bad output and rerunning
  the normal pipelines, never with a new pipeline or flag (CLAUDE.md rule 14). Back up first
  (`nornir-volume-backup`).
- Bulk deletes on CIFS are slow: move the folders to `/storageN/_<topic>_trash/` (a rename is instant),
  rerun, then `rm -rf` the trash in the background (`xargs -P8`). Delete the trash only after the rerun
  is verified.
- Don't open every file in a volume for checks while builds are running; sample per section, or use a
  small header read (`os.pread` with readahead off) instead of opening whole files.

## 7. Resources and errors

- **Scripts that call nornir functions directly** (not through `nornir-build`) must keep everything
  except imports and function definitions under `if __name__ == "__main__":`. Python 3.14 starts
  worker processes with forkserver, which re-imports the script. Unguarded, the work re-runs inside
  the forkserver and deadlocks: 0% CPU, no workers, every thread waiting.
- About 5.9 GB RAM per core at the default `MAX_PYTHON_THREADS`, which caps the pools. Parallel pipelines
  share the 750 GB; if swap fills, run fewer at once.
- There's no GPU out-of-memory fallback. To profile a live stage: `py-spy dump|record --pid <pid>` inside
  the container (in the image from nornir-docker c90fa9b; older images: `pip install --target /tmp/pyspy py-spy`).
- "Exploded target-space control points" from Assemble means a bad grid transform, not too little
  memory.
- For unfamiliar errors, ask the Nornir RC agent. For hung stages, use the `nornir-debug-profiling`
  skill. Report bugs (CLAUDE.md rule 10).
