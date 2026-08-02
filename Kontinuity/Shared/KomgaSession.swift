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

    /// The server's libraries, loaded once for the sidebar. Small and stable —
    /// a home Komga has a handful — so there's no paging here.
    private(set) var libraries: [KomgaLibrary] = []
    private(set) var librariesError: String?

    init(server: Server, service: any KomgaServing, modelContext: ModelContext) {
        self.server = server
        self.service = service
        thumbnails = ThumbnailLoader(service: service)
        sync = ProgressionSyncEngine(
            service: service,
            modelContext: modelContext,
            device: KomgaDevice(id: server.deviceID, name: server.deviceName)
        )
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
