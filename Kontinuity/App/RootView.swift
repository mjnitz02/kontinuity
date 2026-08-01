//
//  RootView.swift
//  Kontinuity
//
//  Phase 0 placeholder. Becomes the NavigationSplitView shell in phase 2 —
//  sidebar (Libraries / Keep Reading / On Deck / Downloaded / Search),
//  content grid, detail.
//

import KontinuityCore
import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Libraries", systemImage: "books.vertical")
                Label("Keep Reading", systemImage: "bookmark")
                Label("Downloaded", systemImage: "arrow.down.circle")
            }
            .navigationTitle(AppInfo.name)
        } detail: {
            ContentUnavailableView(
                "Not connected",
                systemImage: "server.rack",
                description: Text("Add a Komga server to get started.")
            )
        }
    }
}

#Preview {
    RootView()
}
