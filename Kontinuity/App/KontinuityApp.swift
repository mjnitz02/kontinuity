//
//  KontinuityApp.swift
//  Kontinuity
//

import KontinuityCore
import SwiftData
import SwiftUI

@main
struct KontinuityApp: App {
    private let container: ModelContainer
    /// How the app reaches Komga, and where it keeps the API key. Both are
    /// substituted wholesale under a UI test so no view needs to know it's
    /// being tested.
    private let provider: KomgaProvider
    private let secrets: any SecretStoring

    init() {
        #if DEBUG
            let mode = UITestMode.current
            provider = mode == nil ? .live : UITestSupport.provider
            secrets = mode == nil ? KeychainSecretStore() : UITestSupport.secrets
        #else
            provider = .live
            secrets = KeychainSecretStore()
        #endif

        do {
            #if DEBUG
                if let mode {
                    container = try UITestSupport.makeContainer(for: mode)
                    return
                }
            #endif
            container = try ModelContainer(for: Server.self)
        } catch {
            // Nothing sensible to fall back to: without a store the app can't
            // remember a server, and silently running in-memory would look like
            // data loss on every launch.
            fatalError("Could not open the Kontinuity data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.komgaProvider, provider)
                .environment(\.secretStore, secrets)
        }
        .modelContainer(container)
    }
}
