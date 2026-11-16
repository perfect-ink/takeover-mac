import AppKit
import Foundation
import os

/// The background half of Takeover: launchd starts the app's own binary
/// with `--defaults-agent` at login (see BackgroundAgent and the bundled
/// launch agent plist). No window, no Dock icon. It:
///
/// 1. checks every chosen Mac default against the system at start (login)
///    and applies the ones that differ,
/// 2. watches `mac-defaults.yaml` in the chosen settings folder (and the
///    storage choice itself) and applies changes synced from another Mac,
/// 3. backs up /Library locations' local folders into the settings folder
///    (see LocalStoreSync) while the app is closed,
/// 4. with Takeover Cloud, pulls a newer profile from the account every few
///    minutes while the app is closed (the open app does its own pulls),
///    which rewrites the file and so gets applied by (2).
@MainActor
final class DefaultsAgent {
    static let launchArgument = "--defaults-agent"
    static let shared = DefaultsAgent()

    private let log = Logger(subsystem: "alexvaos.Takeover", category: "defaults-agent")
    private var watcher: FolderWatcher?
    private var watchedFolder: String?

    private init() {}

    /// Runs the agent for the life of the process.
    nonisolated static func run() -> Never {
        Task { @MainActor in await DefaultsAgent.shared.start() }
        dispatchMain()
    }

    private func start() async {
        log.info("Started")
        do {
            try await MacDefaultCatalog.shared.load()
        } catch {
            log.error("Catalog unavailable: \(error.localizedDescription, privacy: .public)")
        }
        watch()
        MacDefaultsEnforcer.enforceFile(trigger: .startup)

        // While the app is closed, keep /Library locations backed up too.
        Task { await LocalStoreSync.keepBackedUp { !Self.appIsOpen } }

        while !Task.isCancelled {
            await pullFromCloudIfNeeded()
            try? await Task.sleep(nanoseconds: ProfileSyncManager.pullInterval)
        }
    }

    /// Watches the settings folder plus the folder holding the storage
    /// choice, so switching storage in the app moves the watch along.
    private func watch() {
        let folder = SettingsManager.shared.storageDirectoryURL.path
        guard folder != watchedFolder else { return }
        watcher?.stop()
        watchedFolder = folder
        let pointerFolder = (StorageLocation.pointerFilePath as NSString).deletingLastPathComponent
        let pointerName = (StorageLocation.pointerFilePath as NSString).lastPathComponent
        watcher = FolderWatcher(
            folders: [folder, pointerFolder],
            fileNames: [SettingsManager.macDefaultsFileName, pointerName]
        ) {
            Task { @MainActor in DefaultsAgent.shared.filesChanged() }
        }
        watcher?.start()
        log.info("Watching \(folder, privacy: .public)")
    }

    private func filesChanged() {
        StorageLocation.reloadFromDisk()
        let location = StorageLocation.current
        if location != SettingsManager.shared.location {
            SettingsManager.shared.location = location
            watch()
        }
        MacDefaultsEnforcer.enforceFile(trigger: .fileChanged)
    }

    private func pullFromCloudIfNeeded() async {
        guard StorageLocation.load()?.provider == .takeoverCloud, !Self.appIsOpen else { return }
        if APIClient.isSignedIn && !AccountManager.shared.isSignedIn {
            await AccountManager.shared.refresh()
        }
        guard AccountManager.shared.isSignedIn else { return }
        if SettingsManager.shared.settings == nil {
            _ = try? await SettingsManager.shared.loadSettings()
        }
        if await ProfileSyncManager.shared.pullIfNewer() {
            log.info("Pulled newer settings from Takeover Cloud")
        }
    }

    /// The Takeover app (not this agent) is running.
    private static var appIsOpen: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me }
    }
}
