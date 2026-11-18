# Local store for system locations

Sync locations outside the home folder, such as `/Library/Application Support/Native Instruments/Kontakt 8`, are still symlinks, but they point at a local folder instead of the settings folder. Takeover backs that local folder up into the settings folder.

## Why

macOS doesn't let system services open files in iCloud Drive (or Dropbox) through a link. When `/Library/Application Support/Native Instruments` linked into iCloud Drive, the package installer (`installd`/`shove`, running as root) failed with "Operation not permitted" ("error opening resolved_dest=…/Mobile Documents/com~apple~CloudDocs/Takeover/Native Instruments/Root Application Support"). Alex didn't want to change the installers or how he installs, and locations must stay symlinks, never copies.

## What users see

- The location's To is unchanged (for example `Native Instruments/Root Application Support` in the settings folder). Under To, the detail view says "Linked through /Users/Shared/Takeover/…" and that Takeover backs it up to To.
- Install links `/Library/…` to `/Users/Shared/Takeover/<To>`. On a Mac that doesn't have that folder yet (a new Mac, or one linked straight into iCloud by an earlier build), Install first copies the synced copy there, so the link points at the user's files. An existing link into iCloud shows as "points somewhere else"; Install relinks it to the local folder.
- `~/…` locations are unchanged: they link straight into the settings folder.

## Code

- `Config.localStoreRoot` (`/Users/Shared/Takeover`), `Config.usesLocalStore(from:)` (source outside the home folder) and `Config.linkTargetPath(from:to:)`, which every install, uninstall, link check and To change uses (`LinkItemInstaller.target(of:)`). A To picked outside the settings folder is used as-is.
- `LocalStoreBackup` (Shared, also used by the CLI): `seedIfNeeded` copies the synced copy into the local folder with `ditto`; `backUp` copies the local folder into the settings folder with `rsync -a --update` (newer files win, nothing is deleted from the backup).
- `LocalStoreSync.keepBackedUp` backs up every linked local-store location at start and every 10 minutes: in the app, and in the background agent (`DefaultsAgent`) while the app is closed. Install also backs up right after linking, off the main thread.
- Changing To moves the local folder and relinks (as before), and moves the synced copy too.

## Tests

- `systemLocationsLinkIntoTheLocalStore` in `TakeoverTests` covers which sources use the local store and where they link.

## Known limits

- The settings folder holds a backup of these locations, refreshed every 10 minutes and on install, not the live files. Changes made between backups reach other Macs late.
- Files deleted locally aren't deleted from the backup, so a restore can bring them back. This keeps two Macs that back up into the same folder from deleting each other's files.
- Files the installer creates that only root can read aren't backed up (rsync reports them in the log).

## History

- Implemented 2026-11-16, after the Native Instruments installer failed through a link into iCloud Drive. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
- 2026-11-18: `/Library/Audio` no longer uses the local store; it's mirrored as a real folder instead (see [audio_folder_mirror.md](audio_folder_mirror.md)).
