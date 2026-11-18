//
//  LinkItemInstaller.swift
//  Takeover
//
//  Created by Alex Vaos on 2/12/25.
//

import Foundation
import SwiftData

enum LinkInstallError: LocalizedError {
    case fullDiskAccessRequired
    case archiveOldBackupFailed(String)
    case moveToBackupFailed(String)
    case symlinkFailed(String)
    case removeFailed(String)
    case defaultsCommandFailed(String)
    case restoreFailed(String)
    case verificationFailed(String)
    case insideLinkedLocation(String)

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
        case let .insideLinkedLocation(name):
            return "This folder is inside \(name), which is linked. Uninstall \(name) with Move destination first, so this folder is real again, then install it."
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
    case broken             // a link exists but what it points to is gone
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

        // Already linked to this destination: nothing to do.
        if isLinked(linkItem) { return }

        // Linking a folder that sits inside another linked location would move
        // files around inside that location's synced copy.
        if let parent = linkedParent(of: linkItem) {
            throw LinkInstallError.insideLinkedLocation(parent.name)
        }

        let backupPath = target(of: linkItem)
        let originalPath = PathUtility.expandTildeToRealHome(linkItem.from)

        // A /Library location on a Mac without its local folder yet: start
        // from the synced copy, as a home-folder location would.
        do {
            try LocalStoreBackup.seedIfNeeded(from: linkItem.from, to: linkItem.to)
        } catch {
            throw LinkInstallError.moveToBackupFailed(error.localizedDescription)
        }

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
        backUpInBackground(linkItem)

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
        let backupPath = target(of: linkItem)

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

    /// The one way to change a location's To. Moves the synced files from the
    /// old destination to `newTo`, points the source's link at the new place
    /// when it pointed at the old one, then sets `to` (and clears the label).
    /// If relinking fails the files are moved back, so a link never ends up
    /// pointing at a folder that's gone. When something is already at `newTo`
    /// and there are files to move, it throws without changing anything,
    /// unless `adoptExisting`: then the folder already at `newTo` wins (another
    /// Mac sharing the settings folder made the same move first) and the old
    /// destination is set aside with a timestamp, never deleted.
    @MainActor
    static func changeDestination(of linkItem: LinkItem, to newTo: String, adoptExisting: Bool = false) throws {
        try moveDestination(of: linkItem, to: newTo, adoptExisting: adoptExisting)
        // A local-store location's backup in the settings folder moves too.
        moveSyncedCopy(of: linkItem, to: newTo)
        linkItem.to = newTo
        linkItem.label = ""
    }

    /// Points a location at another destination without moving anything (the
    /// Change button; Move goes through `changeDestination`). The old
    /// destination keeps its files. When the source is linked to the old
    /// destination, or its link is broken, it's relinked to the new one; a
    /// local-store location's local folder is seeded from the new synced copy
    /// first, and a missing new folder is created so the link isn't left
    /// dangling. If relinking fails the old link is put back and To is unchanged.
    @MainActor
    static func pointDestination(of linkItem: LinkItem, to newTo: String) throws {
        guard !newTo.isEmpty else { return }
        let newPath = Config.linkTargetPath(from: linkItem.from, to: newTo)
        let source = linkItem.from.isEmpty ? "" : PathUtility.expandTildeToRealHome(linkItem.from)
        let sourceIsLink = !source.isEmpty && FileOps.isSymlink(source)
        let oldTarget = sourceIsLink ? linkTarget(source) : nil
        let pointsAtOld = !linkItem.to.isEmpty && oldTarget.map {
            let oldPath = Config.linkTargetPath(from: linkItem.from, to: linkItem.to)
            return samePath($0, oldPath) || isInside($0, oldPath)
        } == true
        let dangling = sourceIsLink && !FileOps.exists(source)

        if (pointsAtOld || dangling), oldTarget.map({ !samePath($0, newPath) }) ?? true {
            do {
                try LocalStoreBackup.seedIfNeeded(from: linkItem.from, to: newTo)
                if !FileOps.exists(newPath) { try FileOps.makeDirectory(newPath, allowPrivileged: true) }
                try FileOps.remove(source, allowPrivileged: true)
                try FileOps.symlink(at: source, to: newPath, allowPrivileged: true)
                try verifyLink(originalPath: source, backupPath: newPath)
            } catch {
                if let oldTarget, linkTarget(source).map({ !samePath($0, oldTarget) }) ?? true {
                    try? FileOps.remove(source, allowPrivileged: true)
                    try? FileOps.symlink(at: source, to: oldTarget, allowPrivileged: true)
                }
                throw LinkInstallError.symlinkFailed(error.localizedDescription)
            }
        }
        linkItem.to = newTo
        linkItem.label = ""
    }

    @MainActor
    static func moveDestination(of linkItem: LinkItem, to newTo: String, adoptExisting: Bool = false) throws {
        guard !linkItem.to.isEmpty, !newTo.isEmpty else { return }
        let oldPath = Config.linkTargetPath(from: linkItem.from, to: linkItem.to)
        let newPath = Config.linkTargetPath(from: linkItem.from, to: newTo)
        guard !samePath(oldPath, newPath) else { return }
        let source = linkItem.from.isEmpty ? "" : PathUtility.expandTildeToRealHome(linkItem.from)
        let sourceIsLink = !source.isEmpty && FileOps.isSymlink(source)
        // Linked to the old destination, however the link spells it, or (when
        // the old one is already gone) to the new one's spot.
        let pointsAtOld = sourceIsLink && linkTarget(source).map { samePath($0, oldPath) || isInside($0, oldPath) } == true
        let danglingBefore = sourceIsLink && !FileOps.exists(source)

        // A local-store location whose new synced copy is already in the
        // settings folder: that copy is what's at the new place.
        let newSynced = Config.usesLocalStore(from: linkItem.from) ? Config.expandedDestinationPath(for: newTo) : newPath
        let existingAtNew = FileOps.exists(newPath) || FileOps.exists(newSynced)

        var moved = false
        var setAside: String?
        if isInside(newPath, oldPath), existingAtNew, adoptExisting {
            // The new place is inside the old one and already there (another
            // Mac moved the files down a level): nothing to move, just relink.
            // Whatever else is in the old folder stays where it is.
        } else if FileOps.exists(oldPath) || FileOps.isSymlink(oldPath) {
            if existingAtNew {
                // FileOps.move replaces what's there; never clobber another folder.
                guard adoptExisting else {
                    throw LinkInstallError.moveToBackupFailed("\(FileOps.exists(newPath) ? newPath : newSynced) already exists.")
                }
                // Use what's already at the new place; keep this Mac's old
                // copy beside it rather than deleting it.
                let archived = "\(oldPath)-old-\(timestamp())"
                do {
                    try FileOps.move(from: oldPath, to: archived, allowPrivileged: true)
                    setAside = archived
                    print("Using the existing \(newPath); set \(oldPath) aside at \(archived)")
                    try LocalStoreBackup.seedIfNeeded(from: linkItem.from, to: newTo)
                } catch {
                    if let archived = setAside { try? FileOps.move(from: archived, to: oldPath, allowPrivileged: true) }
                    throw LinkInstallError.moveToBackupFailed(error.localizedDescription)
                }
            } else {
                do {
                    // Moving a folder into a folder inside itself takes two
                    // steps: out of the way first, then into place.
                    var from = oldPath
                    if isInside(newPath, oldPath) {
                        from = "\(oldPath)-moving-\(timestamp())"
                        try FileOps.move(from: oldPath, to: from, allowPrivileged: true)
                    }
                    try FileOps.makeDirectory((newPath as NSString).deletingLastPathComponent, allowPrivileged: true)
                    try FileOps.move(from: from, to: newPath, allowPrivileged: true)
                    moved = true
                } catch {
                    throw LinkInstallError.moveToBackupFailed(error.localizedDescription)
                }
            }
        }

        // Relink when the link pointed at the old destination, or when moving
        // just broke it (it pointed somewhere inside what moved).
        let brokenByMove = sourceIsLink && !danglingBefore && !FileOps.exists(source)
        guard pointsAtOld || brokenByMove else { return }
        // A local-store location starts from its synced copy, if there is one.
        try? LocalStoreBackup.seedIfNeeded(from: linkItem.from, to: newTo)
        if !FileOps.exists(newPath) {
            // Nothing to point at (the old destination was already missing):
            // make the folder so the link isn't left dangling.
            try FileOps.makeDirectory(newPath, allowPrivileged: true)
        }
        do {
            try FileOps.remove(source, allowPrivileged: true)
            try FileOps.symlink(at: source, to: newPath, allowPrivileged: true)
            try verifyLink(originalPath: source, backupPath: newPath)
        } catch {
            if moved || setAside != nil {
                // Put the files back and the old link with them.
                if let archived = setAside {
                    try? FileOps.move(from: archived, to: oldPath, allowPrivileged: true)
                } else if isInside(newPath, oldPath) {
                    // FileOps.move would replace the old folder, which now
                    // holds the files: lift them out, drop the emptied parents
                    // (rmdir never removes a folder with anything in it), then
                    // put them back.
                    let lifted = "\(oldPath)-moving-\(timestamp())"
                    if (try? FileOps.move(from: newPath, to: lifted, allowPrivileged: true)) != nil {
                        var dir = (newPath as NSString).deletingLastPathComponent
                        while isInside(dir, oldPath) || samePath(dir, oldPath), rmdir(dir) == 0 {
                            dir = (dir as NSString).deletingLastPathComponent
                        }
                        if !FileOps.exists(oldPath) { try? FileOps.move(from: lifted, to: oldPath, allowPrivileged: true) }
                    }
                } else {
                    try? FileOps.move(from: newPath, to: oldPath, allowPrivileged: true)
                }
                if !FileOps.isSymlink(source) { try? FileOps.symlink(at: source, to: oldPath, allowPrivileged: true) }
            }
            throw LinkInstallError.symlinkFailed(error.localizedDescription)
        }
    }

    /// Another saved location that is linked and whose source contains this
    /// one's, e.g. /Library/Application Support/Native Instruments for its
    /// Kontakt 7 folder.
    static func linkedParent(of linkItem: LinkItem) -> LinkItem? {
        guard !linkItem.from.isEmpty, let context = linkItem.modelContext,
              let items = try? context.fetch(FetchDescriptor<LinkItem>()) else { return nil }
        let source = plainPath(linkItem.from)
        return items.first { other in
            other.persistentModelID != linkItem.persistentModelID && !other.from.isEmpty
                && source.hasPrefix(plainPath(other.from) + "/")
                && FileOps.isSymlink(PathUtility.expandTildeToRealHome(other.from))
        }
    }

    /// Expanded and standardized without resolving links, compared the way
    /// the Mac's file system does.
    private static func plainPath(_ path: String) -> String {
        (PathUtility.expandTildeToRealHome(path) as NSString).standardizingPath
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    /// What this item's link points to (see `Config.linkTargetPath`).
    static func target(of linkItem: LinkItem) -> String {
        Config.linkTargetPath(from: linkItem.from, to: linkItem.to)
    }

    /// Backs a local-store location up into the settings folder off the main
    /// thread (it can be gigabytes).
    static func backUpInBackground(_ linkItem: LinkItem) {
        let from = linkItem.from, to = linkItem.to
        guard Config.usesLocalStore(from: from) else { return }
        DispatchQueue.global(qos: .utility).async {
            if let error = LocalStoreBackup.backUp(from: from, to: to) { print(error) }
        }
    }

    /// Moves a local-store location's synced copy along with a To change,
    /// unless something is already at the new place.
    private static func moveSyncedCopy(of linkItem: LinkItem, to newTo: String) {
        guard Config.usesLocalStore(from: linkItem.from) else { return }
        let oldSynced = Config.expandedDestinationPath(for: linkItem.to)
        let newSynced = Config.expandedDestinationPath(for: newTo)
        guard !samePath(oldSynced, newSynced), FileOps.exists(oldSynced), !FileOps.exists(newSynced) else { return }
        try? FileOps.makeDirectory((newSynced as NSString).deletingLastPathComponent)
        try? FileOps.move(from: oldSynced, to: newSynced)
    }

    /// Where the link at `path` points, made absolute.
    static func linkTarget(_ path: String) -> String? {
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        return raw.hasPrefix("/") ? raw : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(raw)
    }

    /// Paths name the same place: symlinked parents resolved, and compared the
    /// way the Mac's file system does (case- and Unicode-form-insensitive).
    static func samePath(_ a: String, _ b: String) -> Bool {
        comparable(a) == comparable(b)
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        comparable(path).hasPrefix(comparable(folder) + "/")
    }

    private static func comparable(_ path: String) -> String {
        normalized(path).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// True when installing would find both a real source and a real synced
    /// copy, so the user should pick which to keep (or merge).
    static func hasConflict(_ linkItem: LinkItem) -> Bool {
        guard !linkItem.from.isEmpty, !linkItem.to.isEmpty, !isLinked(linkItem) else { return false }
        let original = PathUtility.expandTildeToRealHome(linkItem.from)
        let backup = target(of: linkItem)
        let synced = Config.expandedDestinationPath(for: linkItem.to)
        // A local-store location gets its local folder from the synced copy,
        // so either one counts.
        let backupExists = (FileOps.exists(backup) && !FileOps.isSymlink(backup))
            || (FileOps.exists(synced) && !FileOps.isSymlink(synced))
        return FileOps.exists(original) && !FileOps.isSymlink(original) && backupExists
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
        if isLinked(linkItem) { return .installed }
        guard !linkItem.from.isEmpty else { return .notInstalled }
        let fromPath = PathUtility.expandTildeToRealHome(linkItem.from)
        guard FileOps.isSymlink(fromPath) else { return .notInstalled }
        // A link whose target is gone, e.g. after another Mac sharing the
        // settings folder moved it. Install relinks it to this item's destination.
        return FileOps.exists(fromPath) ? .differentLocation : .broken
    }

    /// True when "from" is a symlink that resolves to this item's destination,
    /// however either path is spelled (~, symlinked parents, trailing slashes).
    static func isLinked(_ linkItem: LinkItem) -> Bool {
        guard !linkItem.from.isEmpty, !linkItem.to.isEmpty else { return false }
        let fromPath = PathUtility.expandTildeToRealHome(linkItem.from)
        guard FileOps.isSymlink(fromPath), let target = linkTarget(fromPath) else { return false }
        return samePath(target, Self.target(of: linkItem))
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
        let absolute = linkTarget(originalPath) ?? target
        guard samePath(absolute, backupPath) else {
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
