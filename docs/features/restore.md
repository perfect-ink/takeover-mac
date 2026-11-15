# Restore

Sets up a Mac from settings built up on another one: app settings (sync settings / links), Mac defaults, installers and apps. The goal is that a brand-new Mac can be restored quickly.

## What users see

The **Restore** tab (`Takeover/Views/RestoreView.swift`) has a source list on the left and what that source holds on the right.

- **Folders:** every Takeover settings folder found on this Mac (iCloud Drive, Dropbox, other cloud drives, plain folders; `StorageLocation.detectExisting()`), with the one in use marked. **Choose Folder** adds any other folder. No account is needed.
- **Takeover Cloud:** when signed in, the account's Macs (their pushed profiles).
- **Apply All** applies every Mac default, sync setting and installer, and installs only the apps marked **Always Install** (`always_install`). Apps without it are listed unchecked and can be picked by hand.
- **Apply Selected** applies just the checked rows. Each row shows its result (applied, linked, added, installed, or the error).
- Applying from a folder that isn't the current settings folder first makes it this Mac's settings folder (sync settings link into it), and says so before you apply.

## Code

- `SettingsManager.read(folder:)` (`Shared/Models/SettingsYaml.swift`) reads `takeover-settings.yaml` and `mac-defaults.yaml` from any folder without changing it; `Profile(settings:catalog:)` turns that into the same `Profile` the account uses.
- `StorageLocation.forFolder(_:)` maps a picked folder to iCloud Drive, Dropbox or a plain folder choice.
- Applying: `MacDefaultInstaller.apply`, `LinkItemInstaller.install`, `AppRestoreEngine.install`; rows are upserted into the local lists.
- `alwaysInstall` lives on `AppEntryModel`, `AppEntryConfig` (`always_install` in the settings file) and `Profile.AppEntry`.

## Known limits

- Mac App Store apps are listed but not installed (`AppRestoreEngine`).
- A restore applies values; it doesn't remove settings on this Mac that the source lacks.

## History

- Implemented 2026-11-15, requested by Alex ("Restore should allow the user to point to an existing takeover folder and to apply all settings"; "Apps would only be installed if they were selected as always install"). Replaces the Takeover Cloud-only Restore. The Always Install toggle itself comes from the app cards work. Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
