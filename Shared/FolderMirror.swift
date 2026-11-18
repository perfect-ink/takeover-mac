import Foundation

/// Locations that installers write into as root, such as the audio plug-in
/// and preset folders, aren't linked. They stay real folders on this Mac and
/// Takeover keeps them and their synced copy in the settings folder in step,
/// both ways. A link there broke installers twice: macOS blocks root from
/// iCloud Drive through a link, and plug-in installers failed even through
/// the local store. See `Config.mirrors(from:)` for which sources this covers.
///
/// Which locations this Mac mirrors is kept per Mac, in `statePath`. Uses
/// only Foundation and system tools, so the CLI shares it.
enum FolderMirror {
    struct Entry: Codable, Equatable {
        var from: String
        var to: String
    }

    /// Per Mac, beside the local store, so a settings folder shared by several
    /// Macs doesn't say which of them mirror what.
    static var statePath = "\(Config.localStoreRoot)/mirrored-locations.json"

    // MARK: - State

    static func entries() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: statePath),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func isMirrored(from: String, to: String) -> Bool {
        let key = Entry(from: standardized(from), to: to)
        return entries().contains(key)
    }

    /// Records (or forgets) that this Mac mirrors `from` into `to`. A source
    /// mirrors into one place, so a new To replaces the old one.
    static func setMirrored(_ mirrored: Bool, from: String, to: String) throws {
        let source = standardized(from)
        var list = entries().filter { $0.from != source }
        if mirrored { list.append(Entry(from: source, to: to)) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    // MARK: - Copying

    /// rsync options for both directions: newer file wins, nothing is ever
    /// deleted (so two Macs sharing a settings folder can't remove each
    /// other's plug-ins), and Finder's litter stays out.
    static let rsyncOptions = ["-a", "--update", "--exclude", ".DS_Store"]

    /// Copies the synced copy into this Mac's folder. Returns an error message,
    /// or nil when it worked or there was nothing to copy.
    @discardableResult
    static func pull(local: String, synced: String) -> String? {
        guard FileManager.default.fileExists(atPath: synced) else { return nil }
        return copy(synced, into: local)
    }

    /// Copies this Mac's folder into the synced copy.
    @discardableResult
    static func push(local: String, synced: String) -> String? {
        guard FileManager.default.fileExists(atPath: local) else { return nil }
        return copy(local, into: synced)
    }

    /// The rsync arguments that copy `source` into `destination`, merging
    /// folders by contents.
    static func rsyncArguments(_ source: String, into destination: String) -> [String] {
        var isDir: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: source, isDirectory: &isDir) && isDir.boolValue
        return rsyncOptions + (folder ? [source + "/", destination + "/"] : [source, destination])
    }

    /// Pulls then pushes every location this Mac mirrors. Pulling into a
    /// folder only root can write to fails quietly here (there's no one to
    /// ask for a password in the background); Install pulls with the password.
    static func syncAll() {
        for entry in entries() {
            let synced = Config.expandedDestinationPath(for: entry.to)
            if let error = pull(local: entry.from, synced: synced) { print(error) }
            if let error = push(local: entry.from, synced: synced) { print(error) }
        }
    }

    // MARK: - Helpers

    private static func copy(_ source: String, into destination: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        } catch {
            return "Couldn't create \(destination): \(error.localizedDescription)"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        task.arguments = rsyncArguments(source, into: destination)
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return error.localizedDescription }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus != 0 else { return nil }
        return "Copying \(source) to \(destination) failed: \(String(data: data, encoding: .utf8) ?? "")"
    }

    private static func standardized(_ path: String) -> String {
        (PathUtility.expandTildeToRealHome(path) as NSString).standardizingPath
    }
}
