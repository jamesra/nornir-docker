# Build-agent skills and rules

Skills and rules for agent sessions that run Nornir builds, written on srv (Build2) and kept here so every build host and
image gets them.

| Folder | What | Where it ends up |
|--------|------|------------------|
| `skills/` | Claude skills (`nornir-build-run`, `nornir-stos-check`, `nornir-mosaic-damaged`, `nornir-image-install`, `nornir-volume-status`, `nornir-volume-backup`, `nornir-volume-rollback`) | image: `/opt/nornir/agent/skills`, copied to `~/.claude/skills` at container start |
| `rules/` | `build-agent-rules.md`, the general build rules | image: copied to `~/.claude/rules` at container start |
| `container-scripts/` | Stos-scoring templates (`ncc_pairs.py`, `manual_variants.py`, `refine_variants.py`) | image: `/opt/nornir/agent/container-scripts` |
| `host-scripts/` | `watch_job.sh`, `notify_session.sh`, `install_image.sh` (they run on the HOST and call `claude`, docker and `stack.ps1`) and `srv-host-facts.md` | repo only; not in the image |

The image copies the skills and rules over any with the same name each time a container starts, so the image is the
source of truth; other files in `~/.claude` are left alone.

The skills and scripts name srv paths (`/srv/docker/...`, `/storageN`, `stack.ps1`, tmux). Adjust them for another host.
`watch_job.sh` and `notify_session.sh` are bash and need tmux and the `claude` CLI on the host; there is no PowerShell
equivalent yet.
