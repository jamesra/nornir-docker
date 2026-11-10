---
name: nornir-volume-backup
description: Pre-build rollback backup (made only before a build changes a volume, never scheduled, no more than once per volume per week) of a Nornir volume's metadata and transforms (VolumeData.xml tree, .mosaic, .stos, settings) on the srv build host. Use right before a build that changes a volume; skip if a backup from the last 7 days exists.
---

# Nornir volume backup

Back up only right before a build changes a volume, never on a schedule, and no more than once per
volume per week. Backups go in `/storageN/_nornir_backups/<Vol>/<YYYY-MM-DD>/`.
That's on the same share, but **outside** the volume tree, so nornir globs and `RecoverLinks` never
see it. The backup holds metadata and transforms only. Tiles, assembled images and `Registered/`
can be regenerated, and import contrast caches only matter for re-import, so leave them all out.
Run it when no build is running on the volume.

1. **Check for a recent backup.** If a folder in `/storageN/_nornir_backups/<Vol>/` is newer than
   7 days, skip the backup and say so.
2. **Build the file list from known paths.** Use globs, not a `find` across the volume; over CIFS a
   find takes more than 10 minutes. `<B>` is the block (usually `TEM`) and `<C>` is the channel.
   ```
   VolumeData.xml VolumeData.db About.xml *.VikingXML Timing.txt StageTimings.json
   <B>/VolumeData.xml  <B>/*.zip
   <B>/<StosGroup>/VolumeData.xml  *.stos  Manual/  Automatic/  Originals/  stos_quality.json
   <B>/<sec>/VolumeData.xml
   <B>/<sec>/<C>/VolumeData.xml  *.mosaic  Translated_*_Settings.json  Translated_*_ManualOffsets.csv
   <B>/<sec>/<C>/<Filter>/VolumeData.xml  PruneScores_*  Histogram*.xml
   ```
   A StosGroup folder is any non-numeric folder in the block that has a `VolumeData.xml`.
3. **Copy with mtimes kept,** because nornir's skip logic depends on them. Run it in the background;
   it takes minutes over CIFS.
   ```bash
   DEST=/storageN/_nornir_backups/<Vol>/$(date +%F)
   rsync -a --files-from=<list> <vol>/ "$DEST"/
   rsync -a --include='*/' --include='*.stos' --include='*.json' --include='VolumeData.xml' --exclude='*' <vol>/<B>/<Group>/ "$DEST"/<B>/<Group>/
   ```
4. **Record it.** Write `MANIFEST.txt` with the request, the planned stages, the file count and
   `du -sh`. Report the path and size to the user.

Never delete old backups unless the user asks. A restore uses `nornir-volume-rollback`.
`nornir-build ExportMetadata` is a snapshot to diff against, not a rollback.
