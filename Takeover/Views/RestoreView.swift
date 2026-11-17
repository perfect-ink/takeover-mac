import AppKit
import SwiftUI
import SwiftData

/// Where a restore reads from: a Takeover settings folder on this Mac
/// (iCloud Drive, Dropbox, any folder) or a Mac saved to the Takeover Cloud
/// account.
enum RestoreSource: Hashable {
    case folder(String)   // tilde-prefixed root path
    case computer(Int)
}

/// Restore: pick a Takeover folder (or, with Takeover Cloud, one of the
/// account's Macs), see what it holds, and apply all of it (or a selection)
/// to this Mac: Mac defaults, sync settings (links), installers and apps.
struct RestoreView: View {
    @EnvironmentObject var account: AccountManager
    @EnvironmentObject var sync: ProfileSyncManager
    @Environment(\.modelContext) private var modelContext
    @Query private var installers: [AppInstaller]
    @Query(sort: \LinkItem.name) private var currentLinks: [LinkItem]
    @Query(sort: \MacDefault.name) private var currentDefaults: [MacDefault]
    @Query(sort: \AppEntryModel.name) private var currentApps: [AppEntryModel]

    @State private var isSavingState = false
    @State private var saveStateMessage: String?
    @State private var selection: RestoreSource?
    @State private var profile: Profile?
    @State private var loadingProfile = false
    @State private var loadError: String?

    /// Folders that already hold Takeover settings, plus any the user picked.
    @State private var folders: [StorageLocation] = StorageLocation.detectExisting().map(\.location)

    @State private var pickedDefaults: Set<String> = []
    @State private var pickedLinks: Set<String> = []
    @State private var pickedApps: Set<String> = []
    @State private var pickedInstallers: Set<String> = []

    @State private var isRestoring = false
    @State private var outcomes: [String: String] = [:]   // row id -> status text
    @State private var summary: String?

    /// The Applications tab's installers folder, or the Takeover folder's Apps.
    private var localFolder: String? {
        if let path = installers.first?.path, !path.isEmpty { return path }
        return InstallerImporter.defaultFolder()
    }

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: "Restore") {
                if account.isSignedIn {
                    if let saveStateMessage {
                        Text(saveStateMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    if isSavingState { ProgressView().scaleEffect(0.7) }
                    Button {
                        Task { await saveCurrentState() }
                    } label: { Label("Save Current State", systemImage: "square.and.arrow.up") }
                    .help("Save this Mac's Sync Settings, Mac Defaults, and Applications to your account now")
                    .disabled(isSavingState)
                }
                Button {
                    chooseFolder()
                } label: { Label("Choose Folder", systemImage: "folder.badge.plus") }
                .help("Restore from a Takeover settings folder anywhere on this Mac")
                Button {
                    refresh()
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(sync.isLoadingComputers)
            }

            HStack(spacing: 0) {
                sourceList
                    .frame(width: 260)
                Divider()
                detail
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: account.isSignedIn) {
            if account.isSignedIn { await sync.loadComputers() }
        }
    }

    // MARK: sources

    private var sourceList: some View {
        List(selection: $selection) {
            Section("Folders") {
                if folders.isEmpty {
                    Text("No Takeover folders found. Use Choose Folder to pick one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(folders, id: \.rootPath) { location in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(location.provider == .folder
                                 ? (location.rootPath as NSString).lastPathComponent
                                 : location.provider.title)
                                .fontWeight(.medium)
                            if isCurrentStorage(location) { badge("in use") }
                        }
                        Text(location.rootPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .tag(RestoreSource.folder(location.rootPath))
                }
            }

            if account.isSignedIn {
                Section("Takeover Cloud") {
                    if sync.computers.isEmpty && !sync.isLoadingComputers {
                        Text("No Macs on this account yet").foregroundStyle(.secondary)
                    }
                    ForEach(sync.computers) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(c.name).fontWeight(.medium)
                                if sync.isThisMac(c) { badge("this Mac") }
                            }
                            Text("\(c.summary.defaults) defaults · \(c.summary.links) links · \(c.summary.apps) apps")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(RestoreSource.computer(c.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if sync.isLoadingComputers && folders.isEmpty { ProgressView() }
        }
        .onChange(of: selection) { _, source in
            Task { await loadProfile(source) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
    }

    private func isCurrentStorage(_ location: StorageLocation) -> Bool {
        StorageLocation.load().map { $0.expandedRootPath == location.expandedRootPath } ?? false
    }

    private func folderLocation(_ rootPath: String) -> StorageLocation? {
        folders.first { $0.rootPath == rootPath }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder that holds your Takeover settings (takeover-settings.yaml)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let location = StorageLocation.forFolder(url.path)
        if !folders.contains(where: { $0.expandedRootPath == location.expandedRootPath }) {
            folders.insert(location, at: 0)
        }
        selection = .folder(folders.first { $0.expandedRootPath == location.expandedRootPath }!.rootPath)
    }

    private func refresh() {
        let picked = folders
        let detected = StorageLocation.detectExisting().map(\.location)
        folders = detected + picked.filter { p in !detected.contains { $0.expandedRootPath == p.expandedRootPath } }
        Task {
            if account.isSignedIn { await sync.loadComputers() }
            await loadProfile(selection)
        }
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        if selection == nil {
            Text("Select a folder or a Mac to see its settings")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadingProfile {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let profile {
            VStack(spacing: 0) {
                List {
                    if profile.isEmpty {
                        Text("Nothing to restore here yet.").foregroundStyle(.secondary)
                    }
                    section("Mac Defaults", picked: $pickedDefaults, ids: profile.macDefaults.map(\.id)) {
                        ForEach(profile.macDefaults) { d in
                            row(id: d.id, picked: $pickedDefaults,
                                title: d.name, subtitle: "\(d.domain) \(d.key) = \(d.value)")
                        }
                    }
                    section("Sync Settings", picked: $pickedLinks, ids: profile.links.map(\.id)) {
                        ForEach(profile.links) { l in
                            row(id: l.id, picked: $pickedLinks, title: l.name, subtitle: "\(l.from) → \(l.to)")
                        }
                    }
                    let installerEntries = profile.appInstallers ?? []
                    section("Installers", picked: $pickedInstallers, ids: installerEntries.map(\.id)) {
                        ForEach(installerEntries, id: \.id) { i in
                            row(id: i.id, picked: $pickedInstallers, title: i.name, subtitle: i.path)
                        }
                    }
                    section("Applications", picked: $pickedApps, ids: profile.apps.map(\.id)) {
                        ForEach(profile.apps) { a in
                            row(id: a.id, picked: $pickedApps,
                                title: a.name,
                                subtitle: (a.source == .brew ? "brew · \(a.cask ?? "—")" : a.source.rawValue)
                                    + (a.alwaysInstall ? " · always install" : ""))
                        }
                    }
                }

                Divider()
                HStack {
                    if let summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    } else if let note = storageNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isRestoring { ProgressView().scaleEffect(0.7) }
                    Button("Apply Selected") { Task { await restore(profile) } }
                        .disabled(isRestoring || nothingPicked)
                    Button("Apply All") {
                        pickAll(profile)
                        Task { await restore(profile) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestoring || profile.isEmpty)
                    .help("Apply every Mac default, sync setting and installer listed here, and install the apps marked Always Install")
                }
                .padding(12)
            }
        } else {
            Text(loadError ?? "Couldn't read these settings").foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var nothingPicked: Bool {
        pickedDefaults.isEmpty && pickedLinks.isEmpty && pickedApps.isEmpty && pickedInstallers.isEmpty
    }

    /// Sync settings link into the storage folder, so restoring links from a
    /// folder makes it this Mac's settings folder.
    private var storageNote: String? {
        guard case .folder(let root)? = selection, let location = folderLocation(root),
              !isCurrentStorage(location) else { return nil }
        return "Applying makes this folder where Takeover keeps your settings."
    }

    private func pickAll(_ profile: Profile) {
        pickedDefaults = Set(profile.macDefaults.map(\.id))
        pickedLinks = Set(profile.links.map(\.id))
        // Apps install only when marked "always install"; others stay
        // listed for the user to pick by hand.
        pickedApps = Set(profile.apps.filter(\.alwaysInstall).map(\.id))
        pickedInstallers = Set((profile.appInstallers ?? []).map(\.id))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, picked: Binding<Set<String>>, ids: [String],
                                        @ViewBuilder content: () -> Content) -> some View {
        if !ids.isEmpty {
            Section {
                content()
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Button(picked.wrappedValue.isSuperset(of: ids) ? "None" : "All") {
                        if picked.wrappedValue.isSuperset(of: ids) { picked.wrappedValue.subtract(ids) }
                        else { picked.wrappedValue.formUnion(ids) }
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func row(id: String, picked: Binding<Set<String>>, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { picked.wrappedValue.contains(id) },
                set: { picked.wrappedValue.toggle(id, on: $0) }
            )).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let status = outcomes[id] {
                Text(status).font(.caption)
                    .foregroundStyle(status.hasPrefix("✓") ? .green : status.hasPrefix("…") ? .secondary : .red)
            }
        }
    }

    // MARK: actions

    /// Explicit "save now" — builds a profile from this Mac's current Sync
    /// Settings / Mac Defaults / Applications and pushes it immediately
    /// (unlike SettingsManager's debounced push-on-edit, this always sends
    /// the full current state right away, whether or not anything changed
    /// since the last edit).
    private func saveCurrentState() async {
        isSavingState = true
        saveStateMessage = nil
        defer { isSavingState = false }

        var profile = Profile.snapshot(
            defaults: currentDefaults.filter { !$0.value.isEmpty },
            links: currentLinks,
            apps: currentApps
        )
        profile.appInstallers = SettingsManager.shared.settings?.appInstallers?.map {
            Profile.AppInstallerEntry(name: $0.name, path: $0.path)
        }
        await sync.push(profile)

        if let err = sync.lastPushError {
            saveStateMessage = "Save failed — \(err)"
        } else {
            saveStateMessage = "Saved just now"
            await sync.loadComputers()
        }
    }

    private func loadProfile(_ source: RestoreSource?) async {
        outcomes = [:]; summary = nil; loadError = nil
        guard let source else { profile = nil; return }
        loadingProfile = true
        defer { loadingProfile = false }
        var loaded: Profile?
        switch source {
        case .folder(let root):
            do {
                let settings = try SettingsManager.read(folder: root)
                loaded = Profile(settings: settings, catalog: MacDefaultCatalog.shared.entries)
            } catch {
                loadError = "Couldn't read the settings in \(root): \(error.localizedDescription)"
            }
        case .computer(let id):
            loaded = await sync.profile(for: id, force: true)
            if loaded == nil { loadError = sync.computersError }
        }
        guard selection == source else { return } // user moved on meanwhile
        profile = loaded
        if let loaded { pickAll(loaded) }
    }

    private func restore(_ profile: Profile) async {
        isRestoring = true
        summary = nil
        defer { isRestoring = false }
        var ok = 0, fail = 0

        // Links point into the settings folder, so a folder restore adopts
        // that folder as this Mac's storage before linking anything.
        if case .folder(let root)? = selection, let location = folderLocation(root), !isCurrentStorage(location) {
            do {
                try SettingsManager.shared.changeLocation(to: location)
                NotificationCenter.default.post(name: .storageLocationChanged, object: nil)
            } catch {
                summary = "Couldn't switch to this folder: \(error.localizedDescription)"
                return
            }
        }

        // Same path as login/sync enforcement: only differing defaults are
        // written, and each follow-up (killall Dock…) runs once.
        let defaults = profile.macDefaults.filter { pickedDefaults.contains($0.id) }
        let result = MacDefaultsEnforcer.enforce(defaults.map {
            MacDefaultConfig(name: $0.name, domain: $0.domain, key: $0.key, type: $0.type, value: $0.value,
                             hostFlag: $0.hostFlag, postCommand: $0.postCommand)
        })
        for d in defaults {
            if result.failed.contains(d.name) {
                outcomes[d.id] = "✗ couldn't write"; fail += 1
            } else {
                upsertDefault(d)
                outcomes[d.id] = result.applied.contains(d.name) ? "✓ applied" : "✓ already set"; ok += 1
            }
        }

        for l in profile.links where pickedLinks.contains(l.id) {
            outcomes[l.id] = "… linking"
            let item = LinkItem(name: l.name, from: l.from, to: l.to, defaults: l.defaults)
            do {
                try LinkItemInstaller.install(linkItem: item)
                upsertLink(l)
                outcomes[l.id] = "✓ linked"; ok += 1
            } catch {
                outcomes[l.id] = "✗ \(error.localizedDescription)"; fail += 1
            }
        }

        for i in profile.appInstallers ?? [] where pickedInstallers.contains(i.id) {
            upsertInstaller(i)
            outcomes[i.id] = "✓ added"; ok += 1
        }

        for a in profile.apps where pickedApps.contains(a.id) {
            outcomes[a.id] = "… installing"
            let folder = localFolder
            let outcome = await Task.detached { AppRestoreEngine.install(a, localFolder: folder) }.value
            switch outcome {
            case .installed, .alreadyPresent:
                outcomes[a.id] = "✓ " + outcome.label; ok += 1
            case .needsHomebrew:
                outcomes[a.id] = "✗ Homebrew required"; fail += 1
            case .skipped(let s):
                outcomes[a.id] = "· \(s)"
            case .failed(let s):
                outcomes[a.id] = "✗ \(s)"; fail += 1
            }
        }

        try? modelContext.save()
        summary = "\(ok) applied" + (fail > 0 ? ", \(fail) failed" : "")
        if profile.apps.contains(where: { pickedApps.contains($0.id) && $0.source == .brew }),
           !AppRestoreEngine.homebrewInstalled {
            summary = (summary ?? "") + " — install Homebrew, then retry"
        }
    }

    private func upsertDefault(_ d: Profile.MacDefaultEntry) {
        let name = d.name
        let existing = (try? modelContext.fetch(FetchDescriptor<MacDefault>(
            predicate: #Predicate { $0.name == name }))) ?? []
        if let m = existing.first { m.value = d.value }
        else {
            modelContext.insert(MacDefault(name: d.name, domain: d.domain, key: d.key, type: d.type,
                                           value: d.value, hostFlag: d.hostFlag, postCommand: d.postCommand))
        }
    }

    private func upsertInstaller(_ i: Profile.AppInstallerEntry) {
        let name = i.name
        let existing = (try? modelContext.fetch(FetchDescriptor<AppInstaller>(
            predicate: #Predicate { $0.name == name }))) ?? []
        let path = PathUtility.expandTildeToRealHome(i.path)
        if let installer = existing.first { installer.path = path }
        else { modelContext.insert(AppInstaller(name: i.name, path: path)) }
    }

    private func upsertLink(_ l: Profile.LinkEntry) {
        let name = l.name
        let existing = (try? modelContext.fetch(FetchDescriptor<LinkItem>(
            predicate: #Predicate { $0.name == name }))) ?? []
        if existing.isEmpty {
            modelContext.insert(LinkItem(name: l.name, from: l.from, to: l.to, defaults: l.defaults))
        }
    }
}

private extension Set {
    mutating func toggle(_ element: Element, on: Bool) {
        if on { insert(element) } else { remove(element) }
    }
}
