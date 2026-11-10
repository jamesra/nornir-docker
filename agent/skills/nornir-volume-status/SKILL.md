---
name: nornir-volume-status
description: Read-only status report for a Nornir EM volume on the srv build host (e.g. /storage2/RC3) — annotated (OData) or not, last build activity and staleness, StosGroups/StosMaps with Manual fix counts, mosaic-chain checksum links and lock state, duplicate or missing Grids, latest backup, offline mounts, recent errors. Use before any build on a volume, or when asked what state a volume is in.
---

# Nornir volume status

Run the script. It is read-only, needs no container, and takes under a minute on a 1,600-section
volume over CIFS:

```bash
bash ~/.claude/skills/nornir-volume-status/scripts/volume_status.sh /storage2/RC3
```

| Line | Meaning | Action |
|---|---|---|
| Annotated | OData probe: 200 = yes, 404 = no, anything else = UNKNOWN | Yes or UNKNOWN: rule 3 (lock the chain, denylist) |
| Last activity | Last `StageTimings.json` or `Timing.txt` entry, plus the last stages run | More than 90 days: ask before building |
| Latest backup | Newest folder in `/storageN/_nornir_backups/<Vol>/` | Informational: back up only if a build will change the volume and none exists from the last 7 days |
| StosGroups | `stos=` count and `Manual=` hand-fix count per group | Manual fixes are reapplied on reruns; mention them |
| Mosaic chain: locks | Locked/unlocked count for Stage, Prune, Translated_Prune and Grid | Annotated and unlocked: lock first |
| Mosaic chain: mismatches | `InputTransformChecksum` that doesn't match the input node's `Checksum` | Unlocked ones get deleted by any validating stage: ask |
| Duplicate / missing Grid | Channels with 2+ Grid nodes, or none | Ask; Select may pick the wrong one |
| Offline mounts | Only shown inside the container | A build on an offline share fails |
| Newest error log | `<vol>/logs/` (2026-09+) or the volume root | Summarize if recent |

The mosaic-chain check compares XML only; it doesn't hash the `.mosaic` files. Nornir has no
read-only validation pipeline: every validating Select can clean nodes.

For more detail, run inside the container (still read-only): `nornir-build ListStosGroups <vol>`,
`ListBlockStosMaps`, `ListDamagedSections`.

Report as a short summary that leads with **annotated?**, **last activity** and **chain problems**,
because those decide whether a build may go ahead.
