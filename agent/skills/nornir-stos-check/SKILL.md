---
name: nornir-stos-check
description: Check slice-to-slice (stos) registrations on a nornir volume on srv — rerun alignment only through Grid32/Grid16 to pick up brute or hand fixes, score pairs with masked NCC, test hand poses and refine variants, and know where manual overrides go. Use when asked whether pairs/hand fixes register, to list unregistered pairs, or to check a Pyre fix.
---

# Check stos registrations

## Vocabulary
- Pair names are `<mapped>-<control>`: `565-566` maps 565 onto 566. Files:
  `StosBrute64/<pair>_ctrl-TEM_Blob_map-TEM_Blob.stos` (ds64 Blob),
  `Grid32|Grid16/<pair>_ctrl-TEM_Leveled_map-TEM_Leveled.stos` (ds32/ds16 Leveled).
- `NonStosSectionNumbers` (the damaged list) only stops a section being a **control**; it is still
  mapped and placed. There is no exclusion-list feature: removing a section from alignment is the user's
  decision and action (on RC3 James moved such folders out of the volume himself). Ask; don't do it.
- Manual overrides (Pyre):
  - `StosBrute64/Manual/<pair>...Blob.stos` replaces the brute result (copied at AlignSections).
  - `Grid32/Manual/<pair>...Leveled.stos` replaces the Grid32 result and is carried into Grid16.
    Grid32 files refer to Leveled ds32 images, so hand fixes can be done on Leveled.
  - A `<pair>...unrefined.stos` in Grid32 is the scaled input left when refine failed (a start point).

## Rerun only what is needed
TEMAlign steps: 1 CreateBlobFilter · 2 AlignSections (StosBrute64) · 3 overlays · 4 SelectBestRegistrationChain ·
5 refine to Grid32 · 6 overlays · 7 Grid32 VikingXML · 8 refine to Grid16 · 9–16 volume steps
(SliceToVolume … ExportImages).

Where to restart depends on the level of the fix:

| Fix saved in | Rerun | Status |
|---|---|---|
| new/changed brute pairs, `StosBrute64/Manual` | `-start-at 2 -stop-after 5` to check at Grid32, or `-stop-after 8` | in use on RC3. AlignSections copies the Manual file ("Copy manual override stos file to output"), so start at 2. Whether step 4 must rerun is still being confirmed with Nornir |
| `Grid32/Manual` | `-start-at 5 -stop-after 8` | read in code, not run (block.py ~2233-2243): the Grid32 refine (step 5) copies the Manual file to the Grid32 root, and step 8 scales that into Grid16. `-start-at 8` alone would miss it |
| `Grid16/Manual` | `-start-at 8 -stop-after 8` | read in code, not run: the same OutputGroup/Manual rule applied at step 8 |

**Never run steps 9–16 while pairs are still being fixed**; they rewrite the volume transforms. Run them
once, when the user approves the pairs. Update this table when Nornir answers.
- Existing pairs skip by checksum; only changed pairs are recomputed. A caught per-pair refine failure
  (e.g. "Masking operation removes all points") prints a traceback but the run still exits 0.

## Score
Scripts in `/var/log/nornir/scripts` inside the container (see its README):
```bash
docker exec nornir-build bash -c 'cd /var/log/nornir/scripts && python -Xfrozen_modules=off ncc_pairs.py 565-566 564-565 566-567'
docker exec nornir-build bash -c 'cd /var/log/nornir/scripts && FILTER=Leveled python -Xfrozen_modules=off ncc_pairs.py 565-566'
```
- Thresholds are per volume. On RC3, masked ds32 **Blob** NCC ≥ 0.13 meant registered and good pairs
  scored ~0.3–0.55. On another volume, calibrate first: score a spread of pairs the user trusts and
  pick the cut from that volume's own distribution (tell the user the value). Always score the
  neighbouring pairs too, for comparison. Leveled NCC is lower and noisier; use it only as a second opinion.
- ds64 brute NCC is weak (on RC3, good poses scored ~0.1); judge by the Grid32 result.
- A hand fix that scores the same before and after Grid32 was not improved by refine: the pose is
  outside the refine's capture range (all cells peak-ambiguous). `manual_variants.py` rules out a
  saved-backwards transform; `refine_variants.py` tries 512 px cells and ±15° (both failed on RC3's
  bad hand fixes in Nov 2026). The fix then has to be redone in Pyre.
- Cross-camera pairs (e.g. RC3 Gatan vs OneView): check the pose scale against the cameras' true pixel
  sizes; a scale near the inverse of the expected one suggests the pose was entered backwards.

## Report
Per pair: NCC before/after Grid32 with neighbours, which file it came from (Manual or automatic), and
the remaining unregistered list. Keep the list in a file in `/srv/docker/Logs/nornir-build/`.
