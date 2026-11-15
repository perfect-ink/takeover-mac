import Foundation
import AppKit

/// Finds the real icon for an app card whose app isn't installed yet, and
/// caches it in ~/Library/Caches/Takeover/AppIcons so each installer is only
/// opened once:
///
/// - `.zip`: reads the app's Info.plist and icon straight out of the archive.
/// - `.dmg`: mounts it read-only, takes the icon of the app inside, unmounts.
/// - Homebrew: the apple-touch-icon from the cask's homepage.
/// - `.pkg`: not opened (payloads can be large); the card keeps a placeholder.
///
/// Installed apps and plain `.app` files don't come through here; the card
/// asks NSWorkspace for those directly.
enum AppIconLoader {

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Takeover/AppIcons", isDirectory: true)
    }

    /// Changes when the installer file changes, so a new version gets a fresh icon.
    static func cacheKey(for card: AppCard) -> String? {
        switch card.source {
        case .homebrew(let cask):
            return "brew-\(safe(cask))"
        case .installer(let app):
            guard app.fileType == .zip || app.fileType == .dmg else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: app.fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            return "file-\(safe(app.fileURL.lastPathComponent))-\(size)-\(mtime)"
        }
    }

    /// The cached icon file for a card, if one was saved before.
    static func cachedIconURL(for card: AppCard) -> URL? {
        guard let key = cacheKey(for: card) else { return nil }
        let url = cacheDir.appendingPathComponent("\(key).tiff")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Finds, caches and returns the icon file for a card, or nil when none
    /// can be found. Slow (unzips, mounts, downloads); call off the main thread.
    static func loadIconURL(for card: AppCard) async -> URL? {
        if let cached = cachedIconURL(for: card) { return cached }
        guard let key = cacheKey(for: card) else { return nil }

        let image: NSImage?
        switch card.source {
        case .installer(let app):
            image = app.fileType == .zip ? iconFromZip(app.fileURL) : iconFromDmg(app.fileURL)
        case .homebrew(let cask):
            image = await iconFromHomebrew(cask: cask)
        }
        guard let image, let tiff = image.tiffRepresentation else { return nil }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent("\(key).tiff")
        do {
            try tiff.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - ZIP

    private static func iconFromZip(_ zip: URL) -> NSImage? {
        let listing = Proc.run("/usr/bin/zipinfo", ["-1", zip.path])
        guard listing.ok else { return nil }
        let entries = listing.stdout.split(whereSeparator: \.isNewline).map(String.init)

        // The outermost app's Info.plist, e.g. "Foo.app/Contents/Info.plist".
        guard let plistPath = entries
            .filter({ $0.hasSuffix(".app/Contents/Info.plist") && !$0.hasPrefix("__MACOSX/") })
            .min(by: { $0.count < $1.count }) else { return nil }
        let contents = String(plistPath.dropLast("Info.plist".count))

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeover-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        guard extract([plistPath], from: zip, to: temp),
              let plist = NSDictionary(contentsOf: temp.appendingPathComponent(plistPath)),
              var iconName = plist["CFBundleIconFile"] as? String, !iconName.isEmpty else {
            return iconByUnzippingApp(zip)
        }
        if (iconName as NSString).pathExtension.isEmpty { iconName += ".icns" }
        let iconPath = contents + "Resources/" + iconName

        guard entries.contains(iconPath), extract([iconPath], from: zip, to: temp),
              let image = NSImage(contentsOf: temp.appendingPathComponent(iconPath)) else {
            return iconByUnzippingApp(zip)
        }
        return image
    }

    /// Apps whose icon only lives in an asset catalog: unzip the whole thing
    /// and let NSWorkspace read it.
    private static func iconByUnzippingApp(_ zip: URL) -> NSImage? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeover-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard Proc.run("/usr/bin/ditto", ["-x", "-k", zip.path, temp.path]).ok,
              let app = AppInstallerEngine.findApp(in: temp) else { return nil }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    private static func extract(_ paths: [String], from zip: URL, to dir: URL) -> Bool {
        // -qq quiet, -o overwrite; entry names are matched as patterns, so
        // escape the wildcard characters unzip understands.
        let escaped = paths.map { $0.replacingOccurrences(of: "[", with: "[[]")
            .replacingOccurrences(of: "*", with: "[*]").replacingOccurrences(of: "?", with: "[?]") }
        return Proc.run("/usr/bin/unzip", ["-qq", "-o", zip.path] + escaped + ["-d", dir.path]).ok
    }

    // MARK: - DMG

    private static func iconFromDmg(_ dmg: URL) -> NSImage? {
        let attach = Proc.run("/usr/bin/hdiutil",
                              ["attach", dmg.path, "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-plist"])
        guard attach.ok, let mount = AppInstallerEngine.parseMountPoint(from: attach.stdout) else { return nil }
        defer { Proc.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }
        guard let app = AppInstallerEngine.findApp(in: URL(fileURLWithPath: mount)) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        // Draw it into a bitmap now, while the volume is still mounted.
        _ = image.tiffRepresentation
        return image
    }

    // MARK: - Homebrew

    private static func iconFromHomebrew(cask: String) async -> NSImage? {
        guard let brew = AppRestoreEngine.brewURL() else { return nil }
        let info = Proc.run(brew.path, ["info", "--cask", "--json=v2", cask])
        guard info.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(info.stdout.utf8)) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]],
              let homepageString = casks.first?["homepage"] as? String,
              let homepage = URL(string: homepageString) else { return nil }

        var candidates: [URL] = []
        if let page = try? await URLSession.shared.data(from: homepage),
           let html = String(data: page.0, encoding: .utf8) {
            candidates += touchIconLinks(in: html, base: homepage)
        }
        if let root = URL(string: "/apple-touch-icon.png", relativeTo: homepage) {
            candidates.append(root.absoluteURL)
        }

        for url in candidates {
            guard let fetched = try? await URLSession.shared.data(from: url),
                  (fetched.1 as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: fetched.0), image.isValid else { continue }
            return image
        }
        return nil
    }

    /// `href`s of `<link rel="apple-touch-icon">` tags, resolved against the page.
    static func touchIconLinks(in html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]),
              let href = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])
        else { return [] }
        let ns = html as NSString
        return tag.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let link = ns.substring(with: match.range)
            guard link.range(of: "apple-touch-icon", options: .caseInsensitive) != nil,
                  let h = href.firstMatch(in: link, range: NSRange(location: 0, length: (link as NSString).length))
            else { return nil }
            let value = (link as NSString).substring(with: h.range(at: 1))
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
    }

    private static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }
}
