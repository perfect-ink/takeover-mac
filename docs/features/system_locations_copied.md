# System locations are copied, not linked

A sync location outside the user's home folder (for example `/Library/Application Support/Native Instruments` or `/Library/Audio/Plug-Ins`) is never replaced with a link. `LinkItemInstaller.isSystemLocation(_:)` decides this; `installByCopy` does the install.

## Why

Installers run as root (macOS Installer, Native Access and other vendors' helpers). macOS doesn't let them write into the settings folder (iCloud Drive, Dropbox, ~/Documents), so once `/Library/...` was a link into it, they failed with "Operation not permitted". Reported by Alex on 2026-11-16 after installing the Native Instruments recipe.

## What Install does for a system location

- Folder on this Mac: copies it into the settings folder, replacing the older copy. The real folder stays where it is.
- Folder missing here but in the settings folder (a new Mac): copies it into place.
- A link left by an older build: removes the link and copies the synced copy back as a real folder. This is the repair for Macs that hit the bug: click Install on the location again.
- Status is Installed when both the folder and its copy exist; a leftover link shows as needing attention. There's no conflict prompt; Install always backs up this Mac's folder.
- The detail view says so under From.

Locations inside the home folder are still linked as before.

## Known limits

- It's a copy: changes on one Mac reach the settings folder only when Install runs again.
- Tests: `systemLocationsAreOutsideHome`. Not run on a Mac in this change; CI compiles it.

## History

- Implemented 2026-11-16. Not yet in a release.
