# Nornir build-agent rules

These apply to every agent session that runs Nornir builds in a build container. They were written on srv (Build2) and apply to any build host; host-specific facts (paths, stack commands, hardware, known issues) are in `host-scripts/srv-host-facts.md`, not here.

## Rules

1. **Permission.** Run builds when they are part of a request, never on your own initiative.
2. **Stale volumes.** If a volume's last build activity was months ago, ask before building. Last
   activity is the last `Timing.txt` or `StageTimings.json` entry; `VolumeData.xml` mtimes are not a
   reliable signal.
3. **Annotated volumes: never change section `.mosaic` files.** The protected files are the Stage,
   Prune, Translated_Prune and Grid mosaics. Mosaics can be changed freely until annotation begins.
   Alignment is NOT restricted: `.stos` files, StosMaps, SliceToVolume, ChannelToVolume and TEMAlign.
   - **Annotated** means `https://websvc.codepharm.net/<Vol>/OData/$metadata` returns 200 (single-quote
     the URL in bash). A 404 means not annotated, and About.xml is not evidence. If the check can't be
     made, treat the volume as annotated.
   - **Lock before building.** Before any build on an annotated volume, lock the mosaic chain with
     `nornir-build SetTransformLock <vol> -Locked 1 -Sections <first>-<last> -Transform '^(Stage|Prune|Translated_Prune|Grid)$'`.
     That pipeline doesn't validate, so it can't clean anything. A locked node reports valid and
     can't be cleaned. Unlocking (`-Locked 0`) needs the user's go-ahead.
   - **Denied on annotated volumes:** Prune, Mosaic and MosaicNoTranslate (CompressTransforms rewrites
     even locked mosaics), SetPruneCutoff, RemoveTransform, ForceUpdateInputTransform, SetMosaicLock
     (it validates before locking), `SetTransformLock -Locked 0`, Cleanup, every Import*, TEMImport,
     TEMBuild, TEMBuild-import and AdoptVikingVolume.
   - Everything else, including TEMAlign, is allowed once the locks are in place.
4. **Never, on any volume:**
   - `ReportVolumeBounds` (broken).
   - `AdoptVikingVolume` on a live volume.
5. **Ask first, on any volume, before:**
   - `MarkSectionsDamaged`/`Undamaged`.
   - Changing `-Center`, Mosaic parameters or Prune thresholds on an existing build.
   - Regenerating VikingXML only "for freshness".
   - Naming an output transform with "grid" in it: Viking uses any transform with "grid" in its
     name to place the volume.
6. **Single builder.** srv is the only build machine, so there is no cross-host locking.
7. **Backups.** Make a backup only when a build is about to change a volume, never on a schedule,
   and no more than once per volume per week (skip it if one exists from the last 7 days). Use
   `nornir-volume-backup`. It saves metadata and transforms only, not `Registered/`.
8. **Test and scratch volumes go on local disk,** never on the NAS. Put them in the test container's
   `/workspace`, keep that container running while the test lasts, and delete the folder afterwards.
9. **Reporting is through MQTT.** Never publish into a build's run id.
10. **Report bugs.** Send every nornir bug you hit (crash, data loss, regression, doc mismatch) to the
    Nornir RC agent, with a repro, the traceback and file:line.
12. **Choosing test sections or pairs.** Never pick sections that nornir considers damaged. Damaged means
    listed in the block's `<NonStosSectionNumbers>` element in `<vol>/<block>/VolumeData.xml` (e.g.
    `/storage2/RC3/TEM/VolumeData.xml`). That's what `nornir-build ListDamagedSections <vol>` prints and
    what `MarkSectionsDamaged` edits. Read it directly:
    `python3 -c "import xml.etree.ElementTree as E;print([e.text for e in E.parse('<vol>/TEM/VolumeData.xml').getroot().iter('NonStosSectionNumbers')])"`
    - For slice-to-slice (stos) tests, drop any pair where either section is damaged.
    - Pick a mix: some sections with hand fixes (`Manual/` stos, or ground truth), some ordinary
      ones, spread across the volume. Hand fixes can themselves be wrong, so score them too; don't
      treat them as unquestioned truth.
    - The volume's build notes (e.g. `RC3/James_RC3_BuildingNoteScribbles.txt`) list known problem
      sections. Include one or two on purpose when testing robustness, and report them separately.
13. **Sharing data with other agents.** You may put data on the storage servers (`/storageN`) for other
    agents to fetch over https. Use a distinct folder per topic, `/storageN/claude-transfer/<topic>/`
    (default storage2), never inside a volume tree. Include a `MANIFEST.txt` (each file, source path,
    image/commit, md5) and send exact file URLs, e.g.
    `https://storage2.connectomes.pitt.edu/claude-transfer/<topic>/<file>`; directory listings are off
    (403). Delete a topic folder only when James says it's no longer needed. Small text stays in
    messages. (James, 2026-10-31)
11. **After a nornir upgrade,** the first run may rebuild stages because of checksum changes. Run the
    status check first.
14. **Keep programs simple: ask before adding flags or options.** Get James's permission before adding,
    or asking another agent to add, any new command-line flag, pipeline argument or option to a
    program. Prefer fixing the default behaviour. Fixes for bug damage are one-off scripts or
    delete-and-rerun, not new pipelines or options. (James, 2026-11-10)

15. **Crushed volumes imported before the `Quantized` change: check, tell James, rename.** New crushed
    imports (`ImportIDoc`/`ImportMRC` without `-NoCrush`) write the crushed tiles to a filter named
    `Quantized`; legacy (`-NoCrush`) imports stay in `Raw8`/`Raw16`. Volumes crushed earlier hold their
    crushed codes in `Raw8` (or `Raw16`) instead. **Before any import into an existing volume,** look for
    a `Raw8`/`Raw16` filter carrying `CrushStep` (crushed) in the target channel's `VolumeData.xml`. If
    you find one, stop and tell James before importing. The fix is to rename it to `Quantized` first
    (`nornir-build RenameFilter`, exact name), not to reimport. Never special-case the old name in code
    or scripts, and never mix names inside one volume. After the rename TEMBuild builds `Leveled` for
    TEMAlign.
    **Deprecated:** delete this rule once RC1, RC2 and RC3 have all been ported to `Quantized`
    (renamed or reimported). (James, 2026-11-10)
