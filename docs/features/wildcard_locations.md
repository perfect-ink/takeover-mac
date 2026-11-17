# Wildcard locations

A catalog location's path can use `*` for the part of one path component that
varies from Mac to Mac, such as an app's version and edition. The first use is
Ableton Live's themes, which live inside each Live app:

- `/Applications/Ableton Live *.app/Contents/App-Resources/Themes` (Live 10 and later)
- `/Applications/Ableton Live *.app/Contents/App-Resources/Skins` (Live 9)

## What it does

When the catalog loads (`Repository.load`), `Repository.expandingWildcards`
turns each such location into one location per matching path on this Mac
(glob(3)), in sorted order. Each `*` in the location's name takes the text the
path's `*` matched, so "Ableton Live * Themes" becomes
"Ableton Live 12 Suite Themes" for Live 12 Suite. A pattern with no
match on this Mac is left out; nothing with a `*` ever becomes a sync setting.

The expanded locations are ordinary locations from then on: Sync Settings
seeds them, and Install moves the folder into the settings folder and links
it, always as a symlink. Because they're outside the home folder, they link
into `/Users/Shared/Takeover` like /Library locations (see
[local_store_for_system_locations.md](local_store_for_system_locations.md)).
Each Live version gets its own folder ("Ableton Live/Ableton Live 12
Suite Themes"), since each version ships its own built-in themes.

Who can view or change it: same as any catalog location. The recipes live in
takeover-site's `public/catalog/apps.yaml`; the bundled copy is
`Takeover/apps-catalog.yaml`.

## Tests

`TakeoverTests.wildcardLocationsExpandPerMatch` (expansion and naming, with an
injected matcher).

## Known limits

- Only `*` is a wildcard; it doesn't cross `/`.
- Live updates replace the whole app, so the Themes link is replaced by a
  fresh folder after an update and needs Install again.
- Changing files inside a signed app bundle is what Ableton's own theme
  instructions ask for, but macOS may ask for App Management permission
  (Privacy & Security) before Takeover can link inside /Applications.
- A Mac app build from before this change shows the pattern itself as a
  location whose source isn't on this Mac.

## History

- Implemented 2026-11-16. Swift wasn't compiled or tested in the cloud
  session; the macOS Build workflow on push to main runs the build and
  `make test`. Not tried on a Mac with Live installed.
