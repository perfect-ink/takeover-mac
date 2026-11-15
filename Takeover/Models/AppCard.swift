import Foundation

/// One app on the Applications tab's Self Service style grid. Cards come from
/// two places: installer files found in the user's installers folder, and
/// Homebrew apps on the restore list. Pure data plus pure helpers, so the
/// grid view stays thin and the rules here are unit tested.
struct AppCard: Identifiable, Equatable {
    enum Source: Equatable {
        case installer(DiscoveredApp)
        case homebrew(cask: String)
    }

    let name: String
    let source: Source

    var id: String {
        switch source {
        case .installer(let app): return app.id
        case .homebrew(let cask): return "brew:\(cask)"
        }
    }

    /// Folder installers first, then restore-list Homebrew apps that the folder
    /// doesn't already cover (matched by name, ignoring case), sorted by name.
    static func cards(installers: [DiscoveredApp], restoreList: [Profile.AppEntry]) -> [AppCard] {
        var cards = installers.map { AppCard(name: $0.name, source: .installer($0)) }
        var seen = Set(installers.map { $0.name.lowercased() })
        for entry in restoreList where entry.source == .brew {
            let cask = (entry.cask ?? "").trimmingCharacters(in: .whitespaces)
            let key = entry.name.lowercased()
            guard !cask.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            cards.append(AppCard(name: entry.name, source: .homebrew(cask: cask)))
        }
        return cards.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The short line under the app's name.
    static func subtitle(for source: Source, installedVersion: String?) -> String {
        if let version = installedVersion {
            return version.isEmpty ? "Installed" : "Version \(version) installed"
        }
        switch source {
        case .installer(let app): return "Installs from \(app.fileType.sourceDescription)"
        case .homebrew(let cask): return "Installs with Homebrew (\(cask))"
        }
    }
}

/// Finds installed apps by bundle name in the folders apps install to.
enum InstalledApps {
    static var folders: [String] {
        ["/Applications", PathUtility.expandTildeToRealHome("~/Applications")]
    }

    static func url(named name: String) -> URL? {
        for folder in folders {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// CFBundleShortVersionString, or "" when the bundle doesn't say.
    static func version(at url: URL) -> String {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
