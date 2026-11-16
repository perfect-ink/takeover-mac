import Foundation

/// Locations outside the home folder link into `Config.localStoreRoot`
/// instead of the settings folder (see `Config.linkTargetPath`). This keeps
/// their synced copy in the settings folder up to date, and fills the local
/// folder from it on a Mac that doesn't have it yet. Uses only Foundation and
/// system tools, so the CLI shares it.
enum LocalStoreBackup {
    /// Copies a local-store location into its place in the settings folder.
    /// Newer files win and nothing is deleted from the backup, so two Macs
    /// backing up into the same folder never remove each other's files.
    /// Returns an error message, or nil when it worked or there was nothing to do.
    @discardableResult
    static func backUp(from: String, to: String) -> String? {
        guard !from.isEmpty, !to.isEmpty else { return nil }
        let local = Config.linkTargetPath(from: from, to: to)
        let synced = Config.expandedDestinationPath(for: to)
        guard local != synced, isLinked(from: from, to: local) else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: local, isDirectory: &isDir) else { return nil }
        do {
            try fm.createDirectory(atPath: (synced as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        } catch {
            return "Couldn't create \(synced): \(error.localizedDescription)"
        }
        let args = isDir.boolValue ? ["-a", "--update", local + "/", synced + "/"] : ["-a", "--update", local, synced]
        let (status, output) = run("/usr/bin/rsync", args)
        return status == 0 ? nil : "Backing up \(local) failed: \(output)"
    }

    /// Before linking on a Mac that doesn't have the local folder yet, copies
    /// the synced copy there so the link points at the user's files.
    static func seedIfNeeded(from: String, to: String) throws {
        let local = Config.linkTargetPath(from: from, to: to)
        let synced = Config.expandedDestinationPath(for: to)
        let fm = FileManager.default
        guard local != synced, !fm.fileExists(atPath: local), fm.fileExists(atPath: synced) else { return }
        try fm.createDirectory(atPath: (local as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        let (status, output) = run("/usr/bin/ditto", [synced, local])
        if status != 0 {
            throw NSError(domain: "LocalStoreBackup", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Copying \(synced) to \(local) failed: \(output)"])
        }
    }

    private static func isLinked(from: String, to target: String) -> Bool {
        let source = PathUtility.expandTildeToRealHome(from)
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: source) else { return false }
        return (raw as NSString).standardizingPath == (target as NSString).standardizingPath
    }

    private static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
