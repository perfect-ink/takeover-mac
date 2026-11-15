# Destination follows the picked source

When you pick a folder for a sync location's From (Browse... in `Takeover/Views/LinkItemDetailView.swift`), To is renamed after that folder, so it shows what's being synced instead of a placeholder like `NativeInstruments-2`.

- The name comes from `RecipeInstaller.destination(appName:from:)` (`Takeover/Views/RecipesView.swift`): the app's name plus the folder's name (`Ableton-UserLibrary`), or just the app's name when the folder is named after the app.
- To is left alone when it's an absolute or `~` path the user chose, or when the location was already linked (an installed destination never moves).
- Tests: `destinationNamedAfterPickedFolder` in `TakeoverTests/TakeoverTests.swift`.

## Known limits

- Doesn't check whether another location already uses the same To name.

## History

- Implemented 2026-11-15. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
