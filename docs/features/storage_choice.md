# Storage choice

Where the user's settings live: iCloud Drive, Dropbox, Takeover Cloud or a folder they pick.

## What users see

- **First open only:** a setup sheet (`StorageSetupView(isFirstLaunch: true)`) asks where to keep settings. It can't be dismissed without choosing. Settings already found on this Mac (`StorageLocation.detectExisting()`) are listed first and preselected, but the user still confirms. Picking Takeover Cloud asks for a login there (see [takeover_cloud_sign_in.md](takeover_cloud_sign_in.md)).
- **After that:** the app never asks again. The choice can be changed in Settings (`StorageSetupView(isFirstLaunch: false)`), or by applying a restore from another folder (see [restore.md](restore.md)).

## Code

- `TakeoverApp.needsStorageSetup` is true only while no choice is saved (`StorageLocation.load() == nil`). The choice is saved in `~/Library/Application Support/Takeover/storage.yaml`, which the CLI reads too.

## Known limits

- Macs that already saved a choice (including ones that auto-picked a single found folder in earlier builds) aren't asked again.

## History

- Implemented 2026-11-15, requested by Alex ("Should only ask the user on first open which storage mechanism to use"). Replaces the earlier behavior of silently adopting a single found settings folder. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
