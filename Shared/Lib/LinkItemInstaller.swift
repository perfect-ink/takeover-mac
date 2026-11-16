//
//  LinkItemInstaller.swift
//  Takeover
//
//  Created by Alex Vaos on 2/12/25.
//

import Foundation

enum LinkInstallError: LocalizedError {
    case fullDiskAccessRequired
    case archiveOldBackupFailed(String)
    case moveToBackupFailed(String)
    case symlinkFailed(String)
    case removeFailed(String)
    case defaultsCommandFailed(String)
    case restoreFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            return "Full Disk Access is required to manage this link."
        case let .archiveOldBackupFailed(detail):
            return "Couldn't archive the existing backup: \(detail)"
        case let .moveToBackupFailed(detail):
            return "Couldn't move the original into the backup location: \(detail)"
        case let .symlinkFailed(detail):
            return "Couldn't create the symlink: \(detail)"
        case let .removeFailed(detail):
            return "Couldn't remove the symlink: \(detail)"
        case let .verificationFailed(detail):
            return "The link was created but doesn't look right: \(detail)"
        case let .restoreFailed(detail):
            return "The link was removed, but restoring the files failed: \(detail)"
        case let .defaultsCommandFailed(detail):
            return "The linked defaults command failed: \(detail)"
        }
    }
}

/// What to do with the synced files when a link is removed.
enum UninstallMode {
    /// Put a copy back where the link was; the destination keeps its files.
    case copyFromDestination
    /// Move the destination's files back where the link was.
    case moveDestination
    /// Remove only the link, leaving nothing at the original location.
    case removeLink
}

/// What to keep when a location's source and its synced copy both exist.
enum InstallConflictChoice {
    /// Keep this Mac's files; the synced copy is set aside with a timestamp.
    case useSource
    /// Keep the synced copy; this Mac's files are set aside with a timestamp.
    case useDestination
    /// rsync this Mac's files into the synced copy (newer file wins, nothing
    /// deleted), then set this Mac's original aside.
    case merge
}

/// How a sync setting's link looks on disk.
enum LinkStatus {
    case installed          // linked to this item's destination
    case differentLocation  // a link exists but points somewhere else
    case notInstalled
}

struct LinkItemInstaller {

    /// Moves the original aside into the iCloud backup location and replaces it
    /// with a symlink. Throws `LinkInstallError` on any failure.
    @MainActor
    static func install(linkItem: LinkItem, conflict: InstallConflictChoice = .useSource) throws {
        guard PermissionsHelper.checkAndRequestPermissions() else {
            throw LinkInstallError.fullDiskAccessRequired
        }

        // System folders are copied, never linked (see isSystemLocation).
        if isSystemLocation(linkItem.from) {
            try installByCopy(linkItem)
            try runDefaults(linkItem)
            return
        }

        // Already linked to this destination: nothing to do.
        if isLinked(linkItem) { return }

        let backupPath = Config.expandedDestinationPath(for: linkItem.to)
        let originalPath = PathUtility.expandTildeToRealHome(linkItem.from)

        let originalExists = FileOps.exists(originalPath)
        let originalIsSymlink = FileOps.isSymlink(originalPath)
        let backupExists = FileOps.exists(backupPath)
        let backupIsSymlink = FileOps.isSymlink(backupPath)

        // A real original *and* a real backup already sit side by side: keep the
        // side `conflict` picks (or merge them) and set the other aside with a
        // timestamp, never clobbering either.
        var keepOriginal = originalExists && !originalIsSymlink
        if originalExists, !originalIsSymlink, backupExists, !backupIsSymlink {
            do {
                switch conflict {
                case .useSource:
                    let archived = "\(backupPath)-old-\(timestamp())"
                    try FileOps.move(from: backupPath, to: archived, allowPrivileged: true)
                    print("Archived existing backup to \(archived)")
                case .useDestination, .merge:
                    if conflict == .merge {
                        try FileOps.merge(from: originalPath, into: backupPath, allowPrivileged: true)
                    }
                    let archived = "\(originalPath)-old-\(timestamp())"
                    try FileOps.move(from: originalPath, to: archived, allowPrivileged: true)
                    print("Set this Mac's copy aside at \(archived)")
                    keepOriginal = false
                }
            } catch {
                throw LinkInstallError.archiveOldBackupFailed(error.localizedDescription)
            }
        }

        // Move the real original into the backup location.
        if keepOriginal {
            let parent = (backupPath as NSString).deletingLastPathComponent
            do {
                try FileOps.makeDirectory(parent, allowPrivileged: true)
                try FileOps.move(from: originalPath, to: backupPath, allowPrivileged: true)
            } catch {
                throw LinkInstallError.moveToBackupFailed(error.localizedDescription)
            }
        }

        // The destination must exist so the link doesn't dangle: create it as a
        // folder when there was nothing to move in and nothing there already.
        if !FileOps.exists(backupPath) {
            do {
                try FileOps.makeDirectory(backupPath, allowPrivileged: true)
            } catch {
                throw LinkInstallError.moveToBackupFailed(error.localizedDescription)
            }
        }

        // Clear a pre-existing (stale) symlink so createSymbolicLink can succeed.
        if originalIsSymlink {
            do {
                try FileOps.remove(originalPath, allowPrivileged: true)
            } catch {
                throw LinkInstallError.symlinkFailed(error.localizedDescription)
            }
        }

        do {
            try FileOps.symlink(at: originalPath, to: backupPath, allowPrivileged: true)
        } catch {
            throw LinkInstallError.symlinkFailed(error.localizedDescription)
        }
        print("Linked \(originalPath) -> \(backupPath)")

        try verifyLink(originalPath: originalPath, backupPath: backupPath)
        try runDefaults(linkItem)
    }

    private static func runDefaults(_ linkItem: LinkItem) throws {
        guard !linkItem.defaults.isEmpty else { return }
        let result = Shell.runTrusted(linkItem.defaults)
        if !result.ok {
            throw LinkInstallError.defaultsCommandFailed(result.text)
        }
    }

    /// A location outside the user's home folder (/Library/...). Those are
    /// written by installers running as root, which macOS doesn't let into the
    /// settings folder (iCloud Drive, Dropbox, ~/Documents...): a link there made
    /// Native Instruments' installers fail with "Operation not permitted". So
    /// they're synced by copying, and the real folder stays in place.
    static func isSystemLocation(_ from: String) -> Bool {
        guard !from.isEmpty else { return false }
        let path = PathUtility.expandTildeToRealHome(from)
        let home = PathUtility.getRealHomeDirectory()
        return path != home && !path.hasPrefix(home + "/")
    }

    /// Install for a system location: back this Mac's folder up into the
    /// settings folder (replacing the old copy), or, on a Mac that doesn't have
    /// it yet, copy the synced copy into place. A link left by an older build
    /// is replaced by a real folder again.
    @MainActor
    private static func installByCopy(_ linkItem: LinkItem) throws {
        let backupPath = Config.expandedDestinationPath(for: linkItem.to)
        let originalPath = PathUtility.expandTildeToRealHome(linkItem.from)

        // Undo an earlier link: put the synced copy back as a real folder.
        if FileOps.isSymlink(originalPath) {
            do {
                try FileOps.remove(originalPath, allowPrivileged: true)
                if FileOps.exists(backupPath) {
                    try FileOps.copy(from: backupPath, to: originalPath, allowPrivileged: true)
                }
            } catch {
                throw LinkInstallError.restoreFailed(error.localizedDescription)
            }
            return
        }

        do {
            if FileOps.exists(originalPath) {
                try FileOps.makeDirectory((backupPath as NSString).deletingLastPathComponent, allowPrivileged: true)
                try FileOps.copy(from: originalPath, to: backupPath, allowPrivileged: true)
                print("Copied \(originalPath) -> \(backupPath)")
            } else if FileOps.exists(backupPath) {
                try FileOps.makeDirectory((originalPath as NSString).deletingLastPathComponent, allowPrivileged: true)
                try FileOps.copy(from: backupPath, to: originalPath, allowPrivileged: true)
                print("Restored \(originalPath) from \(backupPath)")
            }
        } catch {
            throw LinkInstallError.moveToBackupFailed(error.localizedDescription)
        }
    }

    /// Removes the symlink at the original location, then handles the destination
    /// per `mode`. A no-op if nothing is linked. Never deletes a real file/directory.
    @MainActor
    static func uninstall(linkItem: LinkItem, mode: UninstallMode = .removeLink) throws {
        guard PermissionsHelper.checkAndRequestPermissions() else {
            throw LinkInstallError.fullDiskAccessRequired
        }

        let originalPath = PathUtility.expandTildeToRealHome(linkItem.from)
        guard FileOps.isSymlink(originalPath) else {
            print("Nothing to uninstall — \(originalPath) is not a symlink")
            return
        }
        let backupPath = Config.expandedDestinationPath(for: linkItem.to)

        do {
            try FileOps.remove(originalPath, allowPrivileged: true)
            print("Removed symlink at \(originalPath)")
        } catch {
            throw LinkInstallError.removeFailed(error.localizedDescription)
        }

        guard mode != .removeLink, FileOps.exists(backupPath) else { return }
        do {
            switch mode {
            case .copyFromDestination:
                try FileOps.copy(from: backupPath, to: originalPath, allowPrivileged: true)
            case .moveDestination:
                try FileOps.move(from: backupPath, to: originalPath, allowPrivileged: true)
            case .removeLink:
                break
            }
        } catch {
            throw LinkInstallError.restoreFailed(error.localizedDescription)
        }
    }

    /// Moves a location's destination to `newTo` (a name in the settings folder
    /// or a path) and, when it's linked, points the link at the new place.
    /// Nothing on disk changes when there's nothing at the old destination.
    @MainActor
    static func moveDestination(of linkItem: LinkItem, to newTo: String) throws {
        let oldPath = Config.expandedDestinationPath(for: linkItem.to)
        let newPath = Config.expandedDestinationPath(for: newTo)
        guard !linkItem.to.isEmpty, oldPath != newPath, FileOps.exists(oldPath) else { return }
        // FileOps.move replaces what's there; never clobber another folder.
        guard !FileOps.exists(newPath) else {
            throw LinkInstallError.moveToBackupFailed("\(newPath) already exists.")
        }
        let linked = isLinked(linkItem)
        do {
            try FileOps.makeDirectory((newPath as NSString).deletingLastPathComponent, allowPrivileged: true)
            try FileOps.move(from: oldPath, to: newPath, allowPrivileged: true)
        } catch {
            throw LinkInstallError.moveToBackupFailed(error.localizedDescription)
        }
        guard linked else { return }
        let originalPath = PathUtility.expandTildeToRealHome(linkItem.from)
        do {
            try FileOps.remove(originalPath, allowPrivileged: true)
            try FileOps.symlink(at: originalPath, to: newPath, allowPrivileged: true)
        } catch {
            throw LinkInstallError.symlinkFailed(error.localizedDescription)
        }
        try verifyLink(originalPath: originalPath, backupPath: newPath)
    }

    /// True when installing would find both a real source and a real synced
    /// copy, so the user should pick which to keep (or merge).
    static func hasConflict(_ linkItem: LinkItem) -> Bool {
        guard !linkItem.from.isEmpty, !linkItem.to.isEmpty, !isLinked(linkItem),
              !isSystemLocation(linkItem.from) else { return false }
        let original = PathUtility.expandTildeToRealHome(linkItem.from)
        let backup = Config.expandedDestinationPath(for: linkItem.to)
        return FileOps.exists(original) && !FileOps.isSymlink(original)
            && FileOps.exists(backup) && !FileOps.isSymlink(backup)
    }

    // MARK: - Helpers

    /// Whether a sync location's source is on this Mac, as a real file or
    /// folder or as a link. An empty path counts as present (nothing to warn about).
    static func sourceExists(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        let expanded = PathUtility.expandTildeToRealHome(path)
        return FileOps.exists(expanded) || FileOps.isSymlink(expanded)
    }

    static func status(_ linkItem: LinkItem) -> LinkStatus {
        if isSystemLocation(linkItem.from) {
            let fromPath = PathUtility.expandTildeToRealHome(linkItem.from)
            // A link here is one an older build made; it needs reinstalling.
            if FileOps.isSymlink(fromPath) { return .differentLocation }
            let copied = FileOps.exists(fromPath) && !linkItem.to.isEmpty
                && FileOps.exists(Config.expandedDestinationPath(for: linkItem.to))
            return copied ? .installed : .notInstalled
        }
        if isLinked(linkItem) { return .installed }
        guard !linkItem.from.isEmpty else { return .notInstalled }
        let fromPath = PathUtility.expandTildeToRealHome(linkItem.from)
        return FileOps.isSymlink(fromPath) ? .differentLocation : .notInstalled
    }

    /// True when "from" is a symlink that resolves to this item's destination,
    /// however either path is spelled (~, symlinked parents, trailing slashes).
    static func isLinked(_ linkItem: LinkItem) -> Bool {
        guard !linkItem.from.isEmpty, !linkItem.to.isEmpty else { return false }
        let fromPath = PathUtility.expandTildeToRealHome(linkItem.from)
        guard FileOps.isSymlink(fromPath),
              let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: fromPath)
        else { return false }
        let target = raw.hasPrefix("/") ? raw : ((fromPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(raw)
        return normalized(target) == normalized(Config.expandedDestinationPath(for: linkItem.to))
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Confirms the install left a symlink at the original path that points at
    /// an existing destination.
    private static func verifyLink(originalPath: String, backupPath: String) throws {
        guard FileOps.isSymlink(originalPath) else {
            throw LinkInstallError.verificationFailed("nothing is linked at \(originalPath).")
        }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: originalPath) else {
            throw LinkInstallError.verificationFailed("couldn't read the link at \(originalPath).")
        }
        guard normalized(target) == normalized(backupPath) else {
            throw LinkInstallError.verificationFailed("\(originalPath) points to \(target), not \(backupPath).")
        }
        guard FileOps.exists(backupPath) else {
            throw LinkInstallError.verificationFailed("the destination \(backupPath) doesn't exist.")
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
