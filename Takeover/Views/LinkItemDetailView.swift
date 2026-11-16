//
//  ItemDetail.swift
//  Takeover
//
//  Created by Alex Vaos on 2/13/25.
//

import SwiftUI
import SwiftData
import AppKit

struct LinkItemDetailView: View {
    @Bindable var linkItem: LinkItem
    /// Every location, so a new To name can avoid one that's already used.
    @Query private var allLinkItems: [LinkItem]
    /// Shown inside an app's page: no name field, sized to its content.
    var embedded = false

    private var onSave: ((LinkItem) -> Void)?
    private var onRun: ((LinkItem) -> Void)?
    private var onDelete: ((LinkItem) -> Void)?
    private var onUninstall: ((LinkItem) -> Void)?

    @State private var saveTask: Task<Void, Never>?
    @State private var showCommand = false
    @State private var renaming = false
    @State private var draftLabel = ""
    @State private var renameError: String?
    @FocusState private var renameFocused: Bool

    init(linkItem: LinkItem,
         embedded: Bool = false,
         onSave: ((LinkItem) -> Void)? = nil,
         onRun: ((LinkItem) -> Void)? = nil,
         onDelete: ((LinkItem) -> Void)? = nil,
         onUninstall: ((LinkItem) -> Void)? = nil) {
        self.linkItem = linkItem
        self.embedded = embedded
        self.onSave = onSave
        self.onRun = onRun
        self.onDelete = onDelete
        self.onUninstall = onUninstall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if embedded {
                HStack(spacing: 12) {
                    if renaming {
                        TextField("Name", text: $draftLabel)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { renaming = false }
                    } else {
                        Text(RecipeInstaller.displayName(of: linkItem)).font(.headline)
                    }
                    Spacer()
                    statusAndButtons
                    Menu {
                        Button("Rename") {
                            draftLabel = RecipeInstaller.displayName(of: linkItem)
                            renaming = true
                            renameFocused = true
                        }
                        if showCommand || !linkItem.defaults.isEmpty {
                            Button("Remove Command", role: .destructive) {
                                linkItem.defaults = ""
                                showCommand = false
                            }
                        } else {
                            Button("Add Command") { showCommand = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        onDelete?(linkItem)
                    } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Remove this location")
                }
            } else {
            // App Name Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("App Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                TextField("Name", text: $linkItem.name)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            }

            // Symlink Paths Section
            VStack(alignment: .leading, spacing: 20) {
                if !embedded {
                    Text("Sync Setting Configuration")
                        .font(.headline)
                }

                // FROM Path (Source)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("From:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("(Source path to be linked)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if !linkItem.from.isEmpty {
                            Button(action: {
                                openInFinder(path: linkItem.from)
                            }) {
                                Image(systemName: "folder")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Open in Finder")
                        }
                    }

                    HStack(spacing: 8) {
                        Text(linkItem.from.isEmpty ? "No path selected" : linkItem.from)
                            .textSelection(.enabled)
                            .foregroundColor(linkItem.from.isEmpty ? .secondary : .primary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)

                        Button("Browse...") {
                            Task {
                                if let path = try await selectFile(startingAt: fromBrowseStart) {
                                    let wasLinked = LinkItemInstaller.isLinked(linkItem)
                                    linkItem.from = path
                                    if !wasLinked { updateToForPickedSource() }
                                }
                            }
                        }
                    }

                    if let target = existingLinkTarget {
                        let matches = (target as NSString).standardizingPath
                            == (Config.expandedDestinationPath(for: linkItem.to) as NSString).standardizingPath
                        let gone = !FileOps.exists(PathUtility.expandTildeToRealHome(linkItem.from))
                        Label {
                            Text(gone
                                 ? "Broken link: points to \(target), which no longer exists. Install relinks it to To."
                                 : "Already a link, pointing to \(target)")
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: matches ? "link" : "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundColor(gone ? .red : (matches ? .secondary : .orange))
                    }

                    if let warning = missingSourceWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .card(enabled: !embedded)

                // Arrow indicator
                HStack {
                    Spacer()
                    Image(systemName: "arrow.down")
                        .foregroundColor(.secondary)
                    Spacer()
                }

                // TO Path (Destination)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("To:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("(Destination for the link)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if !linkItem.to.isEmpty {
                            Button(action: {
                                openInFinder(path: linkItem.to)
                            }) {
                                Image(systemName: "folder")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Open in Finder")
                        }
                    }

                    HStack(spacing: 8) {
                        Text(linkItem.to.isEmpty ? "No path selected" : displayToPath)
                            .textSelection(.enabled)
                            .foregroundColor(linkItem.to.isEmpty ? .secondary : .primary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)

                        Button("Browse...") {
                            Task {
                                if let path = try await selectFile(startingAt: toBrowseStart) {
                                    changeTo(toValue(forPicked: path))
                                }
                            }
                        }
                    }
                }
                .card(enabled: !embedded)
            }

            // Command to run after linking
            if showCommand || !linkItem.defaults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Run After Linking")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            linkItem.defaults = ""
                            showCommand = false
                        } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                        .help("Remove command")
                    }
                    TextField("defaults write ...", text: $linkItem.defaults)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("This command runs after the link is created when you click Install")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if !embedded {
                Spacer()

                Divider()

                // Action Buttons
                HStack(spacing: 12) {
                    Button("Delete", role: .destructive) {
                        onDelete?(linkItem)
                    }

                    Spacer()

                    statusAndButtons
                }
            }
        }
        .card(enabled: embedded, padding: 16)
        .padding(embedded ? 0 : 24)
        .frame(minWidth: embedded ? 0 : 400)
        .alert(
            "Couldn't change this location's destination",
            isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })
        ) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
        .onChange(of: linkItem.name) { oldValue, newValue in
            if oldValue != newValue {
                saveChangesToYAML()
            }
        }
        .onChange(of: linkItem.from) { oldValue, newValue in
            if oldValue != newValue {
                saveChangesToYAML()
            }
        }
        .onChange(of: linkItem.to) { oldValue, newValue in
            if oldValue != newValue {
                saveChangesToYAML()
            }
        }
        .onChange(of: linkItem.defaults) { oldValue, newValue in
            if oldValue != newValue {
                saveChangesToYAML()
            }
        }
    }

    private func saveChangesToYAML() {
        // Cancel previous save task
        saveTask?.cancel()

        // Create new debounced save task
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay

            // Check if task was cancelled
            if !Task.isCancelled {
                // Trigger save callback to persist to YAML
                onSave?(linkItem)
            }
        }
    }

    /// Renames the location. Its destination folder in the settings folder is
    /// renamed with it so the two keep matching (and a linked location is
    /// relinked to the new folder); a To chosen outside the settings folder
    /// only gets a new label.
    private func commitRename() {
        renaming = false
        let new = RecipeInstaller.folderName(draftLabel)
        guard !new.isEmpty, new != RecipeInstaller.displayName(of: linkItem) else { return }
        if RecipeInstaller.isAbsolute(linkItem.to) || linkItem.to.isEmpty {
            linkItem.label = new
        } else {
            let to = RecipeInstaller.uniqueDestination(appName: linkItem.name, location: new, from: linkItem.from, others: otherItems)
            guard changeTo(to) else { return }
        }
        onSave?(linkItem)
    }

    /// Changes To through `changeDestination`, so a linked location's files
    /// move and its link follows. Shows why when it can't.
    @discardableResult
    private func changeTo(_ to: String) -> Bool {
        do {
            try LinkItemInstaller.changeDestination(of: linkItem, to: to)
            return true
        } catch {
            renameError = error.localizedDescription
            return false
        }
    }

    /// Link status icon plus the Install / Uninstall button.
    @ViewBuilder private var statusAndButtons: some View {
        statusIcon

        // Inside an app's page each location has its own icon button; the
        // app's Install All / Uninstall covers every location.
        if embedded {
            if symlinkIsValid {
                Button { onUninstall?(linkItem) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                    .buttonStyle(.plain)
                    .help("Uninstall this location")
            } else {
                Button { onRun?(linkItem) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain)
                    .help("Install this location")
                    .disabled(linkItem.from.isEmpty || linkItem.to.isEmpty)
            }
        } else {
            if symlinkIsValid {
                Button("Uninstall") {
                    onUninstall?(linkItem)
                }
            } else {
                Button("Install") {
                    onRun?(linkItem)
                }
                .buttonStyle(.borderedProminent)
                .disabled(linkItem.from.isEmpty || linkItem.to.isEmpty)
            }
        }
    }

    private var statusIcon: some View {
        LinkStatusIcon(status: LinkItemInstaller.status(linkItem))
    }

    /// After picking a From folder, name the destination after it so To reflects
    /// what's being synced. Leaves a To the user chose themselves (an absolute
    /// path) alone. Not called for a location that was linked, so an installed
    /// destination never moves.
    private func updateToForPickedSource() {
        guard !RecipeInstaller.isAbsolute(linkItem.to) else { return }
        changeTo(RecipeInstaller.destination(appName: linkItem.name, from: linkItem.from, others: otherItems))
    }

    private var otherItems: [LinkItem] {
        allLinkItems.filter { $0.persistentModelID != linkItem.persistentModelID }
    }

    /// Shown when the source isn't on this Mac, so installing doesn't quietly
    /// link an empty folder.
    private var missingSourceWarning: String? {
        guard !LinkItemInstaller.sourceExists(linkItem.from) else { return nil }
        if !linkItem.to.isEmpty, FileOps.exists(Config.expandedDestinationPath(for: linkItem.to)) {
            return "This path doesn't exist on this Mac. Installing links it to your synced copy."
        }
        return "This path doesn't exist on this Mac, so there's nothing to sync yet. Installing links an empty folder here."
    }

    /// Where the existing symlink at "from" points, if there is one.
    private var existingLinkTarget: String? {
        guard !linkItem.from.isEmpty else { return nil }
        let path = PathUtility.expandTildeToRealHome(linkItem.from)
        guard FileOps.isSymlink(path) else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    private var symlinkIsValid: Bool { LinkItemInstaller.isLinked(linkItem) }

    private var displayToPath: String {
        guard !linkItem.to.isEmpty else {
            return ""
        }

        // Show path inside the chosen settings folder
        return Config.destinationPath(for: linkItem.to)
    }

    /// Nearest folder that exists at or above `path`, for an open panel to start in.
    private func existingFolder(for path: String) -> String? {
        var dir = PathUtility.expandTildeToRealHome(path)
        while !dir.isEmpty, dir != "/" {
            if FileOps.isDirectory(dir) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// From's Browse starts at the current From (or its nearest existing parent).
    private var fromBrowseStart: String? {
        linkItem.from.isEmpty ? nil : existingFolder(for: linkItem.from)
    }

    /// To's Browse starts in the settings folder: at the current To's parent so
    /// it's selectable, or the settings folder itself when To isn't there yet.
    private var toBrowseStart: String? {
        let root = Config.expandedBackupPath
        guard !linkItem.to.isEmpty else { return existingFolder(for: root) }
        let dest = Config.expandedDestinationPath(for: linkItem.to)
        return existingFolder(for: (dest as NSString).deletingLastPathComponent) ?? existingFolder(for: root)
    }

    /// A pick inside the settings folder is stored as its name there (so it moves
    /// with the folder); anything else as the absolute path.
    private func toValue(forPicked path: String) -> String {
        let root = (Config.expandedBackupPath as NSString).standardizingPath
        let picked = (path as NSString).standardizingPath
        guard picked.hasPrefix(root + "/") else { return PathUtility.abbreviateRealHome(path) }
        return String(picked.dropFirst(root.count + 1))
    }

    func selectFile(startingAt directory: String? = nil) async throws -> String? {
        let panel = NSOpenPanel()
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select the path for the link"

        var filename: String?
        if panel.runModal() == .OK {
            filename = panel.url?.path
        }
        return filename
    }

    func openInFinder(path: String) {
        // A "from" field is a full path; a "to" field is just a backup name.
        let target: String
        if path.contains("/") {
            target = PathUtility.expandTildeToRealHome(path)
        } else {
            target = PathUtility.expandTildeToRealHome("\(Config.backupPath)/\(path)")
        }

        // If the target exists, reveal (and select) it in Finder. Otherwise walk
        // up to the nearest existing ancestor and open that.
        if FileOps.exists(target) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
            return
        }

        var ancestor = (target as NSString).deletingLastPathComponent
        while !ancestor.isEmpty, ancestor != "/", !FileOps.exists(ancestor) {
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        if FileOps.exists(ancestor) {
            NSWorkspace.shared.open(URL(fileURLWithPath: ancestor))
        } else {
            print("openInFinder: no existing path found for '\(path)'")
        }
    }
}

#Preview("With Data") {
    let linkItem: LinkItem = LinkItem(
        name: "Fonts",
        from: "/Users/user/Library/Fonts",
        to: "/Users/user/Documents/Takeover/Fonts"
    )
    LinkItemDetailView(linkItem: linkItem)
}

#Preview("Empty") {
    let linkItem: LinkItem = LinkItem.empty()
    LinkItemDetailView(linkItem: linkItem)
}


extension View {
    /// Rounded, bordered box around a group of related fields.
    @ViewBuilder
    func card(enabled: Bool = true, padding: CGFloat = 12) -> some View {
        if enabled {
            self
                .padding(padding)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .cornerRadius(8)
        } else {
            self
        }
    }
}

/// ✓ installed at the right destination, ? linked somewhere else, ✕ not installed.
struct LinkStatusIcon: View {
    let status: LinkStatus

    var body: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                .help("Installed")
        case .differentLocation:
            Image(systemName: "questionmark.circle.fill").foregroundColor(.orange)
                .help("Installed at a different location")
        case .broken:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                .help("Broken link: what it points to is gone. Install relinks it.")
        case .notInstalled:
            Image(systemName: "circle.dashed").foregroundColor(.secondary)
                .help("Not installed")
        }
    }
}
