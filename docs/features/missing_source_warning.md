# Missing source warning

Warns when a sync location's source path (its "From") doesn't exist on this Mac, instead of failing silently.

## What users see

- **Available Recipes** (`Takeover/Views/RecipesView.swift`): each recipe path that isn't on this Mac gets an orange "Not found on this Mac" label. Adding the recipe still works.
- **Sync setting detail** (`Takeover/Views/LinkItemDetailView.swift`): under From, an orange warning says the path doesn't exist on this Mac. If a synced copy already exists at the destination, it says installing links to that copy (the usual restore on a new Mac). Otherwise it says there's nothing to sync yet and installing links an empty folder.

- **Greyed out**: in an app's page in Sync Settings (`AppDetailView`, each location is an embedded `LinkItemDetailView`), a location whose From isn't on this Mac is drawn at reduced opacity, like apps not on this Mac in the sidebar. Missing recipe paths in Available Recipes are greyed the same way. Greyed locations stay fully usable.
- A broken link (a link whose target is gone) is not "missing": `sourceExists` counts it as present, so it keeps full color and its red icon (see [broken_links.md](broken_links.md)).

Installing is not blocked; the warning only explains what will happen.

## Code

- `LinkItemInstaller.sourceExists(_:)` in `Shared/Lib/LinkItemInstaller.swift`: true when the expanded path exists or is a link (including a dangling one). An empty path counts as present.
- Tests: `TakeoverTests/TakeoverTests.swift` (`sourceExistsForPathsOnThisMac`, `sourceMissingForPathsNotOnThisMac`, `brokenLinkCountsAsPresentNotMissing`).

## Known limits

- The check reads the disk when the view draws; it updates when the view redraws, not live.
- Paths the app can't read without Full Disk Access may show as missing until access is granted.

## History

- Implemented 2026-11-15, requested by Alex with the Native Instruments recipe. Not compiled or tested locally (written in a Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
- 2026-11-17: missing locations greyed out (Alex). Not compiled locally (Linux session); CI compiles and tests it.
