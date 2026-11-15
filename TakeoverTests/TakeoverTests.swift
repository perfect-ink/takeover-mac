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

    @Test func destinationNamedAfterPickedFolder() {
        #expect(RecipeInstaller.destination(appName: "Native Instruments", from: "/Library/Application Support/Native Instruments") == "NativeInstruments")
        #expect(RecipeInstaller.destination(appName: "Ableton (2)", from: "~/Music/Ableton/User Library") == "Ableton-UserLibrary")
    }

    @Test func distinguishingPartIsWhereThePathsDiffer() {
        #expect(RecipeInstaller.distinguishingPart(of: "~/Library/Audio/Plug-Ins", from: "/Library/Audio/Plug-Ins") == "User")
        #expect(RecipeInstaller.distinguishingPart(of: "/Library/Audio/Plug-Ins", from: "~/Library/Audio/Plug-Ins") == "System")
        #expect(RecipeInstaller.distinguishingPart(of: "/Volumes/Samples/Kontakt/Presets", from: "~/Documents/Kontakt/Presets") == "Samples")
    }

    @Test func sourceMissingForPathsNotOnThisMac() {
        #expect(!LinkItemInstaller.sourceExists("/Library/Application Support/takeover-test-\(UUID().uuidString)"))
    }

}
