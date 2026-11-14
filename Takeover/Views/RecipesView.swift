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

    /// First free "App", "App (2)", "App (3)"...
    static func uniqueName(base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "-")
    }

    /// Name of the destination inside the settings folder. Apps with several
    /// locations get one folder per location so they don't collide.
    static func destination(for app: AppConfig, path: String) -> String {
        let clean = cleanName(app.name)
        guard app.files.count > 1 else { return clean }
        let last = (path as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "")
        return "\(clean)-\(last)"
    }

    @discardableResult
    static func addLocation(app: AppConfig, path: String, existing: [LinkItem], context: ModelContext) -> LinkItem {
        let name = uniqueName(base: app.name, taken: Set(existing.map { $0.name }))
        let item = LinkItem(
            name: name,
            from: path,
            to: destination(for: app, path: path),
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
            last = addLocation(app: app, path: file.path, existing: all, context: context)
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
                        }
                        .padding(.leading, 8)
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
