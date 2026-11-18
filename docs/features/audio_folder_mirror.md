# Audio folders kept in sync as real folders

Audio plug-ins and presets (`/Library/Audio/Plug-Ins`, `~/Library/Audio/Plug-Ins`, `/Library/Audio/Presets`, `~/Library/Audio/Presets`, and anything else under `/Library/Audio` or `~/Library/Audio`) are not linked. They stay real folders on the Mac, and Takeover copies newer files both ways between each folder and its synced copy in the settings folder.

## Why

Plug-in installers write into these folders as root. Through a link into iCloud Drive they fail with "Operation not permitted", and plug-in installers kept failing even when the link pointed into the local store (`/Users/Shared/Takeover`). Alex chose "two real folders kept in sync" over more links (2026-11-18). Every other location is still a link.

## What users see

- The catalog has **Audio Plug-Ins** (Library Audio Plug-Ins, User Audio Plug-Ins) and **Audio Presets** (Library Audio Presets, User Audio Presets). Serum and u-he no longer list their own Audio/Presets subfolders, since Audio Presets covers them.
- **Install** copies the synced copy's newer files into this Mac's folder (one password prompt when the folder is root's), then copies this Mac's newer files into the synced copy in the background. Both sides merge; there's no "which copy to keep" question.
- If the folder is still a link from an earlier build, Install puts a real copy of what it points to in its place first. The folder it pointed to is left alone.
- If another location is linked inside the folder (for example Serum's old `/Library/Audio/Presets/Xfer Records`), Install stops and says to uninstall that one with Move destination first.
- **Uninstall** just stops the copying. Nothing is moved or deleted, so it doesn't ask what to do with the files.
- The detail view says the folder is kept as a real folder and copied both ways.
- Every 10 minutes (with the local-store backup, in the app and in the background agent), Takeover pulls then pushes every mirrored folder. In the background it can't ask for a password, so a pull into a folder only root can write to waits for the next Install.

## Code

- `Config.mirroredFolders` and `Config.mirrors(from:)` pick the mirrored sources; `Config.usesLocalStore(from:)` excludes them.
- `Shared/FolderMirror.swift`: per-Mac state (which sources this Mac mirrors, and into which To) in `/Users/Shared/Takeover/mirrored-locations.json`; `pull`, `push` and `syncAll` with `rsync -a --update --exclude .DS_Store`. Foundation only, shared with the CLI.
- `LinkItemInstaller`: `installMirror`, `linkedChild(of:)`, and mirror branches in `install`, `uninstall`, `isLinked` (true when this Mac mirrors it), `hasConflict` and the To changes (`followMirror`).
- `LocalStoreSync.backUpAll` calls `FolderMirror.syncAll()`.
- CLI: `Installer.install/uninstall/isInstalled` handle mirrored folders (sudo rsync when the folder is root's).

## Tests

`TakeoverTests`: `audioFoldersAreMirroredNotLinked`, `mirroringCopiesBothWaysAndDeletesNothing`, `mirrorStateIsKeptPerSource`.

## Known limits

- Deleting a plug-in on one Mac doesn't delete it from the synced copy, so the next pull brings it back. Delete it from both places (or from the synced copy first).
- Changes reach the other side within 10 minutes, not instantly.
- Files only root can read (some installers write these) aren't pushed; rsync logs them.
- A large first pull (a new Mac restoring gigabytes of plug-ins) runs during Install and keeps the window busy until it's done.

## History

- Implemented 2026-11-18, after Alex reported that installing audio plug-ins and presets failed with permissions ("Maybe a better solution would be syncing two folders"). Not compiled or run locally (Linux session, no Swift toolchain); the GitHub Actions build on main compiles it and runs the unit tests. Not tried on a Mac. Not yet in a release.
