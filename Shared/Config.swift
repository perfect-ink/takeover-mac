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
