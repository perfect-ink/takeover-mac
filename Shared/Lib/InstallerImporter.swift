import Foundation

/// Copies installer files dropped on the Applications tab into the installers
/// folder, which defaults to `Apps` inside the Takeover settings folder, so
/// they sync with the rest of the settings and show up as app cards.
enum InstallerImporter {

    /// Installer file extensions the Applications tab understands.
    static let installerExtensions: Set<String> = ["dmg", "zip", "pkg", "mpkg", "app"]

    /// The default installers folder: `<Takeover folder>/Apps`, tilde-prefixed
    /// when under home.
    static func defaultFolder(settingsRoot: String = StorageLocation.current.rootPath) -> String {
        (settingsRoot as NSString).appendingPathComponent("Apps")
    }

    static func isInstaller(_ url: URL) -> Bool {
        installerExtensions.contains(url.pathExtension.lowercased())
    }

    enum Plan: Equatable {
        /// Copy to this file name in the folder.
        case copy(as: String)
        /// The same file is already in the folder; nothing to do.
        case alreadyThere
    }

    /// What to do with a dropped file whose name is `fileName`. A file of that
    /// name already in the folder is left alone when it's the same file (same
    /// size); otherwise the new one is kept beside it, Finder style:
    /// "Arc.dmg" becomes "Arc 2.dmg". Nothing in the folder is overwritten.
    static func plan(fileName: String, size: Int64?, existing: [String: Int64?]) -> Plan {
        let taken = Set(existing.keys.map { $0.lowercased() })
        guard taken.contains(fileName.lowercased()) else { return .copy(as: fileName) }
        let match = existing.first { $0.key.lowercased() == fileName.lowercased() }
        if let size, let existingSize = match?.value, existingSize == size { return .alreadyThere }

        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return .copy(as: candidate) }
            n += 1
        }
    }

    struct Result {
        var copied: [String] = []
        var alreadyThere: [String] = []
        var unsupported: [String] = []
        var failed: [String] = []

        /// A line for the user when something didn't go in, otherwise nil.
        var problem: String? {
            var lines: [String] = []
            if !unsupported.isEmpty {
                lines.append("Not an installer (.dmg, .zip, .pkg or .app): \(unsupported.joined(separator: ", "))")
            }
            if !failed.isEmpty { lines.append(contentsOf: failed) }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    /// Copies each installer into `folder`, creating it if needed. The
    /// originals stay where they were. Synchronous; call off the main thread.
    static func importFiles(_ urls: [URL], into folder: String) -> Result {
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: PathUtility.expandTildeToRealHome(folder), isDirectory: true)
        var result = Result()

        let installers = urls.filter { url in
            if isInstaller(url) { return true }
            result.unsupported.append(url.lastPathComponent)
            return false
        }
        guard !installers.isEmpty else { return result }

        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            result.failed.append("Couldn't create \(folder): \(error.localizedDescription)")
            return result
        }

        for url in installers {
            // Dropping a file that's already in the folder does nothing.
            if url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                == folderURL.resolvingSymlinksInPath().path {
                result.alreadyThere.append(url.lastPathComponent)
                continue
            }
            let existing = existingFiles(in: folderURL)
            switch plan(fileName: url.lastPathComponent, size: size(of: url), existing: existing) {
            case .alreadyThere:
                result.alreadyThere.append(url.lastPathComponent)
            case .copy(let name):
                do {
                    try fm.copyItem(at: url, to: folderURL.appendingPathComponent(name))
                    result.copied.append(name)
                } catch {
                    result.failed.append("Couldn't copy \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    private static func existingFiles(in folder: URL) -> [String: Int64?] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var map: [String: Int64?] = [:]
        for name in names { map[name] = size(of: folder.appendingPathComponent(name)) }
        return map
    }

    /// A file's size; a bundle such as an .app adds up the files inside it.
    static func size(of url: URL) -> Int64? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
