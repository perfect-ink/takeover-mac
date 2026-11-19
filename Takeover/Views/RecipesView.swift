//
//  RecipesView.swift
//  Takeover
//
//  Created by Alex Vaos on 2/12/25.
//

import SwiftUI
import SwiftData

struct RecipesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingLinks: [LinkItem]
    private var repository = Repository.shared

    var onAdd: ((LinkItem) -> Void)?

    init(onAdd: ((LinkItem) -> Void)? = nil) {
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Available Recipes")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if repository.isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading recipes...")
                    Spacer()
                }
            } else if let error = repository.error {
                VStack {
                    Spacer()
                    Text("Error loading recipes")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // App Recipes Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Applications")
                                .font(.headline)
                                .padding(.horizontal)
                                .padding(.top)

                            ForEach(sortedRecipes) { app in
                                AppRecipeRow(
                                    app: app,
                                    isAlreadyAdded: isRecipeAlreadyAdded(app),
                                    onAdd: {
                                        addRecipeToLinks(app)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.bottom)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var sortedRecipes: [AppConfig] {
        let apps = repository.response?.apps ?? []
        return apps.sorted { recipe1, recipe2 in
            let exists1 = isRecipeAlreadyAdded(recipe1)
            let exists2 = isRecipeAlreadyAdded(recipe2)

            // If one exists and the other doesn't, put the existing one last
            if exists1 != exists2 {
                return !exists1
            }

            // Otherwise sort alphabetically
            return recipe1.name < recipe2.name
        }
    }

    private func isRecipeAlreadyAdded(_ app: AppConfig) -> Bool {
        let existingNames = Set(existingLinks.map { $0.name })
        return existingNames.contains(app.name)
    }

    private func addRecipeToLinks(_ app: AppConfig) {
        if let item = RecipeInstaller.add(app, existing: existingLinks, context: modelContext) {
            onAdd?(item)
        }
        dismiss()
    }
}

/// Helpers for turning catalog recipes into LinkItems and grouping them per app.
enum RecipeInstaller {
    /// "App (2)" -> "App": every sync location of an app shares its base name.
    static func baseName(_ name: String) -> String {
        var base = name
        if let r = base.range(of: #" \(\d+\)$"#, options: .regularExpression) { base = String(base[..<r.lowerBound]) }
        if base.hasSuffix(" (Users)") { base = String(base.dropLast(" (Users)".count)) }
        return base
    }

    /// A location whose app no longer lists its path, while another catalog app
    /// does (Guitar Rig's folder moved from Native Instruments to Native
    /// Instruments Guitar Rig), joins that app instead of being added twice.
    /// Renaming it is enough: its destination then follows the catalog like any
    /// renamed location (moved silently when nothing is on disk, asked about
    /// otherwise). Locations of the user's own (not named for a catalog app)
    /// are left alone. Returns whether anything changed.
    static func followCatalogApps(_ items: [LinkItem], apps: [AppConfig]) -> Bool {
        let appNames = Set(apps.map(\.name))
        var owner: [String: String] = [:]
        for app in apps {
            for file in app.files { owner[PathUtility.expandTildeToRealHome(file.path)] = owner[PathUtility.expandTildeToRealHome(file.path)] ?? app.name }
        }
        var changed = false
        for item in items where !item.from.isEmpty {
            let current = baseName(item.name)
            let from = PathUtility.expandTildeToRealHome(item.from)
            guard appNames.contains(current), let newApp = owner[from], newApp != current,
                  !(apps.first { $0.name == current }?.files.contains { PathUtility.expandTildeToRealHome($0.path) == from } ?? false)
            else { continue }
            item.name = uniqueName(base: newApp, taken: Set(items.filter { $0 !== item }.map(\.name)))
            changed = true
        }
        return changed
    }

    /// First free "App", "App (2)", "App (3)"...
    static func uniqueName(base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// A name made safe to use as one folder name ("/" and ":" can't be in one).
    static func folderName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The app's own folder inside the settings folder: its name, as shown.
    static func appFolder(_ appName: String) -> String {
        folderName(baseName(appName))
    }

    /// A location's default name: the catalog's name for it, or the path's last
    /// component without a leading dot ("~/.ssh" -> "ssh").
    static func locationName(for path: String, named name: String? = nil) -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return folderName(name) }
        var last = (path as NSString).lastPathComponent
        while last.hasPrefix(".") { last.removeFirst() }
        return folderName(last)
    }

    /// Destination of a location inside the settings folder: "App/Location".
    static func destination(appName: String, location: String) -> String {
        "\(appFolder(appName))/\(folderName(location))"
    }

    /// The name a location is shown under. For a destination in the settings
    /// folder that's its folder's name, so the two always match; for a To the
    /// user chose elsewhere, the rename label, else the source's name.
    static func displayName(of item: LinkItem) -> String {
        if !item.to.isEmpty, !isAbsolute(item.to) { return (item.to as NSString).lastPathComponent }
        if !item.label.isEmpty { return item.label }
        let fromName = locationName(for: item.from)
        return fromName.isEmpty ? baseName(item.name) : fromName
    }

    static func isAbsolute(_ to: String) -> Bool { to.hasPrefix("/") || to.hasPrefix("~") }

    /// The part of `path` that tells it apart from `other`: drop the path
    /// components both end with and take the last one left, so
    /// "~/Library/Audio/Plug-Ins" vs "/Library/Audio/Plug-Ins" gives "User" and
    /// the other way round gives "System".
    static func distinguishingPart(of path: String, from other: String) -> String {
        func parts(_ p: String) -> [String] {
            (PathUtility.abbreviateRealHome(p) as NSString).pathComponents
                .filter { $0 != "/" }
                .map { $0 == "~" ? "User" : $0 }
        }
        var mine = parts(path), theirs = parts(other)
        while let a = mine.last, let b = theirs.last, a.caseInsensitiveCompare(b) == .orderedSame {
            mine.removeLast(); theirs.removeLast()
        }
        var part = mine.last ?? "System"
        while part.hasPrefix(".") { part.removeFirst() }
        return folderName(part.isEmpty ? "System" : part)
    }

    /// "App/Location" for a new location of `appName`, made unique among the
    /// other locations: when one already uses that folder, the part of the path
    /// that differs is added ("Plug-Ins (User)"), then a number.
    static func uniqueDestination(appName: String, location: String, from path: String, others: [LinkItem]) -> String {
        let base = destination(appName: appName, location: location)
        let taken = Set(others.map { $0.to.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        let clash = others.first { $0.to.caseInsensitiveCompare(base) == .orderedSame }
        let part = clash.map { distinguishingPart(of: path, from: $0.from) } ?? ""
        let named = part.isEmpty ? location : "\(location) (\(part))"
        let candidate = destination(appName: appName, location: named)
        if !taken.contains(candidate.lowercased()) { return candidate }
        var n = 2
        while taken.contains(destination(appName: appName, location: "\(named) \(n)").lowercased()) { n += 1 }
        return destination(appName: appName, location: "\(named) \(n)")
    }

    /// Default "App/Location" for a source path, unique among `others`.
    static func destination(appName: String, from path: String, named name: String? = nil, others: [LinkItem]) -> String {
        uniqueDestination(appName: appName, location: locationName(for: path, named: name), from: path, others: others)
    }

    /// Whether a To is still in the old flat layout ("NativeInstruments-Documents")
    /// rather than "App/Location".
    static func needsAppFolder(_ item: LinkItem) -> Bool {
        guard !item.to.isEmpty, !isAbsolute(item.to) else { return false }
        let parent = (item.to as NSString).deletingLastPathComponent
        return parent.caseInsensitiveCompare(appFolder(item.name)) != .orderedSame
    }

    @discardableResult
    static func addLocation(app: AppConfig, file: FileConfig, existing: [LinkItem], context: ModelContext) -> LinkItem {
        let name = uniqueName(base: app.name, taken: Set(existing.map { $0.name }))
        let item = LinkItem(
            name: name,
            from: file.path,
            to: destination(appName: app.name, from: file.path, named: file.name, others: existing),
            defaults: app.defaults?.joined(separator: " && ") ?? ""
        )
        context.insert(item)
        try? context.save()
        return item
    }

    @discardableResult
    static func add(_ app: AppConfig, existing: [LinkItem], context: ModelContext) -> LinkItem? {
        var all = existing
        var last: LinkItem?
        for file in app.files {
            last = addLocation(app: app, file: file, existing: all, context: context)
            if let last { all.append(last) }
        }
        return last
    }

    static func isInstalled(_ app: AppConfig) -> Bool {
        isInstalled(name: app.name, paths: app.files.map { $0.path })
    }

    /// Best effort: an app bundle named like the app, or any of its files already on disk.
    static func isInstalled(name: String, paths: [String]) -> Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "\(home)/Applications"]
        if dirs.contains(where: { fm.fileExists(atPath: "\($0)/\(name).app") }) { return true }
        return paths.contains { fm.fileExists(atPath: PathUtility.expandTildeToRealHome($0)) }
    }
}

struct AppRecipeRow: View {
    let app: AppConfig
    let isAlreadyAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "app.fill")
                    .foregroundColor(isAlreadyAdded ? .gray : .blue)
                Text(app.name)
                    .font(.headline)
                    .foregroundColor(isAlreadyAdded ? .secondary : .primary)
                Spacer()
                Button("Add") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAlreadyAdded)
            }

            if !app.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(app.files.indices, id: \.self) { index in
                        HStack {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(app.files[index].path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if !LinkItemInstaller.sourceExists(app.files[index].path) {
                                Label("Not found on this Mac", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .help("This path doesn't exist here, so there's nothing to sync from it yet.")
                            }
                        }
                        .padding(.leading, 8)
                        .opacity(LinkItemInstaller.sourceExists(app.files[index].path) ? 1 : 0.45)
                    }
                }
            }

            if let defaults = app.defaults, !defaults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Defaults:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(defaults, id: \.self) { defaultCommand in
                        HStack {
                            Image(systemName: "terminal.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(defaultCommand)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 8)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

struct OSRecipeRow: View {
    let recipe: OSRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "gear")
                    .foregroundColor(.orange)
                Text(recipe.name)
                    .font(.headline)
                Spacer()
            }

            HStack {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("defaults \(recipe.defaults)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 8)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

#Preview {
    RecipesView()
}
