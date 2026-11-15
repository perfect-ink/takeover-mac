//
//  SystemOps.swift
//  Takeover
//
//  Native replacements for the old "route everything through
//  `osascript -e "do shell script …"`" approach:
//
//    • Proc            – run a known tool with an argv array (no shell, no quoting)
//    • Shell           – run a TRUSTED command line via /bin/sh (catalog/settings text only)
//    • PrivilegedShell – run one argv command with administrator privileges (in-process, so one prompt covers several steps)
//    • FileOps         – FileManager wrappers that transparently escalate on EPERM
//

import Foundation

enum SystemOpError: LocalizedError {
    case launchFailed(tool: String, underlying: Error)
    case commandFailed(tool: String, args: [String], status: Int32, message: String)
    case privilegedFailed(argv: [String], status: Int32, message: String)
    case fileOperationFailed(operation: String, path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(tool, underlying):
            return "Couldn't launch \(tool): \(underlying.localizedDescription)"
        case let .commandFailed(tool, _, status, message):
            let detail = message.isEmpty ? "" : " — \(message)"
            return "\((tool as NSString).lastPathComponent) exited with code \(status)\(detail)"
        case let .privilegedFailed(argv, status, message):
            let name = (argv.first as NSString?)?.lastPathComponent ?? "command"
            if message.contains("-128") || message.lowercased().contains("user canceled") {
                return "Authentication was cancelled."
            }
            let detail = message.isEmpty ? "" : " — \(message)"
            return "\(name) (privileged) exited with code \(status)\(detail)"
        case let .fileOperationFailed(operation, path, underlying):
            return "\(operation) failed for \(path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Proc

/// Runs an executable directly with an argument vector — no shell is involved,
/// so paths and values never need escaping and can't be re-interpreted.
enum Proc {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var ok: Bool { exitCode == 0 }
        var combined: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: "failed to launch \(launchPath): \(error.localizedDescription)", exitCode: -1)
        }

        // Drain both pipes concurrently so a large stream on one can't deadlock the child.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "takeover.proc.io", attributes: .concurrent)
        group.enter()
        queue.async { outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data(); group.leave() }
        group.enter()
        queue.async { errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(); group.leave() }
        process.waitUntilExit()
        group.wait()

        return Result(
            stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus
        )
    }

    /// Like `run`, but throws `SystemOpError.commandFailed` on a non-zero exit and returns stdout.
    @discardableResult
    static func require(_ launchPath: String, _ args: [String]) throws -> String {
        let result = run(launchPath, args)
        guard result.ok else {
            throw SystemOpError.commandFailed(
                tool: launchPath, args: args, status: result.exitCode,
                message: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout
    }
}

// MARK: - Shell

/// Runs a command line that is authored by us or by the user's own settings/catalog
/// (e.g. `killall Finder`, a `defaults …` snippet, `git pull`). Never pass a
/// caller-controlled filesystem path through here — use `Proc` or `FileOps`.
enum Shell {
    struct Output {
        let text: String
        let exitCode: Int32
        var ok: Bool { exitCode == 0 }
    }

    @discardableResult
    static func runTrusted(_ command: String) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            return Output(text: "failed to launch: \(error.localizedDescription)", exitCode: -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus
        )
    }
}

// MARK: - PrivilegedShell

/// Runs a single command, as its own argv, with administrator privileges.
///
/// The script runs in this process through NSAppleScript, not a new
/// `osascript` each time: macOS then remembers the authorization for about five
/// minutes, so an install that needs several privileged steps (move, then
/// link) asks for the password once instead of once per step.
///
/// Each argument is single-quoted for the shell and the whole command escaped
/// as an AppleScript string, so a path with quotes, spaces or `$(…)` can't
/// break out of either.
enum PrivilegedShell {
    @discardableResult
    static func run(_ argv: [String]) throws -> String {
        precondition(!argv.isEmpty, "PrivilegedShell.run requires at least the tool path")
        let command = argv.map(shellQuoted).joined(separator: " ")
        let source = "do shell script \(appleScriptString(command)) with administrator privileges"

        let execute = { () -> Result<String, Error> in
            guard let script = NSAppleScript(source: source) else {
                return .failure(SystemOpError.privilegedFailed(argv: argv, status: -1, message: "Couldn't build the AppleScript"))
            }
            var errorInfo: NSDictionary?
            let output = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? -1
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
                return .failure(SystemOpError.privilegedFailed(argv: argv, status: number, message: "\(message) (\(number))"))
            }
            return .success(output.stringValue ?? "")
        }

        // NSAppleScript isn't thread-safe; run it on the main thread.
        if Thread.isMainThread { return try execute().get() }
        return try DispatchQueue.main.sync(execute: execute).get()
    }

    static func shellQuoted(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - FileOps

/// Thin, native FileManager operations. Each mutating call first tries the
/// unprivileged path and, only if it's blocked by permissions and
/// `allowPrivileged` is set, retries the same operation via `PrivilegedShell`
/// (which prompts for authentication).
enum FileOps {
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func makeDirectory(_ path: String, allowPrivileged: Bool = false) throws {
        if exists(path) { return }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            try escalateOrThrow(error, operation: "Create directory", path: path, allowPrivileged: allowPrivileged) {
                try PrivilegedShell.run(["/bin/mkdir", "-p", path])
            }
        }
    }

    static func move(from source: String, to destination: String, allowPrivileged: Bool = false) throws {
        do {
            if exists(destination) || isSymlink(destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        } catch {
            try escalateOrThrow(error, operation: "Move", path: source, allowPrivileged: allowPrivileged) {
                try PrivilegedShell.run(["/bin/mv", "-f", source, destination])
            }
        }
    }

    static func copy(from source: String, to destination: String, allowPrivileged: Bool = false) throws {
        do {
            if exists(destination) || isSymlink(destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        } catch {
            try escalateOrThrow(error, operation: "Copy", path: source, allowPrivileged: allowPrivileged) {
                try PrivilegedShell.run(["/usr/bin/ditto", source, destination])
            }
        }
    }

    /// Copies `source` into `destination` with rsync, keeping whichever copy of
    /// each file is newer and deleting nothing. Folders merge by contents.
    static func merge(from source: String, into destination: String, allowPrivileged: Bool = false) throws {
        let rsync = "/usr/bin/rsync"
        let src = isDirectory(source) ? source + "/" : source
        let dst = isDirectory(source) ? destination + "/" : destination
        let args = ["-a", "--update", src, dst]
        let result = Proc.run(rsync, args)
        guard !result.ok else { return }
        guard allowPrivileged else {
            throw NSError(domain: "FileOps", code: 1, userInfo: [NSLocalizedDescriptionKey: "rsync failed: \(result.combined)"])
        }
        try PrivilegedShell.run([rsync] + args)
    }

    static func remove(_ path: String, allowPrivileged: Bool = false) throws {
        guard exists(path) || isSymlink(path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            try escalateOrThrow(error, operation: "Remove", path: path, allowPrivileged: allowPrivileged) {
                try PrivilegedShell.run(["/bin/rm", "-rf", path])
            }
        }
    }

    static func symlink(at linkPath: String, to target: String, allowPrivileged: Bool = false) throws {
        do {
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        } catch {
            try escalateOrThrow(error, operation: "Create symlink", path: linkPath, allowPrivileged: allowPrivileged) {
                try PrivilegedShell.run(["/bin/ln", "-s", target, linkPath])
            }
        }
    }

    // MARK: Escalation plumbing

    private static func escalateOrThrow(
        _ error: Error, operation: String, path: String,
        allowPrivileged: Bool, _ privilegedRetry: () throws -> Void
    ) throws {
        guard allowPrivileged, isPermissionError(error) else {
            throw SystemOpError.fileOperationFailed(operation: operation, path: path, underlying: error)
        }
        try privilegedRetry()
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let posixCodes = Set([EPERM, EACCES, EROFS].map { Int($0) })

        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, posixCodes.contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, posixCodes.contains(underlying.code) {
            return true
        }
        return false
    }
}
