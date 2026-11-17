//
//  CatalogVersionTests.swift
//  TakeoverTests
//
//  Catalog files carry a `version` (their revision); the app keeps the copy
//  with the highest one.
//

import Foundation
import Testing
@testable import Takeover

struct CatalogVersionTests {

    @Test func macDefaultsCatalogDecodesVersionedAndBareFiles() throws {
        let versioned = """
        version: 3
        defaults:
          - name: Dark Mode
            domain: NSGlobalDomain
            key: AppleInterfaceStyle
            type: string
        """
        let file = try RemoteCatalog.decode(MacDefaultsCatalogFile.self, from: Data(versioned.utf8))
        #expect(file.version == 3)
        #expect(file.defaults.map(\.name) == ["Dark Mode"])

        // The API's JSON has the same shape.
        let json = #"{"version": 4, "defaults": [{"name": "A", "domain": "d", "key": "k", "type": "bool"}]}"#
        #expect(try RemoteCatalog.decode(MacDefaultsCatalogFile.self, from: Data(json.utf8)).version == 4)

        // A cache from before catalogs had versions still loads, as version 0.
        let bare = """
        - name: Dark Mode
          domain: NSGlobalDomain
          key: AppleInterfaceStyle
          type: string
        """
        let old = try RemoteCatalog.decode(MacDefaultsCatalogFile.self, from: Data(bare.utf8))
        #expect(old.version == 0)
        #expect(old.defaults.count == 1)
    }

    @Test func newestCopyWins() {
        let cached = RepositoryResponse(version: 2, os_recipies: nil, apps: [])
        let bundled = RepositoryResponse(version: 5, os_recipies: nil, apps: [])
        let fetched = RepositoryResponse(version: 5, os_recipies: [], apps: [])
        #expect(RemoteCatalog.newest(cached, bundled)?.version == 5)
        #expect(RemoteCatalog.newest(nil, cached)?.version == 2)
        #expect(RemoteCatalog.newest(fetched, bundled)?.os_recipies != nil) // a tie keeps the first
        #expect(RemoteCatalog.newest(nil as RepositoryResponse?, nil) == nil)
    }

    /// Unit tests run inside the app, so Bundle.main is Takeover.app.
    @Test func bundledCatalogsHaveVersions() throws {
        let apps = try #require(Bundle.main.url(forResource: "apps-catalog", withExtension: "yaml"))
        let defaults = try #require(Bundle.main.url(forResource: "mac-defaults-catalog", withExtension: "yaml"))
        #expect(try RemoteCatalog.decode(RepositoryResponse.self, from: Data(contentsOf: apps)).version >= 1)
        #expect(try RemoteCatalog.decode(MacDefaultsCatalogFile.self, from: Data(contentsOf: defaults)).version >= 1)
    }
}
