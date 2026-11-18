import Darwin
import Foundation

struct Installer {

    // MARK: - Status

    static func isInstalled(_ link: LinkConfig) -> Bool {
        if Config.mirrors(from: link.from) { return FolderMirror.isMirrored(from: link.from, to: link.to) }
        return isSymlink(atPath: PathUtility.expandTildeToRealHome(link.from))
    }

    static func isSymlink(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Shell helpers

    /// Runs a command, captures and returns its output + exit code.
    @discardableResult
    static func shell(_ command: String) -> (output: String, exitCode: Int32) {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        do { try task.run() } catch { return (error.localizedDescription, -1) }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (output, task.terminationStatus)
    }

    /// Runs a command with the terminal inherited (stdout/stderr visible, stdin works for sudo).
    @discardableResult
    static func run(_ command: String) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }

    // MARK: - Install

    static func install(_ link: LinkConfig) -> Result<Void, InstallError> {
        let fromPath = PathUtility.expandTildeToRealHome(link.from)
        // /Library locations link into a local folder (see Config.linkTargetPath).
        let toPath = Config.linkTargetPath(from: link.from, to: link.to)

        if Config.mirrors(from: link.from) { return installMirror(link) }
        if isSymlink(atPath: fromPath) {
            return .failure(.alreadyInstalled)
        }
        do {
            try LocalStoreBackup.seedIfNeeded(from: link.from, to: link.to)
        } catch {
            return .failure(.moveFailed)
        }

        let fm = FileManager.default
        let fromExists = fm.fileExists(atPath: fromPath)
        let toExists = fm.fileExists(atPath: toPath)

        let escapedFrom = escaped(fromPath)
        let escapedTo = escaped(toPath)
        let needsSudo = requiresSudo(fromPath)

        // Ensure backup parent directory exists
        let parentDir = (toPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // If both locations exist and neither is a symlink, rename the old backup
        if fromExists && toExists && !isSymlink(atPath: toPath) {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd-HHmmss"
            let oldBackup = "\(toPath)-old-\(df.string(from: Date()))"
            run("mv '\(escapedTo)' '\(escaped(oldBackup))'")
        }

        // Move original to backup location
        if fromExists && !isSymlink(atPath: fromPath) {
            let cmd = needsSudo
                ? "sudo mv '\(escapedFrom)' '\(escapedTo)'"
                : "mv '\(escapedFrom)' '\(escapedTo)'"
            let code = run(cmd)
            if code != 0 { return .failure(.moveFailed) }
        }

        // Create symlink: from → to (backup)
        let linkCmd = needsSudo
            ? "sudo ln -s '\(escapedTo)' '\(escapedFrom)'"
            : "ln -s '\(escapedTo)' '\(escapedFrom)'"
        let code = run(linkCmd)
        if code != 0 { return .failure(.symlinkFailed) }

        LocalStoreBackup.backUp(from: link.from, to: link.to)

        // Run defaults command if present
        if let defaults = link.defaults, !defaults.isEmpty {
            shell(defaults)
        }

        return .success(())
    }

    // MARK: - Uninstall

    static func uninstall(_ link: LinkConfig) -> Result<Void, InstallError> {
        if Config.mirrors(from: link.from) {
            guard FolderMirror.isMirrored(from: link.from, to: link.to) else { return .failure(.notInstalled) }
            return (try? FolderMirror.setMirrored(false, from: link.from, to: link.to)) != nil
                ? .success(()) : .failure(.removeFailed)
        }
        let fromPath = PathUtility.expandTildeToRealHome(link.from)

        guard isSymlink(atPath: fromPath) else {
            return .failure(.notInstalled)
        }

        let needsSudo = requiresSudo(fromPath)
        let cmd = needsSudo
            ? "sudo rm '\(escaped(fromPath))'"
            : "rm '\(escaped(fromPath))'"
        let code = run(cmd)
        return code == 0 ? .success(()) : .failure(.removeFailed)
    }

    /// A mirrored folder (see FolderMirror): no link. Copies the synced
    /// copy's newer files here (with sudo when the folder is root's), then
    /// this Mac's into the synced copy.
    private static func installMirror(_ link: LinkConfig) -> Result<Void, InstallError> {
        if isInstalled(link) { return .failure(.alreadyInstalled) }
        let local = PathUtility.expandTildeToRealHome(link.from)
        let synced = Config.expandedDestinationPath(for: link.to)
        if isSymlink(atPath: local) {
            print("\(local) is a link. Uninstall it first, so it's a real folder again.")
            return .failure(.moveFailed)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: synced) {
            if FolderMirror.pull(local: local, synced: synced) != nil {
                let args = FolderMirror.rsyncArguments(synced, into: local).map { "'\(escaped($0))'" }
                if run("sudo /usr/bin/rsync " + args.joined(separator: " ")) != 0 { return .failure(.moveFailed) }
            }
        } else if !fm.fileExists(atPath: local) {
            let mkdir = requiresSudo(local) ? "sudo mkdir -p '\(escaped(local))'" : "mkdir -p '\(escaped(local))'"
            if run(mkdir) != 0 { return .failure(.moveFailed) }
        }
        if let error = FolderMirror.push(local: local, synced: synced) { print(error) }
        if (try? FolderMirror.setMirrored(true, from: link.from, to: link.to)) == nil { return .failure(.moveFailed) }
        return .success(())
    }

    // MARK: - Helpers

    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func requiresSudo(_ path: String) -> Bool {
        path.hasPrefix("/Library/") || path.hasPrefix("/System/") || path.hasPrefix("/Applications/")
    }
}

enum InstallError: LocalizedError {
    case alreadyInstalled
    case notInstalled
    case moveFailed
    case symlinkFailed
    case removeFailed

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled: return "Already installed"
        case .notInstalled:     return "Not installed (no symlink found)"
        case .moveFailed:       return "Failed to move original to backup location"
        case .symlinkFailed:    return "Failed to create symlink"
        case .removeFailed:     return "Failed to remove symlink"
        }
    }
}
