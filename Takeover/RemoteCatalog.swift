import Foundation
import Yams

/// A catalog file with a revision number. takeover-site raises `version` by
/// one in every change to a catalog (its CI refuses a change that doesn't).
protocol VersionedCatalog {
    var version: Int { get }
}

/// Fetches a static catalog file published by takeover-site (served from its
/// `public/catalog/` folder), keeping a local copy for a week so the app
/// doesn't hit the network on every launch, and falling back to the stale cache
/// and then a bundled copy when offline. Whichever copy it ends up with, a
/// bundled copy with a higher version wins, so an app update that ships a newer
/// catalog isn't held back by an older cache (or a server not yet deployed).
enum RemoteCatalog {
    static let cacheDuration: TimeInterval = 7 * 86400 // 1 week
    /// After a failed refresh, don't try again for this long (the stale copy is used).
    static let retryAfterFailure: TimeInterval = 3600 // 1 hour

    static func catalogURL(_ fileName: String) -> URL {
        Config.apiBaseURL.appendingPathComponent("catalog").appendingPathComponent(fileName)
    }

    /// - Parameters:
    ///   - sources: tried in order; YAML or JSON, detected from the content.
    ///   - cacheName: file name under the app's Caches folder.
    ///   - bundled: last-resort copy shipped in the app bundle.
    static func load<T: Decodable & VersionedCatalog>(
        _ type: T.Type,
        sources: [URL],
        cacheName: String,
        bundled: URL? = nil,
        force: Bool = false
    ) async throws -> T {
        let bundledCopy = bundled.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decode(type, from: $0) }
        let fetched = await loadFetchedOrCached(type, sources: sources, cacheName: cacheName, force: force)
        guard let best = newest(fetched, bundledCopy) else { throw URLError(.resourceUnavailable) }
        return best
    }

    /// The copy with the highest version; the first one on a tie.
    static func newest<T: VersionedCatalog>(_ copies: T?...) -> T? {
        var best: T?
        for copy in copies.compactMap({ $0 }) where best == nil || copy.version > best!.version {
            best = copy
        }
        return best
    }

    /// The fresh cache, else a fetched copy, else the stale cache; nil when
    /// none of them can be had.
    private static func loadFetchedOrCached<T: Decodable & VersionedCatalog>(
        _ type: T.Type, sources: [URL], cacheName: String, force: Bool
    ) async -> T? {
        let cacheURL = cacheDirectory.appendingPathComponent(cacheName)
        let failureMarker = cacheDirectory.appendingPathComponent(cacheName + ".failed")
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? decode(type, from: $0) }

        // A recent failed refresh with a usable cache: stay local, don't hammer the API.
        if !force, isFresh(failureMarker, maxAge: retryAfterFailure), let cached {
            return cached
        }

        if !force, isFresh(cacheURL), let cached {
            return cached
        }

        var lastError: Error?
        for url in sources {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8 // fail over to the next source quickly
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let decoded = try decode(type, from: data)
                // A server behind the cache (a rollback, a stale mirror) doesn't
                // replace a newer catalog this Mac already has.
                if let cached, cached.version > decoded.version {
                    touch(cacheURL)
                    return cached
                }
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? data.write(to: cacheURL)
                try? FileManager.default.removeItem(at: failureMarker)
                return decoded
            } catch {
                print("Catalog fetch failed for \(url): \(error)")
                lastError = error
            }
        }

        if let cached {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? Data().write(to: failureMarker)
            return cached
        }
        if let lastError { print("No catalog copy for \(cacheName): \(lastError)") }
        return nil
    }

    /// Restarts a file's cache week.
    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let text = String(data: data, encoding: .utf8) ?? ""
        let first = text.first { !$0.isWhitespace }
        if first == "{" || first == "[" {
            return try JSONDecoder().decode(type, from: data)
        }
        return try YAMLDecoder().decode(type, from: text)
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takeover", isDirectory: true)
    }

    private static func isFresh(_ url: URL, maxAge: TimeInterval = cacheDuration) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modified) < maxAge
    }
}
