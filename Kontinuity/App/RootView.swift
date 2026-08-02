//
//  RootView.swift
//  Kontinuity
//
//  Phase 1 shell. The sidebar roots are still placeholders — phase 2 fills them
//  with libraries/series/books. What's real here is the connected-vs-not split.
//

import KontinuityCore
import SwiftData
import SwiftUI

struct RootView: View {
    // Multi-server is an explicit non-goal (PLAN §1), so "the server" is the
    // first (and only) row.
    @Query(sort: \Server.addedDate) private var servers: [Server]
    @State private var selection: SidebarItem? = .libraries

    private enum SidebarItem: Hashable, CaseIterable {
        case libraries, keepReading, onDeck, downloaded, server

        var title: String {
            switch self {
            case .libraries: "Libraries"
            case .keepReading: "Keep Reading"
            case .onDeck: "On Deck"
            case .downloaded: "Downloaded"
            case .server: "Server"
            }
        }

        var systemImage: String {
            switch self {
            case .libraries: "books.vertical"
            case .keepReading: "bookmark"
            case .onDeck: "square.stack"
            case .downloaded: "arrow.down.circle"
            case .server: "server.rack"
            }
        }

        /// Phase 2 replaces these with real content.
        var isImplemented: Bool {
            self == .server
        }
    }

    var body: some View {
        if let server = servers.first {
            connected(to: server)
        } else {
            NavigationStack {
                ConnectView()
            }
        }
    }

    private func connected(to server: Server) -> some View {
        NavigationSplitView {
            List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationTitle(AppInfo.name)
        } detail: {
            NavigationStack {
                switch selection {
                case .server:
                    ServerSettingsView(server: server)
                case let .some(item):
                    ContentUnavailableView(
                        item.title,
                        systemImage: item.systemImage,
                        description: Text("Browsing arrives in the next phase.")
                    )
                case .none:
                    ContentUnavailableView(
                        "Nothing selected",
                        systemImage: "sidebar.left",
                        description: Text("Pick something from the sidebar.")
                    )
                }
            }
        }
    }
}

#Preview("Not connected") {
    RootView()
        .modelContainer(for: Server.self, inMemory: true)
}
