# Locations inside linked locations

Install refuses a location whose source sits inside another location that is linked, for example `/Library/Application Support/Native Instruments/Kontakt 7` while `/Library/Application Support/Native Instruments` itself is a link. Installing it would move files around inside the parent's synced copy. The error names the parent and says to uninstall it with Move destination first, so the folder is real again.

This matters for Native Instruments, whose folder under `/Library/Application Support/Native Instruments` is never linked whole. Since 2026-11-19 each NI product has its own recipe for its folder there ("Native Instruments Guitar Rig" covers every `Guitar Rig *` version; likewise Kontakt, Maschine, Reaktor, Battery, Kore, Massive, FM8, Komplete Kontrol, Dirt, Solid Mix Series, Supercharger). The "Native Instruments" recipe keeps the shared folders (Controller Editor, Driver, Hardware, Host Integration, Shared Content) and the user folders. NTK and Service Center aren't synced. The folder itself stays real so NI's installers can write there. Audio Presets works the same way: `/Library/Audio/Presets` and `~/Library/Audio/Presets` are no longer locations of their own, and each vendor recipe (Serum, u-he and others) syncs its own subfolder. The recipes live in takeover-site's `public/catalog/apps.yaml`; the bundled copy is `Takeover/apps-catalog.yaml`.

## Code

- `RecipeInstaller.followCatalogApps`: when the catalog moves a path to another app (Guitar Rig 7 from Native Instruments to Native Instruments Guitar Rig), the existing location is renamed into that app instead of a second one being added; its destination then follows the catalog like any rename (silently when nothing is on disk, asked otherwise). Locations of the user's own aren't touched.

- `LinkItemInstaller.linkedParent(of:)` finds a saved location that is a link and whose source contains this one's (paths compared expanded, without resolving links, case-insensitively). `install` throws `LinkInstallError.insideLinkedLocation` when there is one.

## Tests

- `installRefusesAFolderInsideALinkedLocation` and `locationsFollowAPathToItsNewCatalogApp` in `TakeoverTests`.

## Known limits

- The check only looks at the parent's link, not the reverse: installing a parent over already-linked children is still allowed.

## History

- 2026-11-19: Native Instruments split into a recipe per product (catalog version 9); existing locations follow their path to the new app.
- 2026-11-16: Audio Plug-Ins dropped from the catalog (plug-in installers break through a link; the bundles are binaries their installers restore).
- 2026-11-16: Audio Presets dropped as a whole-folder location (Alex: "Audio Presets is another one that cannot be done").
- Implemented 2026-11-16, when Alex chose to sync Native Instruments' product folders one by one. Not compiled locally (Linux session); CI builds and tests it.
