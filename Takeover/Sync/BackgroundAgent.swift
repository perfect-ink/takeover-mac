import Foundation
import ServiceManagement

/// The "Keep Applied" switch in the Mac Defaults tab: registers the
/// background agent (LaunchAgents/alexvaos.Takeover.DefaultsAgent.plist,
/// run by DefaultsAgent) with launchd through SMAppService, so chosen Mac
/// defaults are checked at login and re-applied when the settings file
/// changes, even while Takeover is closed. On by default.
@MainActor
final class BackgroundAgent: ObservableObject {
    static let shared = BackgroundAgent()
    static let plistName = "alexvaos.Takeover.DefaultsAgent.plist"
    private static let turnedOffKey = "takeover.keepMacDefaultsAppliedOff"

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    private init() {
        refresh()
    }

    /// The user's switch; on unless they turned it off.
    var isTurnedOn: Bool {
        !UserDefaults.standard.bool(forKey: Self.turnedOffKey)
    }

    /// launchd is running the agent, so the app leaves applying to it.
    var isRunningInBackground: Bool {
        status == .enabled
    }

    /// Turned on, but macOS is waiting for the user to allow it in
    /// System Settings > General > Login Items.
    var needsApproval: Bool {
        isTurnedOn && status == .requiresApproval
    }

    /// Whether the app itself should apply defaults (at launch and on file
    /// changes) because the agent can't.
    var appShouldApply: Bool {
        isTurnedOn && !isRunningInBackground
    }

    func refresh() {
        status = service.status
    }

    /// Called at launch. Only an installed copy registers itself, so a debug
    /// build never becomes the login agent; the switch still works there.
    func registerIfNeeded() {
        refresh()
        guard isTurnedOn, status == .notRegistered || status == .notFound else { return }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        register()
    }

    func setTurnedOn(_ on: Bool) {
        objectWillChange.send()
        UserDefaults.standard.set(!on, forKey: Self.turnedOffKey)
        if on { register() } else { unregister() }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = "Couldn't start the background helper: \(error.localizedDescription)"
        }
        refresh()
    }

    private func unregister() {
        do {
            try service.unregister()
            lastError = nil
        } catch {
            // Already gone is fine.
            if service.status != .notRegistered {
                lastError = "Couldn't stop the background helper: \(error.localizedDescription)"
            }
        }
        refresh()
    }
}
