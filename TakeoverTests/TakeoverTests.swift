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

    @Test func appCardsMergeInstallersAndHomebrewApps() {
        let dmg = DiscoveredApp(name: "Rectangle", fileURL: URL(fileURLWithPath: "/tmp/Rectangle.dmg"), fileType: .dmg)
        let cards = AppCard.cards(installers: [dmg], restoreList: [
            Profile.AppEntry(name: "rectangle", source: .brew, cask: "rectangle"),
            Profile.AppEntry(name: "Arc", source: .brew, cask: "arc"),
            Profile.AppEntry(name: "No Cask", source: .brew),
            Profile.AppEntry(name: "Local Only", source: .local),
        ])
        #expect(cards.map(\.name) == ["Arc", "Rectangle"])
        #expect(cards.first?.source == .homebrew(cask: "arc"))
    }

    @Test func appCardSubtitleSaysHowItInstalls() {
        let pkg = DiscoveredApp(name: "Tool", fileURL: URL(fileURLWithPath: "/tmp/Tool.pkg"), fileType: .pkg)
        #expect(AppCard.subtitle(for: .installer(pkg), installedVersion: nil) == "Installs from an installer package")
        #expect(AppCard.subtitle(for: .homebrew(cask: "arc"), installedVersion: nil) == "Installs with Homebrew (arc)")
        #expect(AppCard.subtitle(for: .installer(pkg), installedVersion: "2.1") == "Version 2.1 installed")
        #expect(AppCard.subtitle(for: .installer(pkg), installedVersion: "") == "Installed")
    }

    @Test func touchIconLinksResolveAgainstThePage() {
        let html = #"<head><link rel="icon" href="/favicon.ico"><link href='/img/touch.png' rel="apple-touch-icon" sizes="180x180"></head>"#
        let links = AppIconLoader.touchIconLinks(in: html, base: URL(string: "https://example.com/app/")!)
        #expect(links.map(\.absoluteString) == ["https://example.com/img/touch.png"])
    }

    @Test func alwaysInstallRoundTripsAndDefaultsOff() throws {
        let off = try JSONDecoder().decode(Profile.AppEntry.self, from: Data(#"{"name":"Arc","source":"brew","cask":"arc"}"#.utf8))
        #expect(!off.alwaysInstall)
        let on = Profile.AppEntry(name: "Arc", source: .brew, cask: "arc", alwaysInstall: true)
        let json = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
        #expect(json.contains(#""always_install":true"#))
        #expect(try JSONDecoder().decode(Profile.AppEntry.self, from: Data(json.utf8)).alwaysInstall)
    }

    @Test func sourceMissingForPathsNotOnThisMac() {
        #expect(!LinkItemInstaller.sourceExists("/Library/Application Support/takeover-test-\(UUID().uuidString)"))
    }

}
