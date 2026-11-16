# Broken links

A location whose From is a link to something that no longer exists shows a red warning icon (`LinkStatus.broken`, from `LinkItemInstaller.status`). Its app shows the same icon in the sidebar, and the detail view says "Broken link: points to …, which no longer exists".

- This happens when the destination moves out from under the link, for example when another Mac that shares the settings folder reorganizes it (app folders, Reset Locations): the files move, but only that Mac's links follow.
- **Install** on the location (or the app's Install All) repairs it: the dangling link is removed and a new one points at the location's current To. Links under /Library need the admin password once.
- Locations are always links, never copies (Alex, 2026-11-16).

## Known limits

- Not detected automatically when the data moved to a folder other than the location's current To; then the files must be moved into To first.
- Not compiled or run locally (Linux session); CI compiles it.

## History

- Implemented 2026-11-16, after /Library/Application Support/Native Instruments, /Library/Audio/Plug-Ins and /Library/Audio/Presets were left dangling on Alex's Mac. Not yet in a release.
