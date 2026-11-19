# Keep Mac defaults applied

The Mac defaults a user picks (the ones with a value in `mac-defaults.yaml` in their settings folder) are checked against the system at login and re-applied whenever that file changes, including changes synced from another Mac through iCloud Drive, Dropbox, a synced folder or Takeover Cloud. Defaults without a value are never touched.

## What users see

- **Mac Defaults tab > Keep Applied** switch (on by default). It registers a background helper with macOS, which shows Takeover under System Settings > General > Login Items ("Allow in the Background").
- If macOS needs approval, a line under the bar says so, with an **Open Login Items** button.
- After the helper or app changes something, the same line shows "Last applied <time>: <names>".
- Turning the switch off unregisters the helper and stops all automatic applying, in the app too.

## How it works

- **One binary, two roles.** `TakeoverMain` starts the app, or, when launchd passes `--defaults-agent`, `DefaultsAgent`: no window or Dock icon, runs for the whole login session.
- **Registration.** `BackgroundAgent` registers `Takeover/LaunchAgents/org.perfectink.takeover.DefaultsAgent.plist` (copied to `Takeover.app/Contents/Library/LaunchAgents` by the "Embed Launch Agents" build phase) with `SMAppService.agent`. The plist has `RunAtLoad` (login) and restarts the helper if it crashes. Only a copy in `/Applications` registers itself at launch, so `make dev` builds don't become the login helper; the switch registers any copy.
- **At login / helper start:** `MacDefaultsEnforcer.enforceFile(trigger: .startup)` reads every chosen default (`defaults read`), writes only the ones that differ (bools, ints and floats compare by meaning, so `true` equals `1`), then runs each needed follow-up (`killall Dock`, `killall Finder`…) once.
- **File changes:** `FolderWatcher` (FSEvents) watches the settings folder and the storage choice (`storage.yaml`). A new `mac-defaults.yaml` is applied the same way. Contents already checked are skipped, and so are edits made in this Mac's own Mac Defaults tab (`SettingsManager` marks them in `takeover.macDefaultsLocalWrite`), because typing a value shouldn't restart the Dock on each keystroke; the tab's Apply buttons apply those, and the next login enforces them.
- **Takeover Cloud:** while the app is closed, the helper pulls a newer profile every 3 minutes (`ProfileSyncManager.pullIfNewer`, never pushes). The pull rewrites the files, which the watcher then applies. While the app is open, the app does its own pulls.
- **App open:** `SettingsDiskWatcher` reloads the app's lists when the settings files change underneath it (another Mac, or the helper's pull), so the app never saves a stale copy back. If the helper isn't running (not approved yet, debug build), the app also applies defaults at launch, after a storage choice, and on file changes.
- **Which defaults:** catalog defaults take their domain/key/type/follow-up from the catalog (same as the tab); custom ones use their own. Catalog defaults the catalog hides on this macOS version are skipped.
- **Restore:** Apply All in the Restore tab applies picked defaults through `MacDefaultsEnforcer.enforce(_ configs:)` too, so they show "applied" or "already set" and each follow-up runs once.

Logs: `log stream --predicate 'subsystem == "org.perfectink.takeover"'` (categories `defaults-agent` and `mac-defaults`).

## Tests

`TakeoverTests`: which defaults resolve (only picked ones, catalog metadata wins, unsupported skipped, host flag order), value comparison, one follow-up per command, watcher file matching, stable fingerprints. CI runs `make test` and checks the launch agent plist is inside the built app.

## Known limits

- Some defaults only take effect after the affected app restarts or the user logs out; only the follow-up commands from the catalog are run, never a logout.
- A manual change in System Settings to a picked default stays until the next login or the next change to `mac-defaults.yaml`, which puts the saved value back. Capture it in the tab to keep it.
- Not verified on a Mac yet (written in a Linux session): SMAppService approval flow, FSEvents on iCloud/Dropbox folders, and the ad hoc signed build registering the helper.

## History

- Implemented 2026-11-15, requested by Alex ("Mac defaults should also sync... at computer startup check... a daemon should catch it"). Compiled and unit tested by GitHub Actions; not yet run on a Mac or in a release.
