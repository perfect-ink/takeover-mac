import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AppInstallerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var installers: [AppInstaller]

    var body: some View {
        VSplitView {
            Group {
                if let installer = installers.first {
                    AppInstallerContentView(installer: installer, onSave: save)
                } else {
                    Text("Loading…")
                        .foregroundColor(.secondary)
                }
            }
            .frame(minHeight: 260)

            AppRestoreListEditor()
                .frame(minHeight: 140, idealHeight: 200)
        }
        .onAppear {
            if installers.isEmpty {
                let item = AppInstaller(name: "Apps", path: "")
                modelContext.insert(item)
            }
        }
    }

    private func save() {
        try? modelContext.save()
        Task { await saveToYAML() }
    }

    @MainActor
    private func saveToYAML() async {
        let configs = installers.map { AppInstallerConfig(name: $0.name, path: $0.path) }
        guard var settings = SettingsManager.shared.settings else { return }
        settings.appInstallers = configs
        try? await SettingsManager.shared.saveSettings(settings)
    }
}

/// The Applications tab's Self Service style catalog: a grid of app cards.
/// An app that isn't installed shows Install; an installed one shows Open and
/// Uninstall. Cards come from the installers folder and from Homebrew apps on
/// the restore list below (see `AppCard`).
struct AppInstallerContentView: View {
    @Bindable var installer: AppInstaller
    var onSave: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppEntryModel.name) private var restoreEntries: [AppEntryModel]

    @State private var discoveredApps: [DiscoveredApp] = []
    @State private var installedCasks: Set<String> = []
    @State private var isScanning = false
    @State private var busy: Set<String> = []
    /// Bundle names learned from an install, when the .app inside a zip or DMG
    /// is named differently from the installer file.
    @State private var installedNames: [String: String] = [:]
    @State private var installError: String? = nil
    @State private var confirmUninstall: AppCard? = nil
    @State private var saveTask: Task<Void, Never>?

    private var cards: [AppCard] {
        AppCard.cards(installers: discoveredApps, restoreList: restoreEntries.map {
            Profile.AppEntry(name: $0.name, source: Profile.AppSource(rawValue: $0.source) ?? .brew,
                             cask: $0.cask.isEmpty ? nil : $0.cask)
        })
    }

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabActionBar(title: "Applications") {
                TextField("Installers folder, e.g. ~/Downloads/Apps", text: $installer.path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 260)
                    .onSubmit { refresh() }
                Button("Browse") { browseForFolder() }
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Scan the folder again")
                .disabled(isScanning)
                if isScanning { ProgressView().controlSize(.small) }
            }

            if cards.isEmpty && !isScanning {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(installer.path.isEmpty
                         ? "Pick a folder of installers (.dmg, .zip, .pkg or .app) with Browse, or add Homebrew apps to the restore list below."
                         : "No installers found in that folder.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(cards) { card in
                            let appURL = installedURL(for: card)
                            AppCardView(
                                card: card,
                                installedURL: appURL,
                                isInstalled: isInstalled(card, installedURL: appURL),
                                isBusy: busy.contains(card.id),
                                alwaysInstall: restoreEntry(for: card)?.alwaysInstall ?? false,
                                onAlwaysInstallChange: { setAlwaysInstall($0, for: card) },
                                onInstall: { install(card) },
                                onOpen: { if let url = appURL { NSWorkspace.shared.open(url) } },
                                onUninstall: { confirmUninstall = card }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .alert("Couldn't finish", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK") { installError = nil }
        } message: {
            Text(installError ?? "")
        }
        .confirmationDialog(
            "Uninstall \(confirmUninstall?.name ?? "")?",
            isPresented: Binding(
                get: { confirmUninstall != nil },
                set: { if !$0 { confirmUninstall = nil } }
            ),
            presenting: confirmUninstall
        ) { card in
            Button("Uninstall", role: .destructive) { uninstall(card) }
        } message: { _ in
            Text("The app is removed from this Mac. Its settings stay where they are.")
        }
        .onChange(of: installer.path) { _, _ in scheduleSave() }
        .onAppear { refresh() }
    }

    // MARK: Install state

    private func installedURL(for card: AppCard) -> URL? {
        InstalledApps.url(named: installedNames[card.id] ?? card.name)
    }

    private func isInstalled(_ card: AppCard, installedURL: URL?) -> Bool {
        if installedURL != nil { return true }
        if case .homebrew(let cask) = card.source { return installedCasks.contains(cask) }
        return false
    }

    // MARK: Always install

    /// The restore-list entry behind a card: same cask for Homebrew cards,
    /// otherwise same name (ignoring case).
    private func restoreEntry(for card: AppCard) -> AppEntryModel? {
        if case .homebrew(let cask) = card.source,
           let match = restoreEntries.first(where: { $0.source == "brew" && $0.cask == cask }) {
            return match
        }
        return restoreEntries.first { $0.name.caseInsensitiveCompare(card.name) == .orderedSame }
    }

    /// Marks an app to be installed automatically on restore or a new Mac.
    /// An installer-folder app not on the restore list yet is added to it as
    /// a local installer, so the flag has somewhere to live in the synced settings.
    private func setAlwaysInstall(_ on: Bool, for card: AppCard) {
        if let entry = restoreEntry(for: card) {
            entry.alwaysInstall = on
        } else if on {
            switch card.source {
            case .installer:
                modelContext.insert(AppEntryModel(name: card.name, source: "local", alwaysInstall: true))
            case .homebrew(let cask):
                modelContext.insert(AppEntryModel(name: card.name, source: "brew", cask: cask, alwaysInstall: true))
            }
        }
        AppEntryModel.saveRestoreList(in: modelContext)
    }

    // MARK: Actions

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            installer.path = url.path
            scheduleSave()
            refresh()
        }
    }

    /// Rescans the installers folder and asks Homebrew what it has installed.
    private func refresh() {
        let path = installer.path
        isScanning = true
        Task {
            let result = await Task.detached { () -> ([DiscoveredApp], Set<String>) in
                (path.isEmpty ? [] : AppInstallerEngine.scan(at: path), AppRestoreEngine.installedCasks())
            }.value
            discoveredApps = result.0
            installedCasks = result.1
            isScanning = false
        }
    }

    private func install(_ card: AppCard) {
        busy.insert(card.id)
        Task {
            switch card.source {
            case .installer(let app):
                let result = await Task.detached { AppInstallerEngine.install(app) }.value
                if let name = result.installedName { installedNames[card.id] = name }
                if !result.success { installError = result.message }
            case .homebrew(let cask):
                let entry = Profile.AppEntry(name: card.name, source: .brew, cask: cask)
                let outcome = await Task.detached { AppRestoreEngine.install(entry, localFolder: nil) }.value
                if outcome == .needsHomebrew {
                    installError = "\(card.name) installs with Homebrew, which isn't on this Mac yet. Install Homebrew from the Restore tab, then try again."
                } else if !outcome.ok {
                    installError = outcome.label
                }
            }
            busy.remove(card.id)
            refresh()
        }
    }

    private func uninstall(_ card: AppCard) {
        busy.insert(card.id)
        Task {
            let result: (success: Bool, message: String)
            switch card.source {
            case .installer(let app):
                let name = installedNames[card.id]
                result = await Task.detached { AppInstallerEngine.uninstall(app, installedName: name) }.value
            case .homebrew(let cask):
                result = await Task.detached { AppRestoreEngine.uninstallCask(cask) }.value
            }
            if result.success {
                installedNames.removeValue(forKey: card.id)
            } else {
                installError = result.message
            }
            busy.remove(card.id)
            refresh()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { onSave?() }
        }
    }
}

/// One app card: icon, name, a short line, and Install or Open and Uninstall.
/// The card itself isn't clickable, so it has no hover state; its buttons do.
struct AppCardView: View {
    let card: AppCard
    let installedURL: URL?
    let isInstalled: Bool
    let isBusy: Bool
    let alwaysInstall: Bool
    let onAlwaysInstallChange: (Bool) -> Void
    let onInstall: () -> Void
    let onOpen: () -> Void
    let onUninstall: () -> Void

    private var subtitle: String {
        AppCard.subtitle(for: card.source,
                         installedVersion: isInstalled ? installedURL.map(InstalledApps.version(at:)) ?? "" : nil)
    }

    private var icon: NSImage {
        if let url = installedURL { return NSWorkspace.shared.icon(forFile: url.path) }
        if case .installer(let app) = card.source, app.fileType == .app {
            return NSWorkspace.shared.icon(forFile: app.fileURL.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(isInstalled ? "Working…" : "Installing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isInstalled {
                    if installedURL != nil {
                        Button("Open", action: onOpen)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Uninstall", role: .destructive, action: onUninstall)
                        .buttonStyle(.bordered)
                } else {
                    Button("Install", action: onInstall)
                        .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.regular)
            .frame(height: 28)

            Toggle("Always install", isOn: Binding(get: { alwaysInstall }, set: onAlwaysInstallChange))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Install \(card.name) automatically on restore or a new Mac. Apps left unchecked are only installed when you click Install.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .contextMenu {
            if case .installer(let app) = card.source {
                Button("Reveal Installer in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.fileURL])
                }
            }
            if let url = installedURL {
                Button("Show App in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.name)
    }
}

// MARK: - Restore list editor

/// The curated "restore list" — synced in the profile and (re)installed on
/// another Mac. Separate from the folder scanner above.
struct AppRestoreListEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppEntryModel.name) private var entries: [AppEntryModel]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Sync & Restore list").font(.headline)
                Text("installed on another Mac via Homebrew or a local installer")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    modelContext.insert(AppEntryModel(name: "New App"))
                    persist()
                } label: { Label("Add App", systemImage: "plus") }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()

            if entries.isEmpty {
                Text("No apps yet — Add App, set its Homebrew cask, and it'll be part of every restore.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        RestoreListRow(entry: entry, onChange: persist, onDelete: {
                            modelContext.delete(entry); persist()
                        })
                    }
                }
            }
        }
        .background(.bar)
    }

    private func persist() {
        AppEntryModel.saveRestoreList(in: modelContext)
    }
}

private struct RestoreListRow: View {
    @Bindable var entry: AppEntryModel
    var onChange: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $entry.name).textFieldStyle(.roundedBorder).frame(width: 160)
                .onSubmit(onChange)

            Picker("", selection: $entry.source) {
                Text("Homebrew").tag("brew")
                Text("Local").tag("local")
                Text("App Store").tag("mas")
            }
            .labelsHidden().frame(width: 110)
            .onChange(of: entry.source) { _, _ in onChange() }

            if entry.source == "brew" {
                TextField("cask id, e.g. rectangle", text: $entry.cask)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .onSubmit(onChange)
            } else if entry.source == "mas" {
                TextField("App Store id", text: $entry.masID)
                    .textFieldStyle(.roundedBorder).onSubmit(onChange)
            } else {
                Text("matched by name in the folder above")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
            Toggle("Always install", isOn: $entry.alwaysInstall)
                .toggleStyle(.checkbox)
                .help("Install this app automatically on restore or a new Mac")
                .onChange(of: entry.alwaysInstall) { _, _ in onChange() }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
