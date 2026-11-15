# Self Service apps

The Applications tab is a Self Service style catalog: a grid of app cards the user can install with one click, built up over time so a new Mac can be restored quickly.

## What users see

- **Cards.** Each card shows the app's real icon, its name, a short line and its buttons. An app that isn't installed shows **Install**. An installed app shows **Open** and **Uninstall** (Uninstall asks first). The short line says how the app installs ("Installs from a disk image", "Installs with Homebrew (arc)") or, once installed, which version is installed.
- **Where cards come from.** Installer files (`.dmg`, `.zip`, `.pkg`, `.app`) in the installers folder picked with Browse, plus Homebrew apps on the restore list (below the grid). A Homebrew app with the same name as an installer file shows once, as the installer.
- **Always install.** Each card, and each restore-list row, has an **Always install** checkbox. Restore's Apply All installs only apps marked this way (see [restore.md](restore.md)); the rest stay listed for picking by hand. Checking it on an installer-folder app that isn't on the restore list yet adds it there as a local installer.
- **Icons.** Installed apps and `.app` files show their own icon. For apps not installed yet, the icon is read from the `.zip` (straight out of the archive) or `.dmg` (mounted read-only, then unmounted), or for Homebrew apps downloaded from the cask homepage's apple-touch-icon. Icons are cached in `~/Library/Caches/Takeover/AppIcons`, keyed by installer file name, size and date, so each installer is opened once. `.pkg` installers and anything without a findable icon show a generic app icon.
- **Context menu.** Reveal the installer, or show the installed app, in Finder.
- The refresh button rescans the folder and asks Homebrew what it has installed.

## Code

- `Takeover/Models/AppCard.swift`: `AppCard` (card list and subtitle, pure) and `InstalledApps` (finds `<name>.app` in `/Applications` and `~/Applications`, reads its version).
- `Takeover/Views/AppInstallerListView.swift`: `AppInstallerContentView` (grid, install state, actions) and `AppCardView` (one card). The restore list editor stays in the same file.
- `Takeover/Lib/AppIconLoader.swift`: finds and caches icons for apps that aren't installed.
- Installs use `AppInstallerEngine` for installer files and `AppRestoreEngine` for Homebrew (`installedCasks()`, `uninstallCask(_:)`). Installs and scans run off the main thread.
- Always install is `AppEntryModel.alwaysInstall`, saved in the synced settings as `always_install` on each `apps:` entry (`AppEntryConfig`, `Profile.AppEntry`). Missing means off. `AppEntryModel.saveRestoreList(in:)` writes the restore list to settings.

## Tests

`TakeoverTests`: `appCardsMergeInstallersAndHomebrewApps`, `appCardSubtitleSaysHowItInstalls`, `alwaysInstallRoundTripsAndDefaultsOff`, `touchIconLinksResolveAgainstThePage`.

## Known limits

- An installed Homebrew app whose `.app` name differs from its restore-list name shows Uninstall but no Open.
- A `.pkg` install is detected only when it puts `<installer name>.app` in Applications.
- Mac App Store apps aren't shown as cards yet.
- `.pkg` installers aren't opened for their icon, since their payloads can be large.
- A Homebrew app whose homepage has no apple-touch-icon shows the generic icon until it's installed. Website icons can differ from the app's own icon.

## History

- Implemented 2026-11-15, requested by Alex ("Installing apps should feel like self-service. Cards of apps to install. If that app is already installed, show buttons for open and uninstall", and "Apps would only be installed if they were selected as always install"). Real icons for apps not yet installed added the same day ("Can the cards in apps have the app icons?"). Replaces the plain installer list and its Install All button. Not compiled or run locally (Linux session); the GitHub Actions build on main compiles it, but doesn't run the tests. Not yet in a release.
