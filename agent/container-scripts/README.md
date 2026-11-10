# Stos-scoring templates

Run inside the container, read-only on the volume (except `refine_variants.py`, which writes only `/tmp/rvar`):

    docker exec <container> bash -c 'cd /opt/nornir/agent/container-scripts && VOL=<volume root> python -Xfrozen_modules=off <script> <pair> ...'

`VOL` is required (the volume root, e.g. `/storage2/RC3`); there is no default.

**Pair names** are `<mapped>-<control>`: `565-566` maps section 565 onto control section 566.

**Hand fixes:** `manual_variants.py` reads the poses saved under `<vol>/TEM/StosBrute64/Manual`. See the `nornir-stos-check`
skill for how to read the scores and what to rerun after a hand fix.

| Script | What |
|---|---|
| `ncc_pairs.py <pair> ...` | Masked NCC of StosBrute64 (ds64) and Grid32 (ds32) per pair. `FILTER=Blob` (default) or `Leveled` (Grid32 only). |
| `manual_variants.py <pair> ...` | Scores `StosBrute64/Manual` poses as saved and with the transform direction reversed (finds poses saved backwards). |
| `refine_variants.py <pair> ...` | Scratch Grid32 refine of the current StosBrute64 input: A = 512 px cells, 5 iterations; B (only if A is below the threshold) adds angles -15..15 degrees. |

**Thresholds:** on ds32 Blob NCC, 0.13 or more counted as registered on RC3 and the median for the 2022 layout was 0.34.
These were calibrated on RC3 only; calibrate per volume before relying on 0.13. NCC of a coarse but correct StosBrute pose
is misleading low, so judge brute poses by distance to a trusted Grid transform.
