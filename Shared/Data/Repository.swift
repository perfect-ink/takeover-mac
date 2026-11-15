//
//  Repository.swift
//  Takeover
//
//  Created by Alex Vaos on 11/7/25.
//

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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let pathString = try? container.decode(String.self) {
            // Handle string format: "/Library/Audio/Plug-Ins"
            self.path = pathString
        } else {
            // Handle object format: {"path": "~/.ssh"}
            let fileObject = try decoder.container(keyedBy: CodingKeys.self)
            self.path = try fileObject.decode(String.self, forKey: .path)
        }
    }

    enum CodingKeys: String, CodingKey {
        case path
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
            response = RepositoryResponse(version: loaded.version, os_recipies: loaded.os_recipies, apps: Self.mergingVariants(apps))
        } catch let fetchError {
            error = fetchError
        }
    }
}
