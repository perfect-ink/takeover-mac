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
    static func install(linkItem: LinkItem) throws {
        guard PermissionsHelper.checkAndRequestPermissions() else {
            throw LinkInstallError.fullDiskAccessRequired
        }

        // Already linked to this destination: nothing to do.
        if isLinked(linkItem) { return }

        let backupPath = Config.expandedDestinationPath(for: linkItem.to)
        let originalPath = PathUtility.expandTildeToRealHome(linkItem.from)

        let originalExists = FileOps.exists(originalPath)
        let originalIsSymlink = FileOps.isSymlink(originalPath)
        let backupExists = FileOps.exists(backupPath)
        let backupIsSymlink = FileOps.isSymlink(backupPath)

        // A real original *and* a real backup already sit side by side — archive
        // the stale backup with a timestamp rather than clobbering it.
        if originalExists, !originalIsSymlink, backupExists, !backupIsSymlink {
            let archived = "\(backupPath)-old-\(timestamp())"
            do {
                try FileOps.move(from: backupPath, to: archived, allowPrivileged: true)
                print("Archived existing backup to \(archived)")
            } catch {
                throw LinkInstallError.archiveOldBackupFailed(error.localizedDescription)
            }
        }

        // Move the real original into the backup location.
        if originalExists, !originalIsSymlink {
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

        if !linkItem.defaults.isEmpty {
            let result = Shell.runTrusted(linkItem.defaults)
            if !result.ok {
                throw LinkInstallError.defaultsCommandFailed(result.text)
            }
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

    // MARK: - Helpers

    static func status(_ linkItem: LinkItem) -> LinkStatus {
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
