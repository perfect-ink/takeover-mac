import SwiftUI

/// One app: every sync location it has, plus catalog locations not yet installed.
struct AppDetailView: View {
    let group: AppGroup
    let onAddLocation: () -> Void
    let onSave: (LinkItem) -> Void
    let onRun: (LinkItem) -> Void
    let onDelete: (LinkItem) -> Void
    let onUninstall: (LinkItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(group.id).font(.title2).fontWeight(.semibold)
                    Spacer()
                    Label(group.installed ? "Installed" : "Not installed",
                          systemImage: group.installed ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundColor(group.installed ? .green : .secondary)
                        .font(.callout)
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


                Divider()
                HStack {
                    Button("Add Location", action: onAddLocation)
                    Spacer()
                }
            }
            .padding(24)
        }
    }
}
