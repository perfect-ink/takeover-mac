//
//  SettingsYaml.swift
//  Takeover
//
//  Created by Alex Vaos on 11/4/25.
//

import Foundation
import Yams

struct SettingsYaml: Codable {
    var links: [LinkConfig]
    var macDefaults: [MacDefaultConfig]?
    var appInstallers: [AppInstallerConfig]?
    /// The synced "restore list" (see AppEntryModel).
    var apps: [AppEntryConfig]?

    enum CodingKeys: String, CodingKey {
        case links
        case macDefaults = "mac_defaults"
        case appInstallers = "app_installers"
        case apps
    }

    init(links: [LinkConfig], macDefaults: [MacDefaultConfig]? = nil,
         appInstallers: [AppInstallerConfig]? = nil, apps: [AppEntryConfig]? = nil) {
        self.links = links
        self.macDefaults = macDefaults
        self.appInstallers = appInstallers
        self.apps = apps
    }

    // `links` tolerates a YAML `links:` with nothing after it (parses as
    // null, not []) — createEmptySettings used to write exactly that, which
    // made every fresh install throw here and silently abort the whole
    // settings/catalog sync pipeline (see loadSettings's catch). Treat
    // missing-or-null the same as an empty list instead of failing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decodeIfPresent([LinkConfig].self, forKey: .links) ?? []
        macDefaults = try container.decodeIfPresent([MacDefaultConfig].self, forKey: .macDefaults)
        appInstallers = try container.decodeIfPresent([AppInstallerConfig].self, forKey: .appInstallers)
        apps = try container.decodeIfPresent([AppEntryConfig].self, forKey: .apps)
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    @Published var settings: SettingsYaml?
    @Published var location: StorageLocation = .current

    static let fileName = "takeover-settings.yaml"
    static let macDefaultsFileName = "mac-defaults.yaml"
    private var fileName: String { Self.fileName }
    private var macDefaultsFileName: String { Self.macDefaultsFileName }

    /// Fingerprint of both files as this process last read or wrote them, to
    /// tell changes made elsewhere (another Mac, the background agent) from
    /// our own saves.
    private var knownDiskFingerprint: String?

    private init() {}

    var storageDirectoryURL: URL {
        URL(fileURLWithPath: location.expandedRootPath)
    }

    var settingsFileURL: URL {
        storageDirectoryURL.appendingPathComponent(fileName)
    }

    var macDefaultsFileURL: URL {
        storageDirectoryURL.appendingPathComponent(macDefaultsFileName)
    }

    /// Switches to a new storage location, copying the current settings files
    /// across when the new folder doesn't have its own yet.
    @MainActor
    func changeLocation(to newLocation: StorageLocation) throws {
        let oldDirectory = storageDirectoryURL
        try newLocation.save()
        location = newLocation

        let newDirectory = storageDirectoryURL
        guard oldDirectory.standardizedFileURL != newDirectory.standardizedFileURL else { return }
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        for name in [fileName, macDefaultsFileName] {
            let from = oldDirectory.appendingPathComponent(name)
            let to = newDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: from.path) && !FileManager.default.fileExists(atPath: to.path) {
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
    }

    func loadSettings() async throws -> SettingsYaml {
        let fileURL = settingsFileURL

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )

        // Check if file exists, if not create a default one
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try createEmptySettings(at: fileURL)
            print("Created default settings at: \(fileURL.path)")
        }

        let data = try Data(contentsOf: fileURL)
        let yamlString = String(data: data, encoding: .utf8) ?? ""

        let decoder = YAMLDecoder()
        var settings = try decoder.decode(SettingsYaml.self, from: yamlString)

        // macOS defaults live in their own file; older installs kept them under
        // `mac_defaults` in the settings file, so move them over once.
        if let macDefaults = try loadMacDefaults() {
            settings.macDefaults = macDefaults
        } else if let legacy = settings.macDefaults {
            try writeMacDefaults(legacy)
            try writeSettingsFile(settings)
        }

        rememberDiskState()
        await MainActor.run {
            self.settings = settings
        }

        return settings
    }

    /// Reads the settings files in any Takeover folder (for Restore) without
    /// creating, migrating or changing anything there. A missing or empty
    /// file reads as empty.
    static func read(folder: String) throws -> SettingsYaml {
        let directory = URL(fileURLWithPath: PathUtility.expandTildeToRealHome(folder))
        func text(_ name: String) -> String? {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        var settings = SettingsYaml(links: [])
        if let yaml = text("takeover-settings.yaml") {
            settings = try YAMLDecoder().decode(SettingsYaml.self, from: yaml)
        }
        if let yaml = text("mac-defaults.yaml") {
            settings.macDefaults = try YAMLDecoder().decode(MacDefaultsYaml.self, from: yaml).macDefaults
        }
        return settings
    }

    func saveSettings(_ settings: SettingsYaml) async throws {
        try writeSettingsFile(settings)
        try writeMacDefaults(settings.macDefaults ?? [], madeOnThisMac: true)
        rememberDiskState()

        await MainActor.run {
            self.settings = settings
        }

        syncProfileToAccount(settings)
    }

    /// Writes settings that came from the Takeover account (a newer profile
    /// pushed by another Mac). Same as `saveSettings` but doesn't push them
    /// back up, so two Macs never bounce the same change between them.
    func applyFromAccount(_ settings: SettingsYaml) async throws {
        try writeSettingsFile(settings)
        try writeMacDefaults(settings.macDefaults ?? [])
        rememberDiskState()

        await MainActor.run {
            self.settings = settings
        }
    }

    private func writeSettingsFile(_ settings: SettingsYaml) throws {
        var fileContents = settings
        fileContents.macDefaults = nil
        let yamlString = try YAMLEncoder().encode(fileContents)
        try yamlString.write(to: settingsFileURL, atomically: true, encoding: .utf8)
    }

    private func loadMacDefaults() throws -> [MacDefaultConfig]? {
        let url = macDefaultsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decodeMacDefaults(try Data(contentsOf: url))
    }

    /// Contents of a `mac-defaults.yaml`; an empty file means no defaults.
    static func decodeMacDefaults(_ data: Data) throws -> [MacDefaultConfig]? {
        let yaml = String(data: data, encoding: .utf8) ?? ""
        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return try YAMLDecoder().decode(MacDefaultsYaml.self, from: yaml).macDefaults
    }

    /// `madeOnThisMac` marks an edit from this Mac's own UI, which the
    /// background agent doesn't apply by itself (the tab has Apply buttons);
    /// changes from another Mac or the account are applied right away. The
    /// mark is saved before the file so the agent never sees the file first.
    private func writeMacDefaults(_ macDefaults: [MacDefaultConfig], madeOnThisMac: Bool = false) throws {
        let yaml = try YAMLEncoder().encode(MacDefaultsYaml(macDefaults: macDefaults))
        let fingerprint = MacDefaultsEnforcer.fingerprint(Data(yaml.utf8))
        if madeOnThisMac {
            UserDefaults.standard.set(fingerprint, forKey: MacDefaultsEnforcer.localWriteKey)
        } else if UserDefaults.standard.string(forKey: MacDefaultsEnforcer.localWriteKey) == fingerprint {
            UserDefaults.standard.removeObject(forKey: MacDefaultsEnforcer.localWriteKey)
        }
        try yaml.write(to: macDefaultsFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Changes made elsewhere

    private func diskFingerprint() -> String {
        let data = [settingsFileURL, macDefaultsFileURL]
            .map { (try? Data(contentsOf: $0)) ?? Data() }
            .reduce(Data(), +)
        return MacDefaultsEnforcer.fingerprint(data)
    }

    private func rememberDiskState() {
        knownDiskFingerprint = diskFingerprint()
    }

    /// Whether either settings file differs from what this process last
    /// read or wrote.
    var hasChangedOnDisk: Bool {
        diskFingerprint() != knownDiskFingerprint
    }

    /// When signed in, push this Mac's setup to the account (debounced). No-op
    /// otherwise. Mac-default rows are enriched with domain/key/type from the
    /// catalog so the profile is self-contained on the restoring Mac.
    private func syncProfileToAccount(_ settings: SettingsYaml) {
        Task { @MainActor in
            let profile = Profile(settings: settings, catalog: MacDefaultCatalog.shared.entries)
            ProfileSyncManager.shared.schedulePush(profile)
        }
    }

    private func createEmptySettings(at url: URL) throws {
        // `links:` with nothing after it parses as YAML null, not an empty
        // sequence — decodes fine now (see SettingsYaml.init(from:)), but
        // write valid empty-array YAML regardless of how lenient the reader is.
        let defaultSettings = """
        links: []
        """

        try defaultSettings.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum SettingsError: Error {
    case iCloudNotAvailable
    case fileNotFound
    case invalidYAML
}
