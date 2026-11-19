import Foundation

/// Keeps the settings folder's copy of /Library locations current. Those
/// locations link into `Config.localStoreRoot` (macOS won't let installers
/// write into iCloud Drive through a link), so their files only reach the
/// settings folder through this backup. The app runs it at start and every
/// few minutes; the background agent does the same while the app is closed.
/// The same pass copies mirrored folders both ways (see FolderMirror).
enum LocalStoreSync {
    static let interval: UInt64 = 10 * 60 * 1_000_000_000

    private static let queue = DispatchQueue(label: "org.perfectink.takeover.local-store-backup", qos: .utility)

    /// Backs up every linked local-store location in the settings file, off
    /// the main thread and one run at a time.
    static func backUpAll() {
        let folder = Config.backupPath
        queue.async {
            guard let settings = try? SettingsManager.read(folder: folder) else { return }
            for link in settings.links where Config.usesLocalStore(from: link.from) {
                if let error = LocalStoreBackup.backUp(from: link.from, to: link.to) {
                    print(error)
                }
            }
            // Mirrored folders (audio plug-ins and presets) copy both ways.
            FolderMirror.syncAll()
        }
    }

    /// Runs `backUpAll` now and then every `interval`, for the life of the caller's task.
    static func keepBackedUp(while shouldRun: @escaping @MainActor () -> Bool = { true }) async {
        while !Task.isCancelled {
            if await shouldRun() { backUpAll() }
            try? await Task.sleep(nanoseconds: interval)
        }
    }
}
