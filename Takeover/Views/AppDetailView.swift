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
    var onResetLocations: () -> Void = {}
    var isIgnored = false
    var onToggleIgnore: () -> Void = {}

    private var appStatus: LinkStatus { group.status }

    private var anyLinked: Bool { group.items.contains { LinkItemInstaller.isLinked($0) } }
    private var anyUnlinked: Bool { group.items.contains { !LinkItemInstaller.isLinked($0) } }

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
                    Button(action: onResetLocations) {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Reset Locations: bring back removed catalog locations and move each into Takeover/\(RecipeInstaller.appFolder(group.id))/[location], keeping files and links")
                    Spacer()
                    Button(isIgnored ? "Stop Ignoring" : "Ignore", action: onToggleIgnore)
                        .help(isIgnored ? "Show this app in Sync Settings again" : "Hide this app from Sync Settings on every Mac")
                    if !group.items.isEmpty {
                        LinkStatusIcon(status: appStatus)
                    }
                    // Both show while some locations are installed and some aren't.
                    if anyLinked {
                        Button { onUninstallAll(group.items) } label: {
                            Label("Uninstall All", systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                    if anyUnlinked || group.items.isEmpty {
                        Button {
                            for item in group.items where !LinkItemInstaller.isLinked(item) { onRun(item) }
                        } label: {
                            Label("Install All", systemImage: "arrow.down.circle")
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
