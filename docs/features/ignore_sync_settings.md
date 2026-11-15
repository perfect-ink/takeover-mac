# Ignore sync settings

Any app in the Sync Settings sidebar can be ignored: right-click it and choose **Ignore**, or use the **Ignore** button next to its name in the detail view.

- An ignored app leaves the sidebar's groups. With Show All on it's listed under **Ignored** at the bottom, where **Stop Ignoring** (same two places) brings it back.
- Ignoring only hides the app; its locations, links and synced files are left as they are.
- The list of ignored app names is saved in the settings file as `ignored_sync_settings` (`SettingsYaml.ignoredSyncSettings`), so other Macs using the same settings folder (iCloud, Dropbox, a folder) hide them too. Takeover Cloud carries it in the Mac's profile (`Profile.ignoredSyncSettings`, JSON key `ignored_sync_settings`; the server stores profiles as-is). A profile from an older build without the key keeps this Mac's list.

## Known limits

- Restore's Apply All doesn't look at it.
- Not compiled or run locally (Linux session); the GitHub Actions build compiles it.

## History

- Implemented 2026-11-15, requested by Alex. Not yet in a release.
