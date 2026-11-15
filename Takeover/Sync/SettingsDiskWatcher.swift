import Foundation

extension Notification.Name {
    /// The settings files changed outside this app (another Mac through
    /// iCloud/Dropbox, or the background agent pulling from Takeover Cloud).
    /// `object` is the reloaded `SettingsYaml`; the app replaces its lists.
    static let settingsChangedOnDisk = Notification.Name("settingsChangedOnDisk")
}

/// While the app is open: reloads the lists when the settings folder
/// changes underneath it, so it never saves a stale copy back over a newer
/// one, and applies changed Mac defaults itself when the background agent
/// isn't running (not allowed yet, or a debug build).
@MainActor
final class SettingsDiskWatcher {
    static let shared = SettingsDiskWatcher()

    private var watcher: FolderWatcher?
    private var watchedFolder: String?

    private init() {}

    /// Starts watching the current settings folder, or moves the watch after
    /// the storage choice changed. Safe to call repeatedly.
    func start() {
        let folder = SettingsManager.shared.storageDirectoryURL.path
        guard folder != watchedFolder else { return }
        watcher?.stop()
        watchedFolder = folder
        watcher = FolderWatcher(
            folders: [folder],
            fileNames: [SettingsManager.fileName, SettingsManager.macDefaultsFileName]
        ) {
            Task { @MainActor in await SettingsDiskWatcher.shared.filesChanged() }
        }
        watcher?.start()
    }

    private func filesChanged() async {
        // Before the reload check: a profile this app just pulled from the
        // account is its own write, but its defaults still need applying.
        BackgroundAgent.shared.refresh()
        if BackgroundAgent.shared.appShouldApply {
            MacDefaultsEnforcer.enforceFile(trigger: .fileChanged)
        }

        guard SettingsManager.shared.hasChangedOnDisk else { return }
        do {
            let settings = try await SettingsManager.shared.loadSettings()
            NotificationCenter.default.post(name: .settingsChangedOnDisk, object: settings)
        } catch {
            print("Couldn't reload changed settings: \(error)")
        }
    }
}
