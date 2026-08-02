//
//  UITestSupport.swift
//  Kontinuity
//
//  Launch-time wiring for XCUITests. A UI test drives the shipping app, so the
//  only honest way to make it deterministic is to swap what the app talks to —
//  an in-memory store and a canned server — while leaving every view unchanged.
//
//  DEBUG-only: `make deploy` and `make ipa` build Debug, so this is available
//  where it's wanted, and an archived Release build carries none of it.
//

#if DEBUG

    import Foundation
    import KontinuityCore
    import SwiftData

    enum UITestSupport {
        /// A store that exists only for this launch, seeded for the requested mode.
        /// In-memory is the point: a UI test must not inherit — or leave behind —
        /// state in the simulator's container.
        static func makeContainer(for mode: UITestMode) throws -> ModelContainer {
            let container = try ModelContainer(
                for: Server.self, Book.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )

            if mode == .connected {
                let server = Server(
                    baseURLString: "http://komga.test",
                    deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(),
                    deviceName: "UI Test iPad",
                    apiKeyRef: "ui-test-key",
                    apiKeyID: "ui-test-key-id",
                    userEmail: "uitest@example.com",
                    lastConnectedDate: .now
                )
                container.mainContext.insert(server)
                try container.mainContext.save()
            }

            return container
        }

        /// Serves the canned library instead of building a client from the Keychain.
        static let provider = KomgaProvider { _, _ in StubKomgaService() }

        /// A throwaway Keychain. The connect screen writes an API key on success,
        /// and a UI test must not leave one in the real Keychain — nor read one a
        /// previous run left behind.
        static let secrets: any SecretStoring = InMemorySecretStore()

        /// A background session identifier is process-global — reusing the
        /// real one across repeated UI test launches risks colliding with a
        /// stale session from a previous run. The stub's "server" has no
        /// actual background transfer to survive suspension anyway, so a
        /// plain ephemeral session is both simpler and correct here.
        static let downloadSessionProvider = DownloadSessionProvider { .ephemeral }
    }

#endif
