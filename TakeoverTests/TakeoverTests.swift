//
//  TakeoverTests.swift
//  TakeoverTests
//
//  Created by Alex Vaos on 2/12/25.
//

import Foundation
import SwiftData
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

    /// A catalog rename another Mac already made: the folder at the new place
    /// is used, and this Mac's old copy is set aside, not deleted. A plain To
    /// change still refuses to touch an existing folder.
    @MainActor @Test func catalogMoveAdoptsAnExistingDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let old = root + "/Takeover/SSH/ssh", new = root + "/Takeover/SSH/User SSH"
        try fm.createDirectory(atPath: old, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: new, withIntermediateDirectories: true)
        try "old".write(toFile: old + "/config", atomically: true, encoding: .utf8)
        try "synced".write(toFile: new + "/config", atomically: true, encoding: .utf8)
        let source = root + "/.ssh"
        try fm.createSymbolicLink(atPath: source, withDestinationPath: old)
        let item = LinkItem(name: "SSH", from: source, to: old)

        #expect(throws: LinkInstallError.self) {
            try LinkItemInstaller.changeDestination(of: item, to: new)
        }
        #expect(item.to == old)

        try LinkItemInstaller.changeDestination(of: item, to: new, adoptExisting: true)

        #expect(item.to == new)
        #expect(LinkItemInstaller.isLinked(item))
        #expect(try String(contentsOfFile: source + "/config", encoding: .utf8) == "synced")
        let aside = try fm.contentsOfDirectory(atPath: root + "/Takeover/SSH").filter { $0.hasPrefix("ssh-old-") }
        #expect(aside.count == 1)
        #expect(try String(contentsOfFile: root + "/Takeover/SSH/" + aside[0] + "/config", encoding: .utf8) == "old")
    }

    /// Moving a location down into a folder inside its old one: two-step move
    /// when nothing's there yet, and just a relink when another Mac already did it.
    @MainActor @Test func catalogMoveIntoASubfolderOfTheOldDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let old = root + "/Takeover/SSH", new = root + "/Takeover/SSH/User SSH"
        try fm.createDirectory(atPath: old, withIntermediateDirectories: true)
        try "mine".write(toFile: old + "/config", atomically: true, encoding: .utf8)
        let source = root + "/.ssh"
        try fm.createSymbolicLink(atPath: source, withDestinationPath: old)
        let item = LinkItem(name: "SSH", from: source, to: old)

        try LinkItemInstaller.changeDestination(of: item, to: new)
        #expect(LinkItemInstaller.isLinked(item))
        #expect(try String(contentsOfFile: source + "/config", encoding: .utf8) == "mine")

        // Another Mac's link still points at the old, now-parent folder.
        try fm.removeItem(atPath: source)
        try fm.createSymbolicLink(atPath: source, withDestinationPath: old)
        item.to = old
        try LinkItemInstaller.changeDestination(of: item, to: new, adoptExisting: true)
        #expect(LinkItemInstaller.isLinked(item))
        #expect(try String(contentsOfFile: source + "/config", encoding: .utf8) == "mine")
    }

    /// Change points a location at another folder without moving anything:
    /// the old destination keeps its files and the link follows To.
    @MainActor @Test func changingDestinationRelinksWithoutMovingFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let old = root + "/Takeover/SSH/User SSH", new = root + "/Elsewhere/SSH"
        try fm.createDirectory(atPath: old, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: new, withIntermediateDirectories: true)
        try "old".write(toFile: old + "/config", atomically: true, encoding: .utf8)
        try "new".write(toFile: new + "/config", atomically: true, encoding: .utf8)
        let source = root + "/.ssh"
        try fm.createSymbolicLink(atPath: source, withDestinationPath: old)
        let item = LinkItem(name: "SSH", from: source, to: old)

        try LinkItemInstaller.pointDestination(of: item, to: new)

        #expect(item.to == new)
        #expect(LinkItemInstaller.isLinked(item))
        #expect(try String(contentsOfFile: source + "/config", encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: old + "/config", encoding: .utf8) == "old")
    }

    /// Change on a location that isn't linked only sets To; a new folder
    /// that isn't there yet is created only when a link needs it.
    @MainActor @Test func changingDestinationOfAnUnlinkedLocationOnlySetsTo() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let source = root + "/.ssh", new = root + "/Elsewhere/SSH"
        try fm.createDirectory(atPath: source, withIntermediateDirectories: true)
        let item = LinkItem(name: "SSH", from: source, to: root + "/Takeover/SSH/User SSH")

        try LinkItemInstaller.pointDestination(of: item, to: new)

        #expect(item.to == new)
        #expect(!fm.fileExists(atPath: new))
        #expect(!LinkItemInstaller.isLinked(item))
    }

    /// Move puts the destination folder, under its current name, inside the
    /// picked folder and relinks it.
    @MainActor @Test func movingDestinationIntoAnotherFolderRelinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let old = root + "/Takeover/SSH/User SSH", folder = root + "/Archive"
        try fm.createDirectory(atPath: old, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "mine".write(toFile: old + "/config", atomically: true, encoding: .utf8)
        let source = root + "/.ssh"
        try fm.createSymbolicLink(atPath: source, withDestinationPath: old)
        let item = LinkItem(name: "SSH", from: source, to: old)

        let new = (folder as NSString).appendingPathComponent((old as NSString).lastPathComponent)
        try LinkItemInstaller.changeDestination(of: item, to: new)

        #expect(item.to == new)
        #expect(!fm.fileExists(atPath: old))
        #expect(LinkItemInstaller.isLinked(item))
        #expect(try String(contentsOfFile: source + "/config", encoding: .utf8) == "mine")
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
        #expect(Config.linkTargetPath(from: "/Library/Application Support/Native Instruments", to: "/Volumes/Audio/NI")
                == "/Volumes/Audio/NI")
    }

    @Test func audioFoldersAreMirroredNotLinked() {
        #expect(Config.mirrors(from: "/Library/Audio/Plug-Ins"))
        #expect(Config.mirrors(from: "/Library/Audio/Presets/Xfer Records"))
        #expect(Config.mirrors(from: "~/Library/Audio/Presets"))
        #expect(!Config.mirrors(from: "/Library/AudioThing"))
        #expect(!Config.mirrors(from: "/Library/Application Support/Native Instruments"))
        #expect(!Config.mirrors(from: ""))
        // Mirrored folders aren't linked, so they don't go through the local store.
        #expect(!Config.usesLocalStore(from: "/Library/Audio/Plug-Ins"))
    }

    /// Both copies get each other's newer files, and nothing is deleted.
    @Test func mirroringCopiesBothWaysAndDeletesNothing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let local = root + "/Plug-Ins", synced = root + "/Takeover/Audio Plug-Ins/Library Audio Plug-Ins"
        try fm.createDirectory(atPath: local + "/VST3", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: synced + "/Components", withIntermediateDirectories: true)
        try "serum".write(toFile: local + "/VST3/Serum.vst3", atomically: true, encoding: .utf8)
        try "diva".write(toFile: synced + "/Components/Diva.component", atomically: true, encoding: .utf8)

        #expect(FolderMirror.pull(local: local, synced: synced) == nil)
        #expect(FolderMirror.push(local: local, synced: synced) == nil)

        #expect(try String(contentsOfFile: local + "/Components/Diva.component", encoding: .utf8) == "diva")
        #expect(try String(contentsOfFile: synced + "/VST3/Serum.vst3", encoding: .utf8) == "serum")
    }

    @Test func mirrorStateIsKeptPerSource() throws {
        let saved = FolderMirror.statePath
        FolderMirror.statePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeover-test-\(UUID().uuidString)/mirrored-locations.json").path
        defer {
            try? FileManager.default.removeItem(atPath: (FolderMirror.statePath as NSString).deletingLastPathComponent)
            FolderMirror.statePath = saved
        }
        let from = "/Library/Audio/Plug-Ins"
        #expect(!FolderMirror.isMirrored(from: from, to: "Audio Plug-Ins/Library Audio Plug-Ins"))
        try FolderMirror.setMirrored(true, from: from, to: "Audio Plug-Ins/Library Audio Plug-Ins")
        #expect(FolderMirror.isMirrored(from: from + "/", to: "Audio Plug-Ins/Library Audio Plug-Ins"))
        // A new To replaces the old one.
        try FolderMirror.setMirrored(true, from: from, to: "Plug-Ins")
        #expect(!FolderMirror.isMirrored(from: from, to: "Audio Plug-Ins/Library Audio Plug-Ins"))
        #expect(FolderMirror.entries().count == 1)
        try FolderMirror.setMirrored(false, from: from, to: "Plug-Ins")
        #expect(FolderMirror.entries().isEmpty)
    }

    /// A folder inside a linked location (Kontakt 7 inside a linked Native
    /// Instruments folder) can't be installed until the parent is unlinked.
    @MainActor @Test func installRefusesAFolderInsideALinkedLocation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/Synced/Kontakt 7", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/Native Instruments", withDestinationPath: root + "/Synced")

        let container = try ModelContainer(for: LinkItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let parent = LinkItem(name: "Native Instruments", from: root + "/Native Instruments", to: root + "/Synced")
        let child = LinkItem(name: "Native Instruments", from: root + "/Native Instruments/Kontakt 7", to: root + "/Kontakt 7")
        context.insert(parent)
        context.insert(child)

        #expect(LinkItemInstaller.linkedParent(of: child)?.from == parent.from)
        #expect(LinkItemInstaller.linkedParent(of: parent) == nil)
    }

    @Test func catalogLocationNamesDecode() throws {
        let yaml = #"[{"path": "~/Documents/Native Instruments", "name": "Documents"}, "/Library/Audio/Plug-Ins"]"#
        let files = try JSONDecoder().decode([FileConfig].self, from: Data(yaml.utf8))
        #expect(files.map(\.name) == ["Documents", nil])
    }

    @Test func wildcardLocationsExpandPerMatch() {
        let app = AppConfig(name: "Ableton Live", files: [
            FileConfig(path: "~/Music/Ableton", name: "Ableton Live Music"),
            FileConfig(path: "/Applications/Ableton Live *.app/Contents/App-Resources/Themes", name: "Ableton Live * Themes"),
            FileConfig(path: "/Applications/Ableton Live *.app/Contents/App-Resources/Skins", name: "Ableton Live * Skins"),
        ], defaults: nil)
        let installed = [
            "/Applications/Ableton Live 12 Suite.app/Contents/App-Resources/Themes",
            "/Applications/Ableton Live 10 Standard.app/Contents/App-Resources/Themes",
        ]
        let expanded = Repository.expandingWildcards([app]) { pattern in
            pattern.hasSuffix("Themes") ? installed : []
        }[0].files
        #expect(expanded.map(\.path) == ["~/Music/Ableton"] + installed.sorted())
        #expect(expanded.map(\.name) == [
            "Ableton Live Music", "Ableton Live 10 Standard Themes", "Ableton Live 12 Suite Themes",
        ])
    }

    /// Guitar Rig's folder moved from the Native Instruments recipe to its own:
    /// the existing location joins the new app instead of being added twice.
    @Test func locationsFollowAPathToItsNewCatalogApp() {
        let gr = "/Library/Application Support/Native Instruments/Guitar Rig 7"
        let apps = [
            AppConfig(name: "Native Instruments", files: [FileConfig(path: "~/Documents/Native Instruments", name: "User Documents")], defaults: nil),
            AppConfig(name: "Native Instruments Guitar Rig", files: [FileConfig(path: gr, name: "Library Guitar Rig 7")], defaults: nil),
        ]
        let moved = LinkItem(name: "Native Instruments (3)", from: gr, to: "Native Instruments/Library Guitar Rig 7")
        let stays = LinkItem(name: "Native Instruments", from: "~/Documents/Native Instruments", to: "Native Instruments/User Documents")
        let own = LinkItem(name: "My Rig", from: gr, to: "Mine")

        #expect(RecipeInstaller.followCatalogApps([moved, stays, own], apps: apps))
        #expect(moved.name == "Native Instruments Guitar Rig")
        #expect(stays.name == "Native Instruments")
        #expect(own.name == "My Rig")
        #expect(!RecipeInstaller.followCatalogApps([moved, stays, own], apps: apps))
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

    @Test func droppedInstallerNamesNeverOverwrite() {
        #expect(InstallerImporter.plan(fileName: "Arc.dmg", size: 10, existing: [:]) == .copy(as: "Arc.dmg"))
        #expect(InstallerImporter.plan(fileName: "Arc.dmg", size: 10, existing: ["arc.dmg": 10]) == .alreadyThere)
        #expect(InstallerImporter.plan(fileName: "Arc.dmg", size: 10, existing: ["Arc.dmg": 12]) == .copy(as: "Arc 2.dmg"))
        #expect(InstallerImporter.plan(fileName: "Arc.dmg", size: 10, existing: ["Arc.dmg": 12, "Arc 2.dmg": 11]) == .copy(as: "Arc 3.dmg"))
        #expect(InstallerImporter.isInstaller(URL(fileURLWithPath: "/tmp/Tool.MPKG")))
        #expect(!InstallerImporter.isInstaller(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(InstallerImporter.defaultFolder(settingsRoot: "~/Takeover") == "~/Takeover/Apps")
    }

    @Test func droppedInstallersAreCopiedIntoTheFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("takeover-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let dmg = downloads.appendingPathComponent("Arc.dmg")
        let txt = downloads.appendingPathComponent("notes.txt")
        try Data("dmg".utf8).write(to: dmg)
        try Data("txt".utf8).write(to: txt)
        let folder = root.appendingPathComponent("Takeover/Apps").path

        let first = InstallerImporter.importFiles([dmg, txt], into: folder)
        #expect(first.copied == ["Arc.dmg"])
        #expect(first.unsupported == ["notes.txt"])
        #expect(fm.fileExists(atPath: dmg.path))
        #expect(AppInstallerEngine.scan(at: folder).map(\.name) == ["Arc"])

        let again = InstallerImporter.importFiles([dmg], into: folder)
        #expect(again.copied.isEmpty)
        #expect(again.alreadyThere == ["Arc.dmg"])
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

    /// A dangling link is broken (shown red), not missing (greyed out).
    @Test func brokenLinkCountsAsPresentNotMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("takeover-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("gone").path)
        #expect(LinkItemInstaller.sourceExists(link.path))
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
