//
//  ReaderModelTests.swift
//  KontinuityTests
//
//  Mode B and Mode A's continuous surface both have no page turn to hang
//  progression off of (PLAN 6B §C gap 1, READER-DESIGN §5, PLAN §12):
//  `recordPageRead` shares `recordProgress`/`lastSentPage` with the paged
//  `sendProgress`, so re-entering a page or stepping backward must cost
//  nothing extra — the same guarantee `ProgressionSyncEngineTests`'s
//  "coalesces" test proves for Mode A's own page turns.
//

import Foundation
import SwiftData
import Testing
@testable import Kontinuity
@testable import KontinuityCore

/// Nested under `SwiftDataTests` for the same reason `ProgressionSyncEngineTests`
/// and `DownloadCoordinatorTests` are — one shared in-memory container per
/// suite rather than one per test.
extension SwiftDataTests {
    @MainActor
    @Suite("ReaderModel", .serialized)
    struct ReaderModelTests {
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

        @Test("recordPageRead sends once per distinct page — re-entering the same page is a no-op")
        func recordPageReadDedupes() async throws {
            let context = try makeContext()
            let device = KomgaDevice(id: UUID(), name: "Test iPad")
            let service = RecordingKomgaService()
            let sync = ProgressionSyncEngine(service: service, modelContext: context, device: device)
            let downloads = DownloadCoordinator(
                service: service,
                modelContext: context,
                settings: DownloadSettings(),
                sessionConfiguration: .ephemeral
            )
            let model = ReaderModel(book: Self.book(), service: service, sync: sync, downloads: downloads)
            await model.load()

            model.recordPageRead(pageIndex: 2) // last band of page 3
            await sync.flush()
            model.recordPageRead(pageIndex: 2) // re-entering page 3's last band: a true no-op
            await sync.flush()
            model.recordPageRead(pageIndex: 4) // stepping on to page 5
            await sync.flush()

            #expect(service.putCalls.map(\.page) == [3, 5])
        }

        @Test("setFlow updates the model and persists the per-series override, mirroring GlassesCoordinator.setFlow")
        func setFlowPersistsOverride() async throws {
            let context = try makeContext()
            let device = KomgaDevice(id: UUID(), name: "Test iPad")
            let service = RecordingKomgaService()
            let sync = ProgressionSyncEngine(service: service, modelContext: context, device: device)
            let downloads = DownloadCoordinator(
                service: service,
                modelContext: context,
                settings: DownloadSettings(),
                sessionConfiguration: .ephemeral
            )
            let settings = try GlassesSettings(defaults: #require(UserDefaults(suiteName: "ReaderModelTests.setFlow.\(UUID())")))
            let book = Self.book()
            let model = ReaderModel(
                book: book,
                service: service,
                sync: sync,
                downloads: downloads,
                glassesSettings: settings
            )
            await model.load()
            #expect(model.flow == .perPage)

            model.setFlow(.continuous)

            #expect(model.flow == .continuous)
            #expect(settings.flowOverride(forSeries: book.seriesId) == .continuous)
        }

        private static func book(pages: Int = 6) -> KomgaBook {
            KomgaBook(
                id: "b1",
                seriesId: "s1",
                name: "Book",
                media: KomgaMedia(pagesCount: pages),
                metadata: KomgaBookMetadata(title: "Book")
            )
        }
    }
}

/// A `KomgaServing` double covering what `ReaderModel.load()` and
/// `ProgressionSyncEngine.flush()` call — everything else fatalErrors so an
/// accidental new dependency fails loudly. Same shape as
/// `ProgressionSyncEngineTests`'s private `MockKomgaServing`, duplicated
/// rather than shared because that one is file-private.
private final class RecordingKomgaService: KomgaServing, @unchecked Sendable {
    private(set) var putCalls: [(bookID: String, page: Int)] = []

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

    func pageImageData(at _: String) async throws -> Data {
        fatalError("unused")
    }

    func book(id _: String) async throws -> KomgaBook {
        fatalError("unused")
    }

    func fileData(forBook _: String) async throws -> Data {
        fatalError("unused")
    }

    func fileDownloadRequest(forBook _: String) -> URLRequest {
        fatalError("unused")
    }

    func divinaManifest(forBook bookID: String) async throws -> KomgaDivinaManifest {
        let readingOrder = (0 ..< 6).map { index in
            KomgaPageLink(
                href: "/opds/v2/books/\(bookID)/pages/\(index + 1)?contentNegotiation=false",
                type: "image/jpeg",
                width: 800,
                height: 1200
            )
        }
        return KomgaDivinaManifest(metadata: .init(title: "Book", numberOfPages: 6), readingOrder: readingOrder)
    }

    func putProgression(bookID: String, write: ProgressionWrite, device _: KomgaDevice) async throws {
        putCalls.append((bookID: bookID, page: write.page))
    }

    func markRead(bookID _: String) async throws {
        fatalError("unused")
    }

    func markUnread(bookID _: String) async throws {
        fatalError("unused")
    }
}
