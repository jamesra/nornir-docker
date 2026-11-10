---
name: nornir-image-install
description: Install a newly published nornir image (ghcr.io/jamesra/nornir:cupy digest) into the nornir-build container on srv — coordinate with sessions that have jobs running, idle check, pull, verify the digest, rebuild (with the known one-retry), report the new Work folder and mounts. Use when Nornir or another session announces a new image or asks for one to be installed.
---

# Install a nornir image into nornir-build

## 1. Before anything: who is using the container?

- A rebuild **kills every process** in nornir-build and gives the container a new `/workspace`
  (Work folder). Shares in `nas-mounts.tsv` come back by themselves, including `/mnt/storage3-RawData`
  (standard since 2026-11-10); any other hand-made mount is lost.
- See what's running. The install script prints the same list and refuses while anything runs:
  - processes: `docker exec nornir-build bash -c 'ps -eo pid,etime,args | grep -E "[p]ython|[n]ornir-build " | grep -v forkserver | cut -c1-160'`
  - pipelines: the retained MQTT meta (`nornir/run/+/meta`). Runs with `status` `running` and `host` equal to
    the container's hostname (`docker inspect nornir-build --format '{{.Config.Hostname}}'`) die on a rebuild.
    The owner is in the run id (`agent-<session>-<Vol>-<what>-<stamp>`; older ids omit the session).
- If another session's job is running, **ask that session first** (ListAgents → SendMessage) and wait
  for its "go". A session running a long job (more than ~2 h) owns the container until it says otherwise.
  Never stop someone else's job to install an image. Multi-hour jobs that don't need nornir-build itself
  belong in their own named container (e.g. `rc2-audit`), so they survive installs.
- If James asked for a job to be "run and profiled", run it on the newest image: install first, then run
  (see memory `run-latest-code`).

## 2. Install

```bash
<nornir checkout>/nornir-docker/agent/host-scripts/install_image.sh sha256:<digest>
```

The script (host side):
1. Aborts if any `python`/`nornir-build` process runs in the container, listing them plus MQTT runs still
   `running` on it.
2. `stack nornir-build pull`, then checks `RepoDigests` of `nornir:cupy` contains the digest; aborts on
   a mismatch (do not rebuild on an unverified image).
3. `stack nornir-build rebuild`, retried once: about 1 in 4 first attempts fails with a `docker run` or
   `OCI runtime exec failed ... /proc/<pid>/ns/ipc` error because the old container is not gone yet.
4. Checks the running container's image equals the digest, waits for `drop_sys_admin` in the logs
   (mounts done), then prints the Work folder, offline mounts, CIFS mounts and GPU.

Notes:
- The `grep -c` trap: `grep -c` prints 0 and exits 1 when nothing matches, so `$(... | grep -c x || echo 0)`
  yields "0\n0". Use `grep -q` for yes/no checks.
- An image built locally (not on GHCR) is lost by the next `stack nornir-build pull`; say so when you
  install one.
- With this Docker (containerd image store) the container's `.Image` equals the registry digest, so the
  script's digest comparison is exact.
- py-spy is in the image from nornir-docker c90fa9b (cupy `sha256:93f021c4...`); no install step needed.

## 3. Report

Send to the requester **and** every session that uses the container:
- image digest and revision label (`org.opencontainers.image.revision`),
- the new Work folder `/srv/docker/Work/nornir-build-<ver>-<stamp>`,
- offline shares (`/run/nornir-offline-mounts`), and that anything kept in the old `/workspace` must be
  copied forward (until Nornir adds a persistent `/projects` mount).

Record the install (date, digest, revision, Work folder) in your project memory.
