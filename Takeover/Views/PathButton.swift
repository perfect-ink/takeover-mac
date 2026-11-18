//
//  PathButton.swift
//  Takeover
//
//  The one button for picking a path, used wherever the app asks for a file
//  or folder (a location's From and To, the installers folder, the settings
//  folder), so every picker looks and reads the same. Icon only, with a
//  tooltip saying what it does.
//

import SwiftUI

struct PathButton: View {
    enum Kind {
        /// Pick a path: From, a new To, a folder.
        case choose
        /// Move what's at a path into another folder.
        case move

        var systemImage: String {
            switch self {
            case .choose: return "folder.badge.plus"
            case .move: return "arrow.right.circle"
            }
        }
    }

    var kind: Kind = .choose
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.systemImage)
                .imageScale(.large)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
