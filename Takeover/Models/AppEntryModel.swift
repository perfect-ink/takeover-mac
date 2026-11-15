import Foundation
import SwiftData

/// One app in the "restore list" — what gets synced in the profile and
/// (re)installed on another Mac. Distinct from `AppInstaller`, which is just the
/// local folder the Applications tab scans.
@Model
final class AppEntryModel: Identifiable {
    var name: String
    /// `Profile.AppSource` raw value: "brew" | "local" | "mas".
    var source: String
    /// Homebrew cask id, when source == "brew".
    var cask: String
    /// App Store id, when source == "mas" (reserved; not acted on yet).
    var masID: String
    /// Installed automatically when restoring a new Mac (Restore > Apply
    /// All). Apps without it are listed but left for the user to pick.
    var alwaysInstall: Bool = false

    init(name: String = "", source: String = "brew", cask: String = "", masID: String = "",
         alwaysInstall: Bool = false) {
        self.name = name
        self.source = source
        self.cask = cask
        self.masID = masID
        self.alwaysInstall = alwaysInstall
    }

    var config: AppEntryConfig {
        AppEntryConfig(name: name, source: source,
                       cask: cask.isEmpty ? nil : cask,
                       masID: masID.isEmpty ? nil : masID,
                       alwaysInstall: alwaysInstall)
    }
}

extension AppEntryModel {
    /// Saves the restore list locally and writes it to the synced settings
    /// (`apps:`), which carries each app's Always install flag.
    @MainActor
    static func saveRestoreList(in context: ModelContext) {
        try? context.save()
        let entries = (try? context.fetch(FetchDescriptor<AppEntryModel>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let configs = entries.map(\.config)
        Task { @MainActor in
            guard var settings = SettingsManager.shared.settings else { return }
            settings.apps = configs
            try? await SettingsManager.shared.saveSettings(settings)
        }
    }
}
