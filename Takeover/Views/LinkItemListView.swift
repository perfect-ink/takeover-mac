//
//  LinkItemList.swift
//  Takeover
//
//  Created by Alex Vaos on 3/4/25.
//

import Foundation
import SwiftUI
import SwiftData

/// One app in the sidebar: its saved sync locations plus any catalog locations not yet added.
struct AppGroup: Identifiable {
    let id: String
    let items: [LinkItem]
    let recipe: AppConfig?
    let installed: Bool
}

struct LinkItemListView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \LinkItem.name) private var linkItems: [LinkItem]
    @State private var selection: String? = nil
    private var repository = Repository.shared
    @State private var errorMessage: String? = nil
    @State private var pendingUninstall: [LinkItem] = []
    /// Bumped after any link change so link status (read from disk) redraws.
    @State private var linkRefresh = 0

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: "Sync Settings") {
                if repository.isLoading { ProgressView().scaleEffect(0.6) }
                Button {
                    Task { await repository.load(force: true) }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Fetch the latest app recipes")
                .disabled(repository.isLoading)
            }

            HStack(spacing: 0) {
                sidebar
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 300)
                Divider()

                Group {
                    if let group = groups.first(where: { $0.id == selection }) {
                        AppDetailView(
                            group: group,
                            onAddLocation: { addLocation(to: group) },
                            onSave: onSave,
                            onRun: onRun,
                            onDelete: onDelete,
                            onUninstall: onUninstall,
                            onUninstallAll: { onUninstallAll(items: $0) }
                        )
                        .id("\(group.id)-\(linkRefresh)")
                    } else {
                        Text("Select an app")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: repository.response?.apps.count) { seedFromCatalog() }
        .confirmationDialog(
            "Uninstall \(pendingUninstall.first.map { RecipeInstaller.baseName($0.name) } ?? "")?",
            isPresented: Binding(get: { !pendingUninstall.isEmpty }, set: { if !$0 { pendingUninstall = [] } }),
            titleVisibility: .visible,
            presenting: pendingUninstall
        ) { items in
            Button("Copy from destination") { items.forEach { uninstall($0, mode: .copyFromDestination) } }
            Button("Move destination") { items.forEach { uninstall($0, mode: .moveDestination) } }
            Button("Remove links, leave empty", role: .destructive) { items.forEach { uninstall($0, mode: .removeLink) } }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text("The links at \(items.map { $0.from }.joined(separator: ", ")) will be removed. Copy leaves your synced files where they are; Move takes them out of your settings folder.")
        }
        .alert(
            "Sync Setting operation failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        Group {
            if groups.isEmpty {
                Text("No Sync Settings")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        HStack {
                            Text(group.id).fontWeight(.medium)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .foregroundColor(group.installed ? .primary : .secondary)
                        .opacity(group.installed ? 1 : 0.45)
                        .contentShape(Rectangle())
                        .tag(group.id)
                        .contextMenu {
                            ForEach(group.items) { item in
                                Button("Install \(item.from)") { onRun(linkItem: item) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListHeaderHeight, 0)
                .onAppear {
                    if selection == nil { selection = groups.first?.id }
                }
            }
        }
    }

    /// Catalog apps and the user's own items as one list; apps that aren't installed sort last, greyed out.
    private var groups: [AppGroup] {
        var byName = Dictionary(grouping: linkItems, by: { RecipeInstaller.baseName($0.name) })
        var result: [AppGroup] = []

        for app in repository.response?.apps ?? [] {
            let items = byName.removeValue(forKey: app.name) ?? []
            let paths = app.files.map { $0.path } + items.map { $0.from }
            result.append(AppGroup(
                id: app.name, items: items, recipe: app,
                installed: RecipeInstaller.isInstalled(name: app.name, paths: paths)
            ))
        }
        for (name, items) in byName {
            result.append(AppGroup(
                id: name, items: items, recipe: nil,
                installed: RecipeInstaller.isInstalled(name: name, paths: items.map { $0.from })
            ))
        }
        return result.sorted {
            $0.installed != $1.installed ? $0.installed : $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    // MARK: locations

    /// Every catalog location becomes a real sync setting, so there is one kind of
    /// item (installed or not) rather than recipes waiting to be added.
    private func seedFromCatalog() {
        guard let apps = repository.response?.apps else { return }
        var all = (try? modelContext.fetch(FetchDescriptor<LinkItem>())) ?? []
        var added = false
        for app in apps {
            let have = Set(all
                .filter { RecipeInstaller.baseName($0.name) == app.name }
                .map { PathUtility.expandTildeToRealHome($0.from) })
            for file in app.files where !have.contains(PathUtility.expandTildeToRealHome(file.path))
                && !RemovedLocations.contains(app: app.name, path: file.path) {
                all.append(RecipeInstaller.addLocation(app: app, path: file.path, existing: all, context: modelContext))
                added = true
            }
        }
        if added { Task { await saveToYAML() } }
    }

    /// Adds a blank location to the app for the user to fill in.
    private func addLocation(to group: AppGroup) {
        let name = RecipeInstaller.uniqueName(base: group.id, taken: Set(linkItems.map { $0.name }))
        let to = "\(RecipeInstaller.cleanName(group.id))-\(group.items.count + 1)"
        modelContext.insert(LinkItem(name: name, to: to))
        try? modelContext.save()
        Task { await saveToYAML() }
    }

    private func pullFromRepository() {
        Task {
            let result = Shell.runTrusted("git pull")
            print("Git pull result: \(result.text)")

            // Reload settings after pull
            do {
                let settings = try await SettingsManager.shared.loadSettings()
                await syncSettingsToDatabase(settings: settings)
            } catch {
                print("Error reloading settings after pull: \(error)")
            }
        }
    }

    @MainActor
    private func syncSettingsToDatabase(settings: SettingsYaml) async {
        // Fetch existing items
        let descriptor = FetchDescriptor<LinkItem>()
        let existingItems = (try? modelContext.fetch(descriptor)) ?? []

        // Create a set of existing names for quick lookup
        let existingNames = Set(existingItems.map { $0.name })

        // Add new items from YAML that don't exist in database
        for linkConfig in settings.links {
            if !existingNames.contains(linkConfig.name) {
                let newItem = LinkItem(
                    name: linkConfig.name,
                    from: linkConfig.from,
                    to: linkConfig.to
                )
                modelContext.insert(newItem)
            }
        }

        try? modelContext.save()
    }

    private func onRun(linkItem: LinkItem) -> Void {
        do {
            try LinkItemInstaller.install(linkItem: linkItem)
        } catch {
            errorMessage = error.localizedDescription
        }
        linkRefresh += 1
    }

    /// Asks what to do with the synced files before removing a link.
    private func onUninstall(linkItem: LinkItem) -> Void {
        let path = PathUtility.expandTildeToRealHome(linkItem.from)
        if FileOps.isSymlink(path) {
            pendingUninstall = [linkItem]
        }
    }

    /// Uninstall every linked location of an app after one question.
    private func onUninstallAll(items: [LinkItem]) -> Void {
        let linked = items.filter { FileOps.isSymlink(PathUtility.expandTildeToRealHome($0.from)) }
        if !linked.isEmpty { pendingUninstall = linked }
    }

    private func uninstall(_ linkItem: LinkItem, mode: UninstallMode) {
        do {
            try LinkItemInstaller.uninstall(linkItem: linkItem, mode: mode)
        } catch {
            errorMessage = error.localizedDescription
        }
        linkRefresh += 1
    }

    private func onSave(linkItem: LinkItem) -> Void {
        // Check for duplicate names
        let duplicates = linkItems.filter { $0.name == linkItem.name && $0 != linkItem }
        if !duplicates.isEmpty {
            // Make name unique by appending a number
            var counter = 1
            var uniqueName = "\(linkItem.name) (\(counter))"
            while linkItems.contains(where: { $0.name == uniqueName && $0 != linkItem }) {
                counter += 1
                uniqueName = "\(linkItem.name) (\(counter))"
            }
            linkItem.name = uniqueName
        }

        // With @Bindable, changes are automatically tracked
        // Save to database
        try? modelContext.save()

        // Also save to YAML file
        Task {
            await saveToYAML()
        }
    }

    @MainActor
    private func saveToYAML() async {
        // Convert all LinkItems to YAML format
        let linkConfigs = linkItems.map { item in
            LinkConfig(
                name: item.name,
                from: item.from,
                to: item.to,
                defaults: item.defaults.isEmpty ? nil : item.defaults,
                label: item.label.isEmpty ? nil : item.label
            )
        }

        // Keep the rest of the settings (Mac defaults, installers, apps):
        // saving a bare `SettingsYaml(links:)` used to wipe them.
        var settings = SettingsManager.shared.settings ?? SettingsYaml(links: [])
        settings.links = linkConfigs

        do {
            try await SettingsManager.shared.saveSettings(settings)
            print("Settings saved to YAML")
        } catch {
            print("Error saving settings to YAML: \(error)")
        }
    }

    private func onDelete(linkItem: LinkItem) -> Void {
        RemovedLocations.add(app: RecipeInstaller.baseName(linkItem.name), path: linkItem.from)
        uninstall(linkItem, mode: .removeLink)
        withAnimation { modelContext.delete(linkItem) }
        try? modelContext.save()
        Task { await saveToYAML() }
    }
}

#Preview("LinkItemList filled") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: LinkItem.self, configurations: config)

    let sampleItems = [
        LinkItem(name: "Dropbox", from: "/Users/user/Dropbox", to: "/opt/dropbox"),
        LinkItem(name: "Adobe Fonts", from: "/Library/Application Support/Adobe/CoreSync/plugins/livetype", to: "/System/Library/Fonts"),
        LinkItem(name: "Audio Plugins", from: "/Library/Audio/Plug-Ins", to: "/usr/local/audio")
    ]

    for item in sampleItems {
        container.mainContext.insert(item)
    }

    return LinkItemListView()
        .modelContainer(container)
}

#Preview("LinkItemList empty") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: LinkItem.self, configurations: config)

    return LinkItemListView()
        .modelContainer(container)
}

/// Catalog locations the user removed, so they aren't added back on the next catalog load.
enum RemovedLocations {
    private static let key = "takeover.removedLocations"

    private static func id(_ app: String, _ path: String) -> String {
        "\(app)|\(PathUtility.expandTildeToRealHome(path))"
    }

    static func contains(app: String, path: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id(app, path))
    }

    static func add(app: String, path: String) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        let entry = id(app, path)
        if !all.contains(entry) { all.append(entry) }
        UserDefaults.standard.set(all, forKey: key)
    }
}
