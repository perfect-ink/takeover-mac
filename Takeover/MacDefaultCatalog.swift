import Foundation
import Yams

struct MacDefaultCatalogEntry: Codable {
    let name: String
    let domain: String
    let key: String
    let type: String
    let hostFlag: String?
    let postCommand: String?
    let category: String?
    /// Inclusive macOS major-version range this default applies to; nil means
    /// no bound.
    let minMacOS: Int?
    let maxMacOS: Int?

    enum CodingKeys: String, CodingKey {
        case name, domain, key, type, category
        case hostFlag = "host_flag"
        case postCommand = "post_command"
        case minMacOS = "min_macos"
        case maxMacOS = "max_macos"
    }

    func supports(macOSMajorVersion version: Int) -> Bool {
        if let minMacOS, version < minMacOS { return false }
        if let maxMacOS, version > maxMacOS { return false }
        return true
    }
}

/// mac-defaults.yaml: `{version, defaults: [...]}`. A bare list (the shape
/// before catalogs had versions) decodes as version 0, so any versioned copy
/// beats it.
struct MacDefaultsCatalogFile: Decodable, VersionedCatalog {
    let version: Int
    let defaults: [MacDefaultCatalogEntry]

    enum CodingKeys: String, CodingKey { case version, defaults }

    init(version: Int, defaults: [MacDefaultCatalogEntry]) {
        self.version = version
        self.defaults = defaults
    }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([MacDefaultCatalogEntry].self) {
            self.init(version: 0, defaults: list)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version),
                  defaults: try c.decode([MacDefaultCatalogEntry].self, forKey: .defaults))
    }
}

/// The `defaults write` catalog shown in the Mac Defaults tab. Fetched from
/// takeover-api (GET /api/v1/mac_defaults, same JSON shape as the old bundled
/// YAML), cached for a day, falling back to a stale cache — and, failing
/// that, the bundled YAML — so a fresh install still works offline.
class MacDefaultCatalog {
    static let shared = MacDefaultCatalog()
    private(set) var entries: [MacDefaultCatalogEntry] = []
    /// The loaded catalog's revision; 0 until loaded.
    private(set) var version = 0
    /// Catalog defaults that don't apply to this macOS; never enforced here.
    private(set) var unsupportedNames: Set<String> = []

    private init() {}

    /// Loads the available defaults from takeover-api (cached, with the bundled
    /// catalog as the offline fallback), keeping only those for this macOS.
    func load() async throws {
        let file = try await RemoteCatalog.load(
            MacDefaultsCatalogFile.self,
            sources: [URL(string: "\(APIClient.baseURL)/mac_defaults")!, RemoteCatalog.catalogURL("mac-defaults.yaml")],
            cacheName: "mac-defaults-catalog",
            bundled: Bundle.main.url(forResource: "mac-defaults-catalog", withExtension: "yaml")
        )
        let all = file.defaults
        version = file.version
        let macOS = SystemInfo.macOSMajorVersion
        entries = all.filter { $0.supports(macOSMajorVersion: macOS) }
        let supportedNames = Set(entries.map(\.name))
        unsupportedNames = Set(all.map(\.name)).subtracting(supportedNames)
    }
}
