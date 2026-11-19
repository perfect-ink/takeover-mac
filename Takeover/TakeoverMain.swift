import SwiftUI

/// One binary, two roles: the app, or (when launchd passes
/// `--defaults-agent`) the background agent that keeps chosen Mac defaults
/// applied. See DefaultsAgent.
@main
enum TakeoverMain {
    @MainActor
    static func main() {
        LegacyBundleIDMigration.run(legacyID: "alexvaos.Takeover")
        if CommandLine.arguments.contains(DefaultsAgent.launchArgument) {
            DefaultsAgent.run()
        } else {
            TakeoverApp.main()
        }
    }
}

/// The bundle ID moved to org.perfectink.* in November 2026, and preferences
/// are stored under the bundle ID. On the first launch under the new ID, copy
/// the old domain's values across so nobody loses their settings. Values
/// already saved under the new ID win, and it runs only once.
enum LegacyBundleIDMigration {
    static let doneKey = "perfectink.migratedLegacyBundleID"

    static func run(legacyID: String,
                    currentID: String? = Bundle.main.bundleIdentifier,
                    defaults: UserDefaults = .standard) {
        guard let currentID, currentID != legacyID,
              !defaults.bool(forKey: doneKey) else { return }
        let existing = defaults.persistentDomain(forName: currentID) ?? [:]
        let legacy = defaults.persistentDomain(forName: legacyID) ?? [:]
        for (key, value) in legacy where existing[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }
}
