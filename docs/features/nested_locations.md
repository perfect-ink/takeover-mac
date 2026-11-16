# Locations inside linked locations

Install refuses a location whose source sits inside another location that is linked, for example `/Library/Application Support/Native Instruments/Kontakt 7` while `/Library/Application Support/Native Instruments` itself is a link. Installing it would move files around inside the parent's synced copy. The error names the parent and says to uninstall it with Move destination first, so the folder is real again.

This matters for the Native Instruments recipe, which (since 2026-11-16) syncs each product folder under `/Library/Application Support/Native Instruments` on its own (Kontakt, Guitar Rig, Maschine, Reaktor and the rest, but not NTK or Service Center) instead of linking the whole folder. The folder itself stays real so NI's installers can write there. The recipe lives in takeover-site's `public/catalog/apps.yaml`; the bundled copy is `Takeover/apps-catalog.yaml`.

## Code

- `LinkItemInstaller.linkedParent(of:)` finds a saved location that is a link and whose source contains this one's (paths compared expanded, without resolving links, case-insensitively). `install` throws `LinkInstallError.insideLinkedLocation` when there is one.

## Tests

- `installRefusesAFolderInsideALinkedLocation` in `TakeoverTests`.

## Known limits

- The check only looks at the parent's link, not the reverse: installing a parent over already-linked children is still allowed.

## History

- Implemented 2026-11-16, when Alex chose to sync Native Instruments' product folders one by one. Not compiled locally (Linux session); CI builds and tests it.
