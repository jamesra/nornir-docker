---
name: nornir-volume-rollback
description: Restore a Nornir volume's metadata and transforms from a nornir-volume-backup snapshot on the srv build host, keeping mtimes and moving post-backup orphans aside, then verify with a status pass. Use only when the user asks to roll back a build.
---

# Nornir volume rollback

Roll back only when the user asks, and confirm which backup date to use.
`B=/storageN/_nornir_backups/<Vol>/<date>`.

1. **Check that nothing is building on the volume:** `tmux ls`, and the meta of any running
   `nornir/run/+`.
2. **Preview.** Run `rsync -ain --dry-run "$B"/ <vol>/ --exclude MANIFEST.txt`. Show the user a
   summary and get a yes.
3. **Move orphans aside.** List the `*.stos`, `*.mosaic` and `Manual/*` files that exist in the live
   volume but not in the backup, using the same globs as the backup. Move them to
   `/storageN/_nornir_backups/<Vol>/_rollback_orphans/<today>/`, keeping their relative paths.
   - This matters because a stray `Manual/<pair>.stos` is applied as an override on the next
     alignment just because it exists.
   - A stray `.mosaic` can be confused with new output.
4. **Restore with mtimes kept:** `rsync -a "$B"/ <vol>/ --exclude MANIFEST.txt`.
   - The restored XML carries the backup's `ValidationTime`, so no mass rebuild is expected.
   - Do NOT run `SyncValidationTimes` afterwards. It would hide real checksum mismatches.
5. **Verify.** Run `nornir-volume-status` and a read-only `nornir-build ListStosGroups <vol>`, and
   report the result.
