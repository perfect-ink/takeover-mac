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
                        Text(linkItem.label.isEmpty ? linkItem.name : linkItem.label).font(.headline)
                    }
                    Spacer()
                    statusAndButtons
                    Menu {
                        Button("Rename") {
                            draftLabel = linkItem.label.isEmpty ? linkItem.name : linkItem.label
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
                                if let path = try await selectFile() {
                                    linkItem.from = path
                                }
                            }
                        }
                    }

                    if let target = existingLinkTarget {
                        let matches = (target as NSString).standardizingPath
                            == (Config.expandedDestinationPath(for: linkItem.to) as NSString).standardizingPath
                        Label {
                            Text("Already a link, pointing to \(target)")
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: matches ? "link" : "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundColor(matches ? .secondary : .orange)
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
                                if let path = try await selectFile() {
                                    linkItem.to = path
                                }
                            }
                        }
                    }
                }
                .card(enabled: !embedded)
            }

            Divider()

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

    private func commitRename() {
        let new = draftLabel.trimmingCharacters(in: .whitespaces)
        linkItem.label = (new == linkItem.name) ? "" : new
        renaming = false
        onSave?(linkItem)
    }

    /// Link status icon plus the Install / Uninstall button.
    @ViewBuilder private var statusAndButtons: some View {
        statusIcon

        // Inside an app's page the app-level Install / Uninstall covers every location.
        if !embedded {
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

    func selectFile() async throws -> String? {
        let panel = NSOpenPanel()
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
        case .notInstalled:
            Image(systemName: "circle.dashed").foregroundColor(.secondary)
                .help("Not installed")
        }
    }
}
