//
//  LinkItemList.swift
//  Takeover
//
//  Created by Alex Vaos on 3/4/25.
//

import Foundation
import SwiftUI
import AppKit
import SwiftData

/// One app in the sidebar: its saved sync locations plus any catalog locations not yet added.
struct AppGroup: Identifiable {
    let id: String
    let items: [LinkItem]
    let recipe: AppConfig?
    let installed: Bool

    /// Installed only when every location is; not installed only when none is.
    var status: LinkStatus {
        let all = items.map { LinkItemInstaller.status($0) }
        if all.isEmpty || all.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
        if all.allSatisfy({ $0 == .installed }) { return .installed }
        return .differentLocation
    }
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
    /// Off by default: the sidebar lists only apps that are on this Mac.
    @AppStorage("syncSettings.showAll") private var showAll = false
    @ObservedObject private var settingsManager = SettingsManager.shared

    /// Apps hidden with Ignore. Kept in the synced settings so every Mac hides them.
    private var ignored: Set<String> { Set(settingsManager.settings?.ignoredSyncSettings ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: "Sync Settings") { EmptyView() }

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
                            onUninstallAll: { onUninstallAll(items: $0) },
                            onResetLocations: { resetLocations(group.items, app: group.id) },
                            isIgnored: ignored.contains(group.id),
                            onToggleIgnore: { toggleIgnore(group) }
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

    /// Add, Show All and Refresh sit above the list they change.
    private var sidebarControls: some View {
        HStack(spacing: 8) {
            Button(action: addSyncSetting) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a sync setting: pick the folder or file to sync")
            Toggle(isOn: $showAll) {
                Label("Show All", systemImage: showAll ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showAll ? "Hide apps that aren't on this Mac" : "Also show apps that aren't on this Mac (\(hiddenCount) hidden)")
            Spacer()
            if linkItems.contains(where: RecipeInstaller.needsAppFolder) {
                Button { resetLocations(linkItems) } label: { Image(systemName: "folder.badge.gearshape") }
                    .buttonStyle(.borderless)
                    .help("Move every location into Takeover/App/Location, keeping its files and links")
            }
            if repository.isLoading { ProgressView().scaleEffect(0.5) }
            Button {
                Task { await repository.load(force: true) }
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless)
            .help("Refresh: fetch the latest app recipes")
            .disabled(repository.isLoading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarControls
            Divider()
            sidebarList
        }
    }

    private var sidebarList: some View {
        Group {
            if visibleGroups.isEmpty {
                VStack(spacing: 8) {
                    Text(groups.isEmpty ? "No Sync Settings" : "No apps found on this Mac")
                        .foregroundColor(.secondary)
                    if !groups.isEmpty {
                        Button("Show All") { showAll = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    let _ = linkRefresh // re-read link status after installs
                    ForEach(sidebarSections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.groups) { group in sidebarRow(group) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onAppear {
                    if selection == nil { selection = sidebarSections.first?.groups.first?.id }
                }
            }
        }
    }

    /// Installed (linked) first, then the rest on this Mac, then, with Show
    /// All, apps that aren't on this Mac. Empty sections are left out.
    private var sidebarSections: [SidebarSection] {
        let visible = visibleGroups.filter { !ignored.contains($0.id) }
        let linked = visible.filter { $0.status != .notInstalled }
        let onMac = visible.filter { $0.status == .notInstalled && $0.installed }
        let others = visible.filter { $0.status == .notInstalled && !$0.installed }
        return [
            SidebarSection(title: "Installed", groups: linked),
            SidebarSection(title: "On This Mac", groups: onMac),
            SidebarSection(title: "Not on This Mac", groups: others),
            SidebarSection(title: "Ignored", groups: visibleGroups.filter { ignored.contains($0.id) }),
        ].filter { !$0.groups.isEmpty }
    }

    private struct SidebarSection {
        let title: String
        let groups: [AppGroup]
    }

    private func sidebarRow(_ group: AppGroup) -> some View {
        HStack {
            Text(group.id).fontWeight(.medium)
            Spacer()
            LinkStatusIcon(status: group.status)
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
            Divider()
            Button(ignored.contains(group.id) ? "Stop Ignoring" : "Ignore") { toggleIgnore(group) }
        }
    }

    /// What the sidebar lists: every group with Show All on; otherwise only apps
    /// on this Mac, plus ones still being set up (a location with no From yet)
    /// and the selected one, so nothing vanishes while you're editing it.
    private var visibleGroups: [AppGroup] {
        guard !showAll else { return groups }
        return groups.filter { group in
            !ignored.contains(group.id) &&
            (group.installed || group.id == selection || group.items.contains { $0.from.isEmpty })
        }
    }

    private var hiddenCount: Int { groups.count - visibleGroups.count }

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
                all.append(RecipeInstaller.addLocation(app: app, file: file, existing: all, context: modelContext))
                added = true
            }
        }
        if moveIntoAppFolders(all, apps: apps) { added = true }
        if added { Task { await saveToYAML() } }
    }

    /// Gives locations from before app folders an "App/Location" To. Only ones
    /// that aren't linked and have nothing at their old destination; the
    /// rest move with Reset Locations, which moves their files too.
    private func moveIntoAppFolders(_ all: [LinkItem], apps: [AppConfig]) -> Bool {
        var changed = false
        for item in all where RecipeInstaller.needsAppFolder(item)
            && LinkItemInstaller.status(item) == .notInstalled
            && !FileOps.exists(Config.expandedDestinationPath(for: item.to)) {
            item.to = defaultDestination(for: item, apps: apps, others: all.filter { $0 !== item })
            item.label = ""
            changed = true
        }
        if changed { try? modelContext.save() }
        return changed
    }

    /// Adds a sync setting of the user's own: pick a folder or file, and it's
    /// named after it, with To filled in. Selecting it keeps it in the list
    /// even while only installed apps are shown.
    private func addSyncSetting() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder or file to sync"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let from = PathUtility.abbreviateRealHome(url.path)
        let taken = Set(linkItems.map { $0.name } + groups.map { $0.id })
        let name = RecipeInstaller.uniqueName(base: url.lastPathComponent, taken: taken)
        let to = RecipeInstaller.destination(appName: name, from: from, others: linkItems)
        modelContext.insert(LinkItem(name: name, from: from, to: to))
        try? modelContext.save()
        selection = RecipeInstaller.baseName(name)
        Task { await saveToYAML() }
    }

    /// Hides an app from Sync Settings (it's listed under Ignored with Show All
    /// on), or brings it back. Saved in the synced settings.
    private func toggleIgnore(_ group: AppGroup) {
        var names = ignored
        if names.contains(group.id) { names.remove(group.id) } else { names.insert(group.id) }
        var settings = settingsManager.settings ?? SettingsYaml(links: [])
        settings.ignoredSyncSettings = names.isEmpty ? nil : names.sorted()
        Task { try? await SettingsManager.shared.saveSettings(settings) }
    }

    /// Adds a blank location to the app for the user to fill in.
    private func addLocation(to group: AppGroup) {
        let name = RecipeInstaller.uniqueName(base: group.id, taken: Set(linkItems.map { $0.name }))
        let to = RecipeInstaller.uniqueDestination(
            appName: group.id, location: "Location \(group.items.count + 1)", from: "", others: linkItems)
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

    /// Gives each location the destination it would get today (Takeover/App/
    /// Location, named from the catalog), moving its synced files there and
    /// relinking it when it's linked, so nothing is lost. With an app, its
    /// removed catalog locations come back too.
    private func resetLocations(_ items: [LinkItem], app: String? = nil) {
        if let app { RemovedLocations.forget(app: app) }
        let apps = repository.response?.apps ?? []
        var failures: [String] = []
        for item in items where !item.to.isEmpty && !RecipeInstaller.isAbsolute(item.to) {
            let others = linkItems.filter { $0 !== item }
            let to = defaultDestination(for: item, apps: apps, others: others)
            guard to != item.to else { continue }
            do {
                try LinkItemInstaller.moveDestination(of: item, to: to)
                item.to = to
                item.label = ""
            } catch {
                failures.append("\(RecipeInstaller.displayName(of: item)): \(error.localizedDescription)")
            }
        }
        try? modelContext.save()
        seedFromCatalog()
        Task { await saveToYAML() }
        linkRefresh += 1
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    /// Takeover/App/Location for a location: the catalog's name for its path,
    /// else its rename label, else its source's name.
    private func defaultDestination(for item: LinkItem, apps: [AppConfig], others: [LinkItem]) -> String {
        let from = PathUtility.expandTildeToRealHome(item.from)
        let catalogName = apps.first { $0.name == RecipeInstaller.baseName(item.name) }?
            .files.first { PathUtility.expandTildeToRealHome($0.path) == from }?.name
        let name = catalogName ?? (item.label.isEmpty ? nil : item.label)
        return item.from.isEmpty
            ? RecipeInstaller.uniqueDestination(appName: item.name, location: name ?? "Location", from: "", others: others)
            : RecipeInstaller.destination(appName: item.name, from: item.from, named: name, others: others)
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

    /// Lets an app's removed catalog locations be added again.
    static func forget(app: String) {
        let all = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { !$0.hasPrefix("\(app)|") }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func add(app: String, path: String) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        let entry = id(app, path)
        if !all.contains(entry) { all.append(entry) }
        UserDefaults.standard.set(all, forKey: key)
    }
}
