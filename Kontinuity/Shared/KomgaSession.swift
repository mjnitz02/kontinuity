//
//  KomgaSession.swift
//  Kontinuity
//
//  Everything the connected UI talks to, built once per server and handed down
//  the view tree. Views ask the session for the service rather than rebuilding a
//  client from the Keychain each time, which is what makes the whole browse tree
//  swappable for a stub in previews and UI tests.
//

import Foundation
import KontinuityCore
import SwiftData
import SwiftUI

@MainActor
@Observable
final class KomgaSession {
    let server: Server
    let service: any KomgaServing
    let thumbnails: ThumbnailLoader
    let sync: ProgressionSyncEngine
    let downloads: DownloadCoordinator
    let glasses: GlassesCoordinator

    /// The server's libraries, loaded once for the sidebar. Small and stable —
    /// a home Komga has a handful — so there's no paging here.
    private(set) var libraries: [KomgaLibrary] = []
    private(set) var librariesError: String?

    /// No default on `downloadSessionConfiguration`: a default argument
    /// expression runs in a nonisolated context regardless of this
    /// initializer's own isolation, so `DownloadSessionProvider.live` — main-
    /// actor-isolated under this project's default actor isolation — can't be
    /// read as one. `RootView` already threads its own value.
    init(
        server: Server,
        service: any KomgaServing,
        modelContext: ModelContext,
        downloadSessionConfiguration: URLSessionConfiguration
    ) {
        self.server = server
        self.service = service
        thumbnails = ThumbnailLoader(service: service)
        sync = ProgressionSyncEngine(
            service: service,
            modelContext: modelContext,
            device: KomgaDevice(id: server.deviceID, name: server.deviceName)
        )
        downloads = DownloadCoordinator(
            service: service,
            modelContext: modelContext,
            settings: DownloadSettings(),
            sessionConfiguration: downloadSessionConfiguration
        )
        glasses = GlassesCoordinator(settings: GlassesSettings())
        // The only path a manually-built GlassesSceneDelegate has into this
        // session's state — see AppDelegate's doc comment.
        AppDelegate.glassesCoordinator = glasses
    }

    /// The choke point every "push then refresh" trigger should call instead
    /// of `sync.flush()` directly — a book whose completion is confirmed
    /// synced by the flush is exactly what auto-remove-on-finish is watching
    /// for (PLAN §6), and this is the one place that's checked regardless of
    /// which of the five triggers fired.
    func flushAndReconcileDownloads() async {
        await sync.flush()
        downloads.reapAutoRemovable()
    }

    func loadLibraries() async {
        do {
            libraries = try await service.libraries()
            librariesError = nil
        } catch {
            // Non-fatal: the sidebar's fixed roots still work, and "All Series"
            // covers everything the user can see anyway.
            librariesError = (error as? KomgaError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refresh() async {
        thumbnails.invalidate()
        await loadLibraries()
    }
}

/// How a `Server` becomes something to talk to. The live implementation reads
/// the API key from the Keychain; UI tests and previews substitute a stub
/// without any view knowing the difference.
struct KomgaProvider {
    var makeService: (Server, any SecretStoring) throws -> (any KomgaServing)?

    static let live = KomgaProvider { server, secrets in
        try server.client(secrets: secrets, session: .komga)
    }
}

extension EnvironmentValues {
    @Entry var komgaProvider: KomgaProvider = .live
    @Entry var downloadSessionProvider: DownloadSessionProvider = .live
}

/// How `DownloadCoordinator` gets its transport. Live is a background
/// `URLSession` configuration so transfers survive app suspension (PLAN §6);
/// `UITestSupport` substitutes a plain ephemeral one, since a UI test's stub
/// server has no real background transfer to survive.
struct DownloadSessionProvider {
    var makeConfiguration: () -> URLSessionConfiguration

    static let live = DownloadSessionProvider {
        let bundleID = Bundle.main.bundleIdentifier ?? "org.mattnitzken.Kontinuity"
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(bundleID).downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return configuration
    }
}

extension URLSession {
    /// One session for JSON and posters alike.
    ///
    /// Komga stamps an ETag and `max-age=0, must-revalidate` on both, so a
    /// shared `URLCache` buys conditional requests on every call — a refresh of
    /// an unchanged library is a page of 304s — with no staleness risk, because
    /// `max-age=0` means nothing is ever served without asking the server first.
    static let komga: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: nil
        )
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }()
}
