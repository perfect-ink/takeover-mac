# Destination follows the picked source

When you pick a folder for a sync location's From (Browse... in `Takeover/Views/LinkItemDetailView.swift`), To is renamed after that folder, so it shows what's being synced instead of a placeholder like `NativeInstruments-2`.

- The name comes from `RecipeInstaller.destination(appName:from:)` (`Takeover/Views/RecipesView.swift`): the app's name plus the folder's name (`Ableton-UserLibrary`), or just the app's name when the folder is named after the app.
- If another location already uses that name, `RecipeInstaller.uniqueDestination` adds the part of the path that differs from that location's: `~/Library/Audio/Plug-Ins` next to `/Library/Audio/Plug-Ins` becomes `...-User` (the other way round, `...-System`). If that's taken too, a number is added. Adding a catalog recipe's locations uses the same check.
- To is left alone when it's an absolute or `~` path the user chose, or when the location was already linked (an installed destination never moves).
- Tests: `destinationNamedAfterPickedFolder`, `distinguishingPartIsWhereThePathsDiffer` in `TakeoverTests/TakeoverTests.swift`.

## History

- Implemented 2026-11-15. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
- 2026-11-15: a clashing To name gets the differing part of the path.
