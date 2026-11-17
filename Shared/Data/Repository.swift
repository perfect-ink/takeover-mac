//
//  Repository.swift
//  Takeover
//
//  Created by Alex Vaos on 11/7/25.
//

import Darwin
import Foundation
import Observation

struct RepositoryResponse: Decodable {
    let version: Int
    let os_recipies: [OSRecipe]?
    let apps: [AppConfig]

    enum CodingKeys: String, CodingKey {
        case version
        case os_recipies
        case apps
    }
}

struct OSRecipe: Decodable, Identifiable {
    let id = UUID()
    let name: String
    let defaults: String

    enum CodingKeys: String, CodingKey {
        case name
        case defaults
    }
}

struct AppConfig: Decodable, Identifiable {
    let id = UUID()
    let name: String
    let files: [FileConfig]
    let defaults: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case files
        case defaults
    }
}

struct FileConfig: Decodable {
    let path: String
    /// The location's name, which is also its folder inside the app's folder.
    /// Optional: without it the path's last component is used.
    let name: String?

    init(path: String, name: String? = nil) {
        self.path = path
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let pathString = try? container.decode(String.self) {
            // Handle string format: "/Library/Audio/Plug-Ins"
            self.path = pathString
            self.name = nil
        } else {
            // Handle object format: {"path": "~/.ssh", "name": "SSH"}
            let fileObject = try decoder.container(keyedBy: CodingKeys.self)
            self.path = try fileObject.decode(String.self, forKey: .path)
            self.name = try fileObject.decodeIfPresent(String.self, forKey: .name)
        }
    }

    enum CodingKeys: String, CodingKey {
        case path, name
    }
}

@Observable
class Repository {
    static let shared = Repository()

    private(set) var response: RepositoryResponse?
    private(set) var isLoading = false
    private(set) var error: Error?

    /// Prefer the API repository, with the published catalog as a fallback.
    private var sources: [URL] {
        [URL(string: "\(APIClient.baseURL)/repository")!, RemoteCatalog.catalogURL("apps.yaml")]
    }

    private init() {}

    /// Folds "X (Users)" entries into "X" as extra locations, so an app is one
    /// entry however the catalog (or an older cached copy) lists it.
    static func mergingVariants(_ apps: [AppConfig]) -> [AppConfig] {
        func base(_ name: String) -> String {
            name.hasSuffix(" (Users)") ? String(name.dropLast(" (Users)".count)) : name
        }
        var order: [String] = []
        var merged: [String: AppConfig] = [:]
        for app in apps {
            let key = base(app.name)
            if let existing = merged[key] {
                var files = existing.files
                for file in app.files where !files.contains(where: { $0.path == file.path }) { files.append(file) }
                merged[key] = AppConfig(name: key, files: files, defaults: existing.defaults ?? app.defaults)
            } else {
                order.append(key)
                merged[key] = AppConfig(name: key, files: app.files, defaults: app.defaults)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Turns each location whose path has a `*` (e.g. every installed Ableton
    /// Live version's Themes folder) into one location per match on this Mac,
    /// with each `*` in its name replaced by the matching text. A pattern with
    /// no match is left out, since there's nothing to link here. `matches`
    /// returns the existing paths for an expanded (no tilde) pattern.
    static func expandingWildcards(_ apps: [AppConfig], matches: (String) -> [String] = Repository.globPaths) -> [AppConfig] {
        apps.map { app in
            var files: [FileConfig] = []
            for file in app.files {
                guard file.path.contains("*") else { files.append(file); continue }
                for match in matches(PathUtility.expandTildeToRealHome(file.path)).sorted() {
                    let path = file.path.hasPrefix("~") ? PathUtility.abbreviateRealHome(match) : match
                    guard !files.contains(where: { $0.path == path }) else { continue }
                    files.append(FileConfig(path: path, name: file.name.map { wildcardName($0, pattern: file.path, path: path) }))
                }
            }
            return AppConfig(name: app.name, files: files, defaults: app.defaults)
        }
    }

    /// "Ableton Live * Themes" for "/Applications/Ableton Live 12
    /// Suite.app/..." matched by "/Applications/Ableton Live *.app/..." is
    /// "Ableton Live 12 Suite Themes": each `*` in the name takes the
    /// text the path's `*`s matched, in order.
    static func wildcardName(_ name: String, pattern: String, path: String) -> String {
        let regex = "^" + pattern.components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "([^/]*)") + "$"
        guard let re = try? NSRegularExpression(pattern: regex),
              let m = re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path))
        else { return name.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
        let captures = (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: path).map { String(path[$0]) } }
        var parts = name.components(separatedBy: "*")
        var result = parts.removeFirst()
        for (i, part) in parts.enumerated() { result += (i < captures.count ? captures[i] : "") + part }
        return result
    }

    /// Existing paths matching a shell-style pattern (glob(3)).
    static func globPaths(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// The fetched catalog plus any app only the bundled copy has, so a server
    /// that's behind the app's build never hides recipes the build ships with.
    static func addingBundled(to apps: [AppConfig]) -> [AppConfig] {
        guard let url = Bundle.main.url(forResource: "apps-catalog", withExtension: "yaml"),
              let data = try? Data(contentsOf: url),
              let bundled = try? RemoteCatalog.decode(RepositoryResponse.self, from: data)
        else { return apps }
        let names = Set(apps.map { $0.name })
        return apps + bundled.apps.filter { !names.contains($0.name) }
    }

    func load(force: Bool = false) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let loaded = try await RemoteCatalog.load(
                RepositoryResponse.self, sources: sources, cacheName: "apps-catalog",
                bundled: Bundle.main.url(forResource: "apps-catalog", withExtension: "yaml"), force: force)
            let apps = Self.addingBundled(to: loaded.apps)
            response = RepositoryResponse(version: loaded.version, os_recipies: loaded.os_recipies, apps: Self.expandingWildcards(Self.mergingVariants(apps)))
        } catch let fetchError {
            error = fetchError
        }
    }
}
