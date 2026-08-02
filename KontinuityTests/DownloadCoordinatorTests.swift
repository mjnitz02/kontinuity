//
//  DownloadCoordinatorTests.swift
//  KontinuityTests
//
//  The impure half of phase 5: does the queue actually drive `CBZArchive`/
//  `LocalBookStore` the way PLAN §6 says it should, against a stubbed
//  transport (`StubURLProtocol`, the same one `KomgaClientTests` uses) and an
//  in-memory `Book` store. Hosted inside the `Kontinuity` app target the same
//  way `ProgressionSyncEngineTests` is.
//

import Foundation
import SwiftData
import Testing
@testable import Kontinuity
@testable import KontinuityCore

/// Nested under `SwiftDataTests` so this suite's container can't run
/// concurrently with `ProgressionSyncEngineTests`'s either — see that type.
extension SwiftDataTests {
    @MainActor
    @Suite("DownloadCoordinator", .serialized)
    struct DownloadCoordinatorTests {
        /// Same rationale as ProgressionSyncEngineTests: one shared in-memory
        /// container per suite, wiped per test, rather than one per test.
        private static let container: ModelContainer = {
            do {
                return try ModelContainer(
                    for: Book.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Could not create the in-memory test container: \(error)")
            }
        }()

        private func makeContext() throws -> ModelContext {
            let context = ModelContext(Self.container)
            for book in try context.fetch(FetchDescriptor<Book>()) {
                context.delete(book)
            }
            try context.save()
            return context
        }

        /// A dedicated suite rather than `.standard` — `KontinuityTests` runs
        /// hosted inside the app process (`TEST_HOST`), so `.standard` would be
        /// the same domain a real run of the app writes to.
        private func makeSettings() -> DownloadSettings {
            let defaults = UserDefaults(suiteName: "kontinuity.tests.downloads")!
            defaults.removePersistentDomain(forName: "kontinuity.tests.downloads")
            return DownloadSettings(defaults: defaults)
        }

        private func makeCoordinator(
            context: ModelContext,
            service: FakeDownloadService,
            transport: StubTransport,
            store: LocalBookStore
        ) -> DownloadCoordinator {
            DownloadCoordinator(
                service: service,
                modelContext: context,
                store: store,
                settings: makeSettings(),
                sessionConfiguration: transport.session.configuration
            )
        }

        private func makeStore() -> LocalBookStore {
            LocalBookStore(baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        }

        private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        private func fetchBook(_ context: ModelContext, id: String) -> Book? {
            (try? context.fetch(FetchDescriptor<Book>()))?.first { $0.id == id }
        }

        @Test("enqueueUnread queues every readable unread book and skips the rest")
        func enqueueUnreadFiltersReadable() async throws {
            let context = try makeContext()
            let service = FakeDownloadService()
            service.seriesBooks = [
                Self.komgaBook(id: "readable", pages: 3),
                Self.komgaBook(id: "unanalysed", pages: 0, status: "UNKNOWN")
            ]
            service.manifests["readable"] = Self.manifest(pageCount: 3)
            let store = makeStore()
            let transport = StubTransport([Self.zipStub(pageCount: 3)])
            let coordinator = makeCoordinator(context: context, service: service, transport: transport, store: store)

            await coordinator.enqueueUnread(seriesID: "s1")
            await waitUntil { fetchBook(context, id: "readable")?.downloadState == .downloaded }

            #expect(fetchBook(context, id: "readable")?.downloadState == .downloaded)
            #expect(fetchBook(context, id: "unanalysed") == nil, "an unanalysed book has nothing to download")
        }

        @Test("a whole-file download decompresses and verifies against the manifest")
        func wholeFileDownloadSucceeds() async throws {
            let context = try makeContext()
            let service = FakeDownloadService()
            service.manifests["b1"] = Self.manifest(pageCount: 2)
            let store = makeStore()
            let transport = StubTransport([Self.zipStub(pageCount: 2)])
            let coordinator = makeCoordinator(context: context, service: service, transport: transport, store: store)

            coordinator.enqueue(book: Self.komgaBook(id: "b1", pages: 2))
            await waitUntil { fetchBook(context, id: "b1")?.downloadState == .downloaded }

            let book = try #require(fetchBook(context, id: "b1"))
            #expect(book.downloadState == .downloaded)
            #expect(book.downloadedDate != nil)
            let manifest = try #require(store.manifest(forBook: "b1"))
            #expect(manifest.pages.count == 2)
            #expect(try Data(contentsOf: #require(store.pageURL(forBook: "b1", index: 0))) == Data([0x00]))
            #expect(try Data(contentsOf: #require(store.pageURL(forBook: "b1", index: 1))) == Data([0x01]))
        }

        @Test("a 403 on the whole file falls back to fetching pages individually")
        func forbiddenFallsBackToPerPage() async throws {
            let context = try makeContext()
            let service = FakeDownloadService()
            service.manifests["b1"] = Self.manifest(pageCount: 2)
            service.pageBytes["/pages/1"] = Data([0xAA])
            service.pageBytes["/pages/2"] = Data([0xBB])
            let store = makeStore()
            let transport = StubTransport([.status(403)])
            let coordinator = makeCoordinator(context: context, service: service, transport: transport, store: store)

            coordinator.enqueue(book: Self.komgaBook(id: "b1", pages: 2))
            await waitUntil { fetchBook(context, id: "b1")?.downloadState == .downloaded }

            #expect(fetchBook(context, id: "b1")?.downloadState == .downloaded)
            #expect(service.pageRequests == ["/pages/1", "/pages/2"])
            #expect(try Data(contentsOf: #require(store.pageURL(forBook: "b1", index: 0))) == Data([0xAA]))
            #expect(try Data(contentsOf: #require(store.pageURL(forBook: "b1", index: 1))) == Data([0xBB]))
        }

        @Test("cancelling a still-queued book removes it from the queue without downloading it")
        func cancelQueuedBook() async throws {
            let context = try makeContext()
            let service = FakeDownloadService()
            for index in 1 ... 4 {
                service.manifests["b\(index)"] = Self.manifest(pageCount: 1)
            }
            let store = makeStore()
            // Every whole-file request "succeeds" instantly if asked — the point
            // of this test is that book 4 never gets far enough to ask.
            let transport = StubTransport(Array(repeating: Self.zipStub(pageCount: 1), count: 4))
            let coordinator = makeCoordinator(context: context, service: service, transport: transport, store: store)

            for index in 1 ... 4 {
                coordinator.enqueue(book: Self.komgaBook(id: "b\(index)", pages: 1))
            }
            coordinator.cancel(bookID: "b4")
            await waitUntil { fetchBook(context, id: "b1")?.downloadState == .downloaded }
            await waitUntil { fetchBook(context, id: "b3")?.downloadState == .downloaded }

            #expect(fetchBook(context, id: "b4")?.downloadState == .notDownloaded)
            #expect(!store.isDownloaded("b4"))
        }

        @Test("auto-remove deletes a downloaded book's files once it's finished and synced")
        func autoRemoveDeletesFinishedSyncedBook() throws {
            let context = try makeContext()
            let service = FakeDownloadService()
            let store = makeStore()
            try store.write(
                pages: [LocalPageWrite(data: Data([1]), width: 800, height: 1200, mediaType: "image/jpeg")],
                bookID: "b1"
            )

            let book = Book(
                id: "b1", localPage: 5, localReadDate: .now, pageHref: "", mediaType: "", isPending: false,
                pagesCount: 5, downloadState: .downloaded, downloadedBytes: store.diskUsage(forBook: "b1"),
                downloadedDate: .now
            )
            context.insert(book)
            try context.save()

            let transport = StubTransport()
            let coordinator = makeCoordinator(context: context, service: service, transport: transport, store: store)

            coordinator.reapAutoRemovable()

            #expect(fetchBook(context, id: "b1")?.downloadState == .notDownloaded)
            #expect(!store.isDownloaded("b1"))
        }

        @Test("auto-remove leaves a book with unsynced progress alone")
        func autoRemoveSkipsPendingBook() throws {
            let context = try makeContext()
            let service = FakeDownloadService()
            let store = makeStore()
            try store.write(
                pages: [LocalPageWrite(data: Data([1]), width: 800, height: 1200, mediaType: "image/jpeg")],
                bookID: "b1"
            )

            let book = Book(
                id: "b1", localPage: 5, localReadDate: .now, pageHref: "", mediaType: "", isPending: true,
                pagesCount: 5, downloadState: .downloaded, downloadedBytes: store.diskUsage(forBook: "b1"),
                downloadedDate: .now
            )
            context.insert(book)
            try context.save()

            let transport = StubTransport()
            let coordinator = makeCoordinator(context: context, service: service, transport: transport, store: store)

            coordinator.reapAutoRemovable()

            #expect(fetchBook(context, id: "b1")?.downloadState == .downloaded)
            #expect(store.isDownloaded("b1"))
        }

        // MARK: - Fixtures

        private static func manifest(pageCount: Int) -> KomgaDivinaManifest {
            KomgaDivinaManifest(
                metadata: .init(title: "Book", numberOfPages: pageCount),
                readingOrder: (0 ..< pageCount).map {
                    KomgaPageLink(href: "/pages/\($0 + 1)", type: "image/jpeg", width: 800, height: 1200)
                }
            )
        }

        private static func komgaBook(id: String, pages: Int, status: String = "READY") -> KomgaBook {
            KomgaBook(
                id: id,
                seriesId: "s1",
                seriesTitle: "Series",
                name: "Book \(id)",
                sizeBytes: 100,
                media: KomgaMedia(status: status, pagesCount: pages),
                metadata: KomgaBookMetadata(title: "Book \(id)")
            )
        }

        /// One byte per page (`[0x00]`, `[0x01]`, …) so a test can tell pages
        /// apart without needing real image bytes.
        private static func zip(pageCount: Int) -> Data {
            ZipFixtureBuilder.make(entries: (0 ..< pageCount).map {
                .init(name: String(format: "%04d.jpg", $0 + 1), data: Data([UInt8($0)]))
            })
        }

        /// `Stub.status(_:body:)` only takes a `String` body — not enough for a
        /// binary ZIP — so this goes through `Stub`'s memberwise init directly.
        private static func zipStub(pageCount: Int) -> Stub {
            Stub(status: 200, body: zip(pageCount: pageCount), headers: [:], error: nil)
        }
    }
}

/// Covers just what `DownloadCoordinator` calls — everything else fatalErrors
/// so an accidental new dependency fails loudly. `@unchecked Sendable` for
/// the same reason as `ProgressionSyncEngineTests`'s mock: single `@MainActor`
/// driver, no real concurrency to guard against.
private final class FakeDownloadService: KomgaServing, @unchecked Sendable {
    var manifests: [String: KomgaDivinaManifest] = [:]
    var seriesBooks: [KomgaBook] = []
    var pageBytes: [String: Data] = [:]
    private(set) var pageRequests: [String] = []

    func checkReachable() async throws {
        fatalError("unused")
    }

    func currentUser() async throws -> KomgaUser {
        fatalError("unused")
    }

    func createAPIKey(comment _: String) async throws -> KomgaAPIKey {
        fatalError("unused")
    }

    func deleteAPIKey(id _: String) async throws {
        fatalError("unused")
    }

    func libraries() async throws -> [KomgaLibrary] {
        fatalError("unused")
    }

    func series(matching _: SeriesQuery) async throws -> KomgaPage<KomgaSeries> {
        fatalError("unused")
    }

    func series(id _: String) async throws -> KomgaSeries {
        fatalError("unused")
    }

    func books(inSeries _: String, matching _: BookQuery) async throws -> KomgaPage<KomgaBook> {
        KomgaPage(
            content: seriesBooks,
            totalElements: seriesBooks.count,
            totalPages: 1,
            number: 0,
            size: 500,
            first: true,
            last: true
        )
    }

    func book(id _: String) async throws -> KomgaBook {
        fatalError("unused")
    }

    func keepReading(matching _: BookQuery) async throws -> KomgaPage<KomgaBook> {
        fatalError("unused")
    }

    func onDeck(matching _: BookQuery) async throws -> KomgaPage<KomgaBook> {
        fatalError("unused")
    }

    func thumbnailData(for _: KomgaThumbnail) async throws -> Data? {
        fatalError("unused")
    }

    func divinaManifest(forBook bookID: String) async throws -> KomgaDivinaManifest {
        guard let manifest = manifests[bookID] else { throw KomgaError.notFound }
        return manifest
    }

    func pageImageData(at href: String) async throws -> Data {
        pageRequests.append(href)
        guard let data = pageBytes[href] else { throw KomgaError.notFound }
        return data
    }

    func putProgression(bookID _: String, write _: ProgressionWrite, device _: KomgaDevice) async throws {
        fatalError("unused")
    }

    func fileData(forBook _: String) async throws -> Data {
        fatalError("unused")
    }

    func fileDownloadRequest(forBook bookID: String) -> URLRequest {
        URLRequest(url: URL(string: "https://komga.test/opds/v2/books/\(bookID)/file")!)
    }
}
