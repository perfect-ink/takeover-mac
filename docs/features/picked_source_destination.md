# Destination follows the picked source

When you pick a folder for a sync location's From (the folder icon button next to From in `Takeover/Views/LinkItemDetailView.swift`), To is renamed after that folder, so it shows what's being synced instead of a placeholder like `Location 2`.

- The name comes from `RecipeInstaller.destination(appName:from:others:)` (`Takeover/Views/RecipesView.swift`): the app's folder, then the picked folder's name (`Ableton/User Library`), which is also the location's name. See [sync_destination_folders.md](sync_destination_folders.md).
- If another location already uses that name, `RecipeInstaller.uniqueDestination` adds the part of the path that differs from that location's: `~/Library/Audio/Plug-Ins` next to `/Library/Audio/Plug-Ins` becomes `Plug-Ins (User)` (the other way round, `Plug-Ins (System)`). If that's taken too, a number is added. Adding a catalog recipe's locations uses the same check.
- To is left alone when it's an absolute or `~` path the user chose, or when the location was already linked (an installed destination never moves).
- Tests: `destinationIsAppFolderThenLocationFolder`, `clashingLocationsGetTheDifferingPart`, `distinguishingPartIsWhereThePathsDiffer` in `TakeoverTests/TakeoverTests.swift`.

## History

- Implemented 2026-11-15. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
- 2026-11-15: a clashing To name gets the differing part of the path.
- 2026-11-15: To is `App/Location` instead of `App-Folder`.
