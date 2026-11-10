---
name: nornir-mosaic-damaged
description: Rescue the mosaic (translate/grid) of a damaged section on srv — folds, tears, white stripes, misjoined tile blocks — using Nornir's committed rescue-damaged-section skill and scripts, with the srv paths, srv rules and crushed-volume caveats layered on top. Use when a section's mosaic is misjoined or fragmented, or when asked to rescue, retranslate or repair a section's mosaic.
---

# Rescue a damaged section's mosaic (srv overlay)

The method lives in Nornir's repo skill, **`rescue-damaged-section`**. Read **all** of it first and
follow it. This file adds what differs on srv and lists the steps that must not be skipped. Don't copy
the method here, so the two don't drift. Where a line below is an srv rule rather than the skill's, it
says so.

## 1. Read the source; refresh policy

The image ships the repo skill with its scripts, so read the deployed copy:

```bash
cat ~/.claude/skills/rescue-damaged-section/SKILL.md      # scripts: ~/.claude/skills/rescue-damaged-section/scripts/
```

It is the version in the image you are running. To compare with the repo's newest, fetch only (never switch a shared
checkout): `git -C <nornir checkout> fetch -q origin dev` then
`git -C <nornir checkout> show origin/dev:.cursor/skills/rescue-damaged-section/SKILL.md`.

- Scripts: the deployed `scripts/` folder above. Run them inside the container with the container's python (not the
  skill's `venv\pyre314\Scripts\python.exe`).
- **srv patches:** the srv session patched some scripts for crushed sections (`*_srv.py`, see §5). They are not in the
  image; if the repo's scripts now handle crushed sections, use those, otherwise ask Build2 for the patches.

## 2. srv paths for the skill's Windows paths

| Repo skill | On srv |
|---|---|
| `C:\Temp\Nornir\<section>_retranslate\` (isolated copy; holds the only refined mosaics until install, often for days) | `/var/log/nornir/rescue/<Vol>-<section>/` in the container = host `/srv/docker/Logs/nornir-build/rescue/<Vol>-<section>/`. Local disk, the same in every container, survives image installs, and isn't touched by `stack.ps1 prune` (which only deletes `Work/nornir-build-*`). **Not** `/workspace`: it is replaced on every install. Move to `/projects/rescue/...` once Nornir adds that mount. Copies keep their original dates (`cp -a`/`rsync -a`, like robocopy), so keep the folder out of any age-based cleanup (nothing on srv prunes Logs as of 2026-11-10; `rescue/README.md` marks it). Delete it only after the install is verified and James agrees. |
| `Y:\_nornir_work\<section>\` (review images and annotation transfer map) | `/storageN/claude-transfer/rescue-<Vol>-<section>/` with a `MANIFEST.txt`. Send James the exact file URLs: `/storageN/<path>` is served as `https://storageN.connectomes.pitt.edu/<path>`; directory listings are off. Use the volume's own NAS if its URLs work (check one with curl), otherwise storage2. Verified 2026-11-10: storage1 and storage2 serve; storage3 answers but returned 404 for volume files; storage4 and storage5 didn't answer from srv. If unsure, check the volume's `About.xml` or ask James for the map. Never upload images to chat. |
| `Y:\_nornir_backups\RC2\<date>-section<N>-rescue\` | `/storageN/_nornir_backups/<Vol>/<date>-section<N>-rescue/` on the NAS that holds the volume. Always on the NAS, never in Work, Logs or projects. |
| `robocopy` | `rsync -a` (verify sizes afterwards, as the skill says). |
| Workstation pitfalls: commit limit / `MAX_PYTHON_THREADS=8`, shared display GPU, UNC paths and `ConvertImagesInDictGpu`, drive-letter paths | Windows only. srv's 750 GB is shared: check `free -g`. The `Raw8\TilePyramid` exclusion list **still applies**. |

**Where writes go: ask the user.** Before the first write outside the isolated copy (backups, Leveled
tiles, Prune, the install itself), ask the user which volume or copy to write to. It may be the production
volume, a mirror or block copy, or a scratch copy. Don't decide from earlier sessions or other volumes'
practice. Also check the target share isn't in `/run/nornir-offline-mounts`.

## 3. Must-not-skip steps (all from the repo skill; easy to miss in a skim)

1. **CuPy:** set `NORNIR_COMPUTATIONAL_LIBRARY=numpy` for `refine_half.py` / RefineGridMosaic and for
   assembly. With the default CuPy backend (the nornir:cupy image), RefineGridMosaic fails with "Implicit
   conversion to a NumPy array is not allowed".
2. **Prune notes (step 2):** move the old `PruneScores_*` aside, **not** `Histogram_*`. Add the flat-tile
   rule (std < 8 on Leveled ds16); crushed sections need an equivalent on Raw8 (§5).
3. **The section's own nominal overlap (step 3):** derive it from the Stage pitch against the tile size.
   825 was captured at 20% overlap, so "no pair over 15%" doesn't hold there.
4. **Full poor-edge check (step 4) and placement rules:** settled tiles never move; coverage never decides
   placement; no unconfirmed fill tiles; no solve move under 128 px; rotation only via log-polar on folded
   pairs. All thresholds come from the section's own far-pair noise floor (RC2 1240: NCC p95 0.77, max 0.86),
   never fixed values.
5. **Review standard (step 6):** `before_Grid_2015_ds16.png` and `after_Grid_repaired_ds16.png` from
   `assemble_mosaic.py`, delivered to the review path (§2).
6. **Annotations first (step 7):** every repair delivers an annotation transfer map
   (`Translated_old.mosaic` and `Grid_old.mosaic` next to the new ones, `remap_mosaic_points.py --sample`,
   `README.txt`) **before** asking to install. `install_rescue.py` refuses a real install without
   `--annotation-rescue-report`, or `--no-annotations` after James confirms the section has none.
7. **Rehearse install steps 3–6 on the copy first.** On 1240 the rehearsal reproduced the production Prune
   and node checksums.
8. **Anchor decision (step 8.5):** always read the `--dry-run`. Anchoring vs `--no-anchor` (and translating
   the annotations) is James's call. On a torn section one anchor fixes only one half (1240: origin pushed
   to -75,325 px).
9. **After install:**
   - Assemble Leveled ds8–64 (this rebuilds the Mask).
   - Back up `Blob\Images`, then run `CreateBlobFilter -Radius 9 -Median 7 -Max 3 -Levels 16,32,64`.
   - ChannelToVolume and the section's stos are now stale. Don't run MosaicToVolume or later steps blindly.
   - James merges the halves in Pyre.
   - (srv) Rerun only the TEMAlign steps the change needs; see `nornir-stos-check`.

## 4. srv rules on top (not from the repo skill)

- **Gates:** run `nornir-volume-status` first. Everything before the skill's *Install* step is analysis on
  the isolated copy and is fine on any volume.
- **Install changes section mosaics** and runs SetPruneCutoff/Prune in the volume. On an annotated volume
  (CLAUDE.md rule 3) that is normally denied. Install only with **James's explicit approval for that
  section and its write target**, given after he has reviewed the images and the annotation map, never on a peer's say-so.
  `install_rescue.py` itself locks Translated_Prune and Grid afterwards. If the section's chain is
  **already locked** (e.g. a second rescue), lifting the locks (`SetTransformLock -Locked 0`) is new ground:
  ask James.
- Never edit `Stage.mosaic` in a volume (also in the repo skill). Changing `-Center`, Prune thresholds or
  Mosaic parameters on an existing build needs James's OK (CLAUDE.md rule 5).
- **Translate regression** (CLAUDE.md known issues, seen on RC3 1637; not in the repo skill):
  the current translate can misjoin a ~300-tile block by ~4800 px. Judge any re-translate by cross-join
  overlap NCC against the section's noise floor, not by seam scores on a fixed pair list.
- Never mix crushed and legacy sections in one volume (James, 2026-11-10). A legacy-volume repair that
  needs new tiles uses a `-NoCrush` import.

## 5. Crushed (gain-first) sections only: caveats until the repo skill covers them

Found by Build2 RC RC3 on RC3 516, 2026-11-10 (`/srv/docker/Logs/nornir-build/rc3-516-handoff.md`).
James decides whether the repo skill changes. **These apply to crushed sections only.** For legacy
(e.g. RC2) sections the skill's method stands as written.
1. `tile_overlap_stats.py` and `crosscheck_pairs.py` hard-code `Leveled/TilePyramid/016`, and crushed
   sections have no Leveled. Use `tile_overlap_stats_srv.py` / `crosscheck_pairs_srv.py` with
   `RESCUE_FILTER=Raw8 RESCUE_LEVEL=4`. Note that the `_srv` crosscheck still reads level 016.
2. On crushed tiles the prune scores don't separate blank tiles from tissue (median 674 removed vs 678
   kept), so "pick the valley" fails. Ask the user how to choose the tile set (on RC3 516 the session
   used the section's older legacy prune tile set). For legacy sections, use the valley method and look at
   the tiles with the user.

## 6. Report

Give James the before/after ds16 pair and the annotation transfer folder as exact paths or URLs, with
the per-section numbers: noise floor, nominal overlap, overlap NCC before/after, tiles dropped at each
stage. Keep the section's working record in its rescue folder (§2), not only in the transcript.
