# Installed apps filter

The Sync Settings sidebar (`Takeover/Views/LinkItemListView.swift`) lists only apps that are on this Mac by default. A **Show All** toggle at the top of the sidebar, next to Refresh, also shows the rest, greyed out and sorted last as before. The choice is remembered (`@AppStorage("syncSettings.showAll")`).

- "On this Mac" is `AppGroup.installed`, from `RecipeInstaller.isInstalled`: an app bundle with the app's name in /Applications (or ~/Applications, Utilities, System), or any of its locations' source paths existing.
- While filtering, an app also stays listed when it's selected or has a location with no From yet, so one you're setting up doesn't disappear.
- When nothing is installed, the sidebar says "No apps found on this Mac" with a Show All button.
- The toggle's tooltip says how many apps are hidden.

## Known limits

- No unit test: the filter is view state. Not checked in a running app.

## History

- Implemented 2026-11-15, requested by Alex. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
