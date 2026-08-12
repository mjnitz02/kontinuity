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

            if mode != .fresh {
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
            }

            if mode == .offlineWithDownloads {
                seedDownloadedBooks(in: container.mainContext)
            }

            try container.mainContext.save()
            return container
        }

        /// Windrunner Vol. 1 (finished) and Vol. 2 (partway through), both
        /// downloaded — enough for a UI test to assert the offline fallback
        /// views: Windrunner shows up offline and Neon Requiem/Halcyon Drift
        /// (nothing downloaded there) don't; and the series' own book list
        /// shows only these two, not Vol. 3, with Vol. 2's in-progress state
        /// preserved.
        private static func seedDownloadedBooks(in context: ModelContext) {
            let finished = Book(
                id: UITestFixture.readBookID,
                localPage: 190,
                localReadDate: Date(timeIntervalSince1970: 1_770_000_000),
                pageHref: "",
                mediaType: "image/jpeg",
                seriesID: UITestFixture.inProgressSeriesID,
                seriesTitle: "Windrunner",
                title: "Windrunner, Vol. 1",
                number: "1",
                numberSort: 1,
                pagesCount: 190,
                downloadState: .downloaded,
                downloadedDate: .now
            )
            let inProgress = Book(
                id: UITestFixture.inProgressBookID,
                localPage: 42,
                localReadDate: Date(timeIntervalSince1970: 1_780_000_000),
                pageHref: "",
                mediaType: "image/jpeg",
                seriesID: UITestFixture.inProgressSeriesID,
                seriesTitle: "Windrunner",
                title: "Windrunner, Vol. 2",
                number: "2",
                numberSort: 2,
                pagesCount: 190,
                downloadState: .downloaded,
                downloadedDate: .now
            )
            context.insert(finished)
            context.insert(inProgress)
        }

        /// Serves the canned library instead of building a client from the
        /// Keychain — offline-shaped for `.offline`/`.offlineWithDownloads`
        static let provider = KomgaProvider { _, _ in
            let mode = UITestMode.current
            return StubKomgaService(offline: mode == .offline || mode == .offlineWithDownloads)
        }

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
