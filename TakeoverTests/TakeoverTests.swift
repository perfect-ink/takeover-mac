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

    @Test func destinationIsAppFolderThenLocationFolder() {
        #expect(RecipeInstaller.destination(appName: "Ableton (2)", from: "~/Music/Ableton/User Library", others: []) == "Ableton/User Library")
        #expect(RecipeInstaller.destination(appName: "SSH", from: "~/.ssh", others: []) == "SSH/ssh")
        #expect(RecipeInstaller.destination(appName: "Native Instruments", from: "~/Documents/Native Instruments", named: "Documents", others: []) == "Native Instruments/Documents")
        #expect(RecipeInstaller.destination(appName: "Audio Plug-Ins (Users)", from: "~/Library/Audio/Plug-Ins", named: "User Plug-Ins", others: []) == "Audio Plug-Ins/User Plug-Ins")
    }

    @Test func clashingLocationsGetTheDifferingPart() {
        let system = LinkItem(name: "Audio Plug-Ins", from: "/Library/Audio/Plug-Ins", to: "Audio Plug-Ins/Plug-Ins")
        #expect(RecipeInstaller.destination(appName: "Audio Plug-Ins", from: "~/Library/Audio/Plug-Ins", others: [system]) == "Audio Plug-Ins/Plug-Ins (User)")
    }

    @Test func locationNameMatchesItsDestinationFolder() {
        #expect(RecipeInstaller.displayName(of: LinkItem(name: "Serum", from: "~/Library/Application Support/Xfer", to: "Serum/Application Support")) == "Application Support")
        #expect(RecipeInstaller.displayName(of: LinkItem(name: "X", from: "~/x", to: "/Volumes/Backup/x", label: "Backup")) == "Backup")
        #expect(RecipeInstaller.needsAppFolder(LinkItem(name: "Native Instruments (2)", from: "~/x", to: "NativeInstruments-x")))
        #expect(!RecipeInstaller.needsAppFolder(LinkItem(name: "Native Instruments (2)", from: "~/x", to: "Native Instruments/x")))
    }

    @Test func mergeKeepsBothSidesFilesAndDeletesNothing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let src = root + "/src", dst = root + "/dst"
        try fm.createDirectory(atPath: src, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
        try "mac".write(toFile: src + "/a.txt", atomically: true, encoding: .utf8)
        try "synced".write(toFile: dst + "/b.txt", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: root) }

        try FileOps.merge(from: src, into: dst)

        #expect(try String(contentsOfFile: dst + "/a.txt", encoding: .utf8) == "mac")
        #expect(try String(contentsOfFile: dst + "/b.txt", encoding: .utf8) == "synced")
        #expect(fm.fileExists(atPath: src + "/a.txt"))
    }

    /// Every To change goes through changeDestination: the synced files move
    /// and the source's link follows them, so nothing is left dangling.
    @MainActor @Test func changingToMovesFilesAndRelinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let old = root + "/Takeover/NativeInstruments", new = root + "/Takeover/Native Instruments/Root Application Support"
        let source = root + "/Library/Native Instruments"
        try fm.createDirectory(atPath: old, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/Library", withIntermediateDirectories: true)
        try "kontakt".write(toFile: old + "/prefs.txt", atomically: true, encoding: .utf8)
        // Spelled with different case, as a link made elsewhere might be.
        try fm.createSymbolicLink(atPath: source, withDestinationPath: root + "/Takeover/nativeinstruments")
        let item = LinkItem(name: "Native Instruments", from: source, to: old)
        #expect(LinkItemInstaller.isLinked(item))

        try LinkItemInstaller.changeDestination(of: item, to: new)

        #expect(item.to == new)
        #expect(!fm.fileExists(atPath: old))
        #expect(LinkItemInstaller.isLinked(item))
        #expect(try String(contentsOfFile: source + "/prefs.txt", encoding: .utf8) == "kontakt")
    }

    /// A link already dangling at the old destination is pointed at the new one.
    @MainActor @Test func changingToRepairsALinkToAMissingDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let new = root + "/Takeover/Audio Plug-Ins/Root Audio Plug-Ins"
        try fm.createDirectory(atPath: new, withIntermediateDirectories: true)
        let source = root + "/Plug-Ins"
        try fm.createSymbolicLink(atPath: source, withDestinationPath: root + "/Takeover/AudioPlug-Ins")
        let item = LinkItem(name: "Audio Plug-Ins", from: source, to: root + "/Takeover/AudioPlug-Ins")

        try LinkItemInstaller.changeDestination(of: item, to: new)

        #expect(LinkItemInstaller.isLinked(item))
        #expect(LinkItemInstaller.status(item) == .installed)
    }

    /// /Library locations link into the local store, since macOS won't let
    /// installers write into iCloud Drive through a link; home ones don't.
    @Test func systemLocationsLinkIntoTheLocalStore() {
        #expect(Config.usesLocalStore(from: "/Library/Application Support/Native Instruments"))
        #expect(!Config.usesLocalStore(from: "~/Library/Application Support/Native Instruments"))
        #expect(!Config.usesLocalStore(from: ""))

        let to = "Native Instruments/Root Application Support"
        #expect(Config.linkTargetPath(from: "/Library/Application Support/Native Instruments", to: to)
                == Config.localStoreRoot + "/" + to)
        #expect(Config.linkTargetPath(from: "~/Library/Preferences/x", to: to)
                == Config.expandedDestinationPath(for: to))
        // A To picked outside the settings folder is used as-is.
        #expect(Config.linkTargetPath(from: "/Library/Audio/Plug-Ins", to: "/Volumes/Audio/Plug-Ins")
                == "/Volumes/Audio/Plug-Ins")
    }

    @Test func catalogLocationNamesDecode() throws {
        let yaml = #"[{"path": "~/Documents/Native Instruments", "name": "Documents"}, "/Library/Audio/Plug-Ins"]"#
        let files = try JSONDecoder().decode([FileConfig].self, from: Data(yaml.utf8))
        #expect(files.map(\.name) == ["Documents", nil])
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

    // MARK: - Keeping Mac defaults applied

    private func catalogEntry(_ name: String, domain: String, key: String, type: String,
                              postCommand: String? = nil) -> MacDefaultCatalogEntry {
        MacDefaultCatalogEntry(name: name, domain: domain, key: key, type: type, hostFlag: nil,
                               postCommand: postCommand, category: nil, minMacOS: nil, maxMacOS: nil)
    }

    @Test func onlyChosenDefaultsAreResolved() {
        let catalog = [catalogEntry("Dock Autohide", domain: "com.apple.dock", key: "autohide", type: "bool",
                                    postCommand: "killall Dock")]
        let configs = [
            MacDefaultConfig(name: "Dock Autohide", value: "1"),
            MacDefaultConfig(name: "Not Picked", domain: "com.example", key: "k", type: "string", value: ""),
            MacDefaultConfig(name: "Custom", domain: "com.example", key: "k", type: "int", value: "3"),
            MacDefaultConfig(name: "No Domain", value: "x"),
            MacDefaultConfig(name: "Old macOS Only", domain: "com.example", key: "old", type: "bool", value: "1"),
        ]
        let targets = MacDefaultTarget.resolve(configs, catalog: catalog, unsupported: ["Old macOS Only"])
        #expect(targets.map(\.name) == ["Dock Autohide", "Custom"])
        #expect(targets[0].writeArguments == ["write", "com.apple.dock", "autohide", "-bool", "1"])
        #expect(targets[0].postCommand == "killall Dock")
        #expect(targets[1].readArguments == ["read", "com.example", "k"])
    }

    @Test func catalogDescribesCatalogDefaults() {
        let catalog = [catalogEntry("Dark Mode", domain: "NSGlobalDomain", key: "AppleInterfaceStyle", type: "string")]
        let configs = [MacDefaultConfig(name: "Dark Mode", domain: "stale", key: "stale", type: "int", value: "Dark")]
        let target = MacDefaultTarget.resolve(configs, catalog: catalog).first
        #expect(target?.writeArguments == ["write", "NSGlobalDomain", "AppleInterfaceStyle", "-string", "Dark"])
    }

    @Test func hostFlagGoesFirst() {
        let configs = [MacDefaultConfig(name: "Clock", domain: "com.apple.menuextra.clock", key: "ShowSeconds",
                                        type: "bool", value: "1", hostFlag: "-currentHost")]
        let target = MacDefaultTarget.resolve(configs, catalog: []).first
        #expect(target?.readArguments == ["-currentHost", "read", "com.apple.menuextra.clock", "ShowSeconds"])
    }

    @Test func followUpCommandsRunOnce() {
        func target(_ name: String, _ post: String) -> MacDefaultTarget {
            MacDefaultTarget(name: name, domain: "d", key: name, type: "bool", value: "1", hostFlag: "", postCommand: post)
        }
        let targets = [target("a", "killall Finder"), target("b", ""), target("c", "killall Dock"), target("d", "killall Finder")]
        #expect(MacDefaultTarget.postCommands(for: targets) == ["killall Finder", "killall Dock"])
    }

    @Test func valuesCompareByMeaning() {
        #expect(MacDefaultValue.matches(type: "bool", desired: "true", current: "1"))
        #expect(MacDefaultValue.matches(type: "bool", desired: "0", current: "NO"))
        #expect(!MacDefaultValue.matches(type: "bool", desired: "1", current: "0"))
        #expect(!MacDefaultValue.matches(type: "bool", desired: "1", current: ""))
        #expect(MacDefaultValue.matches(type: "float", desired: "0.50", current: "0.5"))
        #expect(MacDefaultValue.matches(type: "int", desired: "36", current: " 36\n"))
        #expect(!MacDefaultValue.matches(type: "string", desired: "Dark", current: "Light"))
        #expect(MacDefaultValue.matches(type: "string", desired: "Dark", current: "Dark"))
    }

    @Test func watcherMatchesSyncedFileNames() {
        let names = ["mac-defaults.yaml"]
        #expect(FolderWatcher.isRelevant("/x/Takeover/mac-defaults.yaml", fileNames: names))
        #expect(FolderWatcher.isRelevant("/x/Takeover/.mac-defaults.yaml.icloud", fileNames: names))
        #expect(!FolderWatcher.isRelevant("/x/Takeover/takeover-settings.yaml", fileNames: names))
    }

    @Test func fingerprintIsStable() {
        let data = Data("mac_defaults: []\n".utf8)
        #expect(MacDefaultsEnforcer.fingerprint(data) == MacDefaultsEnforcer.fingerprint(Data("mac_defaults: []\n".utf8)))
        #expect(MacDefaultsEnforcer.fingerprint(data) != MacDefaultsEnforcer.fingerprint(Data()))
    }

}
