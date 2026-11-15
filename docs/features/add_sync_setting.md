# Add a sync setting

The **Add** (+) button at the top of the Sync Settings sidebar (`addSyncSetting()` in `Takeover/Views/LinkItemListView.swift`) adds a sync setting that isn't in the recipe catalog.

- It opens a picker for the folder or file to sync. The new setting is named after it, From is that path (`~`-abbreviated under home), and To comes from `RecipeInstaller.destination(appName:from:others:)`: `Name/Name` in the settings folder (see [sync_destination_folders.md](sync_destination_folders.md)).
- If the name is taken, it gets " (2)" and so on, which adds it as another location of the existing app with that name.
- The new setting is selected and saved to the settings file. Its source exists, so it shows even with the installed-only filter on ([installed_apps_filter.md](installed_apps_filter.md)).
- Rename it from its detail view. Adding another location to an existing app is still the + next to the app's name.

## History

- Implemented 2026-11-15, requested by Alex. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
