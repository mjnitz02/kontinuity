//
//  RootView.swift
//  Kontinuity
//
//  The connected-vs-not split, and the sidebar the rest of the app hangs off.
//  PLAN §7: sidebar → content grid → detail, Komga-ish and iPad-native.
//

import KontinuityCore
import SwiftData
import SwiftUI

struct RootView: View {
    /// Multi-server is an explicit non-goal (PLAN §1), so "the server" is the
    /// first (and only) row.
    @Query(sort: \Server.addedDate) private var servers: [Server]

    var body: some View {
        if let server = servers.first {
            ConnectedView(server: server)
        } else {
            NavigationStack {
                ConnectView()
            }
        }
    }
}

/// Owns the `KomgaSession` for a server. Split out from `RootView` so the
/// session is built once, on appearance, rather than on every redraw of a view
/// that a `@Query` re-evaluates.
private struct ConnectedView: View {
    let server: Server

    @Environment(\.secretStore) private var secrets
    @Environment(\.komgaProvider) private var provider
    @Environment(\.downloadSessionProvider) private var downloadSessionProvider
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: KomgaSession?
    @State private var failure: String?

    var body: some View {
        Group {
            if let session {
                BrowseSplitView()
                    .environment(session)
            } else if let failure {
                unavailable(failure)
            } else {
                ProgressView()
            }
        }
        .task(id: server.persistentModelID) {
            guard session == nil else { return }
            do {
                guard let service = try provider.makeService(server, secrets) else {
                    // The Keychain no longer holds the key: a restored backup,
                    // or someone cleared it. Recoverable, but only by
                    // reconnecting — so say that instead of failing every call.
                    failure = "The stored API key is missing."
                    return
                }
                session = KomgaSession(
                    server: server,
                    service: service,
                    modelContext: modelContext,
                    downloadSessionConfiguration: downloadSessionProvider.makeConfiguration()
                )
            } catch {
                failure = (error as? KomgaError)?.errorDescription ?? error.localizedDescription
            }
        }
        // One of PLAN §5's five flush triggers: a backgrounded app can be
        // killed by the system at any moment, so any pending progress needs
        // to be on its way to Komga before that happens, not after.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, let session else { return }
            Task { await session.flushAndReconcileDownloads() }
        }
    }

    private func unavailable(_ message: String) -> some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Can't reach the Keychain", systemImage: "key.slash")
            } description: {
                Text("\(message) Disconnect and connect again to store a new one.")
            } actions: {
                NavigationLink("Server settings") {
                    ServerSettingsView(server: server)
                }
            }
        }
    }
}

private struct BrowseSplitView: View {
    @Environment(KomgaSession.self) private var session
    @State private var selection: SidebarItem? = .allSeries
    @State private var path = NavigationPath()

    enum SidebarItem: Hashable {
        case allSeries
        case keepReading
        case onDeck
        case library(id: String, name: String)
        case downloaded
        case server
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                detail
            }
            // One banner regardless of which screen's refresh triggered the
            // reconciliation — simpler than threading it through every
            // screen individually, including the reader.
            .overlay(alignment: .top) {
                if let notice = session.sync.conflictNotice {
                    ConflictNoticeBanner(notice: notice)
                }
            }
            .animation(.default, value: session.sync.conflictNotice)
        }
        .task { await session.loadLibraries() }
        // A pushed series belongs to the root it was reached from; leaving it on
        // screen after switching roots would show a series from a library the
        // sidebar no longer says you're in.
        .onChange(of: selection) { path = NavigationPath() }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                row(.allSeries, "All Series", "books.vertical", AID.sidebarAllSeries)
                row(.keepReading, "Keep Reading", "bookmark", AID.sidebarKeepReading)
                row(.onDeck, "On Deck", "square.stack", AID.sidebarOnDeck)
            }

            // Only worth a section when there's more than one to choose between;
            // a single-library server is the common case and "All Series"
            // already is that library.
            if session.libraries.count > 1 {
                Section("Libraries") {
                    ForEach(session.libraries) { library in
                        row(
                            .library(id: library.id, name: library.name),
                            library.name,
                            library.unavailable ? "externaldrive.trianglebadge.exclamationmark" : "folder",
                            AID.sidebarLibrary(library.id)
                        )
                    }
                }
            }

            Section {
                row(.downloaded, "Downloaded", "arrow.down.circle", AID.sidebarDownloaded)
                row(.server, "Server", "server.rack", AID.sidebarServer)
            }

            if let error = session.librariesError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier(AID.sidebar)
        .navigationTitle(AppInfo.name)
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, _ id: String) -> some View {
        Label(title, systemImage: symbol)
            // Without combining, the identifier propagates to both the icon and
            // the text, and a lookup can land on the icon — which has the
            // symbol's frame, not the row's, and so isn't tappable.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
            .tag(item)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .allSeries:
            SeriesGridView(libraryID: nil, title: "All Series")
        case let .library(id, name):
            SeriesGridView(libraryID: id, title: name)
        case .keepReading:
            BookShelfView(shelf: .keepReading)
        case .onDeck:
            BookShelfView(shelf: .onDeck)
        case .downloaded:
            DownloadsView()
        case .server:
            ServerSettingsView(server: session.server)
        case .none:
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "sidebar.left",
                description: Text("Pick something from the sidebar.")
            )
        }
    }
}

#Preview("Not connected") {
    RootView()
        .modelContainer(for: [Server.self, Book.self], inMemory: true)
}
