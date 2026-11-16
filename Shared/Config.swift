import Foundation

struct Config {
    /// The user's chosen settings folder (iCloud, Dropbox, Takeover Cloud's
    /// local copy, or a folder), tilde-prefixed when under home.
    static var backupPath: String {
        StorageLocation.current.rootPath
    }

    static var expandedBackupPath: String {
        PathUtility.expandTildeToRealHome(backupPath)
    }

    /// Where a link's destination lives. A bare name sits inside the settings
    /// folder; a chosen absolute (or ~) path is used as-is, never prefixed.
    static func destinationPath(for to: String) -> String {
        if to.hasPrefix("/") || to.hasPrefix("~") { return to }
        return "\(backupPath)/\(to)"
    }

    static func expandedDestinationPath(for to: String) -> String {
        PathUtility.expandTildeToRealHome(destinationPath(for: to))
    }

    /// Where links from outside the home folder (/Library and the like) point.
    /// macOS doesn't let system services, such as the package installer,
    /// open files in iCloud Drive or Dropbox through a link ("Operation not
    /// permitted"), so those locations keep their files in this local folder,
    /// still as a link, and Takeover backs it up into the settings folder
    /// (see LocalStoreBackup).
    static let localStoreRoot = "/Users/Shared/Takeover"

    /// True for sources outside the home folder, e.g. /Library/Audio/Plug-Ins.
    static func usesLocalStore(from: String) -> Bool {
        guard !from.isEmpty else { return false }
        let source = PathUtility.expandTildeToRealHome(from)
        let home = PathUtility.getRealHomeDirectory()
        return !(source == home || source.hasPrefix(home + "/"))
    }

    /// What the link at `from` points to: the synced copy for home-folder
    /// sources, the same place under `localStoreRoot` for the others. A To
    /// chosen outside the settings folder is used as-is.
    static func linkTargetPath(from: String, to: String) -> String {
        let synced = expandedDestinationPath(for: to)
        guard usesLocalStore(from: from), let relative = settingsRelativePath(synced) else { return synced }
        return "\(localStoreRoot)/\(relative)"
    }

    /// `path` relative to the settings folder, or nil when it isn't inside it.
    static func settingsRelativePath(_ path: String) -> String? {
        let root = (expandedBackupPath as NSString).standardizingPath
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(root + "/") else { return nil }
        return String(standardized.dropFirst(root.count + 1))
    }

    static var settingsPath: String {
        "\(expandedBackupPath)/takeover-settings.yaml"
    }

    static var macDefaultsPath: String {
        "\(expandedBackupPath)/mac-defaults.yaml"
    }

    /// Takeover API: catalogs are static files under `/catalog`, accounts and
    /// sync under `/api/v1`.
    static let apiBaseURL = URL(string: "https://takeoverapp.site")!
}
