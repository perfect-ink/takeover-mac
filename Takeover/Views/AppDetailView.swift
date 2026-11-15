import SwiftUI

/// One app: every sync location it has, plus catalog locations not yet installed.
struct AppDetailView: View {
    let group: AppGroup
    let onAddLocation: () -> Void
    let onSave: (LinkItem) -> Void
    let onRun: (LinkItem) -> Void
    let onDelete: (LinkItem) -> Void
    let onUninstall: (LinkItem) -> Void
    let onUninstallAll: ([LinkItem]) -> Void
    var isIgnored = false
    var onToggleIgnore: () -> Void = {}

    private var appStatus: LinkStatus { group.status }

    private var allLinked: Bool {
        !group.items.isEmpty && group.items.allSatisfy { LinkItemInstaller.isLinked($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text(group.id).font(.title2).fontWeight(.semibold)
                    Button(action: onAddLocation) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Add Location")
                    Spacer()
                    Button(isIgnored ? "Stop Ignoring" : "Ignore", action: onToggleIgnore)
                        .help(isIgnored ? "Show this app in Sync Settings again" : "Hide this app from Sync Settings on every Mac")
                    if !group.items.isEmpty {
                        LinkStatusIcon(status: appStatus)
                    }
                    if allLinked {
                        Button("Uninstall") { onUninstallAll(group.items) }
                    } else {
                        Button("Install") {
                            for item in group.items where !LinkItemInstaller.isLinked(item) { onRun(item) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(group.items.isEmpty)
                    }
                }

                ForEach(group.items.sorted { $0.name < $1.name }) { item in
                    LinkItemDetailView(
                        linkItem: item,
                        embedded: true,
                        onSave: onSave,
                        onRun: onRun,
                        onDelete: onDelete,
                        onUninstall: onUninstall
                    )
                }


            }
            .padding(24)
        }
    }
}
