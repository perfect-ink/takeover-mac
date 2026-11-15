//
//  TakeoverTests.swift
//  TakeoverTests
//
//  Created by Alex Vaos on 2/12/25.
//

import Foundation
import Testing
@testable import Takeover

struct TakeoverTests {

    @Test func sourceExistsForPathsOnThisMac() {
        #expect(LinkItemInstaller.sourceExists("/Library"))
        #expect(LinkItemInstaller.sourceExists("~"))
        #expect(LinkItemInstaller.sourceExists(""))
    }

    @Test func sourceMissingForPathsNotOnThisMac() {
        #expect(!LinkItemInstaller.sourceExists("/Library/Application Support/takeover-test-\(UUID().uuidString)"))
    }

}
