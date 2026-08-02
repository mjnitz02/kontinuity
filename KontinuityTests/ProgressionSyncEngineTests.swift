//
//  ProgressionSyncEngineTests.swift
//  KontinuityTests
//
//  The impure half of phase 4: does `flush()` actually persist what the pure
//  `ProgressionSync` policy says it should, against a mocked `KomgaServing`
//  and an in-memory `Book` store. `KontinuityTests` is hosted inside the
//  `Kontinuity` app target (TEST_HOST in project.pbxproj), so it can reach
//  app-target types the same way it reaches KontinuityCore's.
//

import Foundation
import SwiftData
import Testing
@testable import Kontinuity
@testable import KontinuityCore

/// Serialized, and sharing one `ModelContainer` across all tests rather than
/// one per test: creating many independent in-memory containers in quick
/// succession has been observed to trap inside SwiftData's own internals on
/// this toolchain — a test-harness artifact (a real app session only ever
/// builds one container), not a concurrency bug in the engine itself. Each
/// test still gets a clean slate via an explicit wipe in `makeContext()`.
@MainActor
@Suite("ProgressionSyncEngine", .serialized)
struct ProgressionSyncEngineTests {
    private let device = KomgaDevice(id: UUID(), name: "Test iPad")

    private static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Book.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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

    @Test("a successful flush marks the row synced with the turn's own timestamp")
    func flushSuccess() async throws {
        let context = try makeContext()
        let service = MockKomgaServing()
        let engine = ProgressionSyncEngine(service: service, modelContext: context, device: device)

        let turnDate = Date(timeIntervalSince1970: 1000)
        engine.recordPageTurn(bookID: "b1", page: 5, pageHref: "/pages/5", mediaType: "image/jpeg", at: turnDate)
        await engine.flush()

        #expect(service.putCalls.count == 1)
        #expect(service.putCalls.first?.readDate == turnDate)

        let row = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(row.isPending == false)
        #expect(row.serverPage == 5)
        #expect(row.serverReadDate == turnDate)
    }

    @Test("a newer page turn coalesces the pending write rather than queueing behind it")
    func recordPageTurnCoalesces() async throws {
        let context = try makeContext()
        let service = MockKomgaServing()
        let engine = ProgressionSyncEngine(service: service, modelContext: context, device: device)

        engine.recordPageTurn(bookID: "b1", page: 5, pageHref: "/pages/5", mediaType: "image/jpeg")
        engine.recordPageTurn(bookID: "b1", page: 6, pageHref: "/pages/6", mediaType: "image/jpeg")
        await engine.flush()

        #expect(service.putCalls.count == 1)
        #expect(service.putCalls.first?.page == 6)
        #expect(try context.fetch(FetchDescriptor<Book>()).count == 1)
    }

    @Test("a 409 never retries — it clears pending and adopts whatever the server actually has")
    func flushConflictAdoptsServer() async throws {
        let context = try makeContext()
        let serverDate = Date(timeIntervalSince1970: 2000)
        let service = MockKomgaServing()
        service.putResult = .failure(KomgaError.conflict)
        service.bookResult = .success(Self.book(page: 9, readDate: serverDate))
        let engine = ProgressionSyncEngine(service: service, modelContext: context, device: device)

        engine.recordPageTurn(bookID: "b1", page: 5, pageHref: "/pages/5", mediaType: "image/jpeg")
        await engine.flush()

        let row = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(row.isPending == false)
        #expect(row.localPage == 9)
        #expect(row.serverPage == 9)
        #expect(row.serverReadDate == serverDate)
    }

    @Test("offline leaves every write pending and stops the rest of the queue, not just the first")
    func flushOfflineLeavesPending() async throws {
        let context = try makeContext()
        let service = MockKomgaServing()
        service.putResult = .failure(KomgaError.transport(code: .notConnectedToInternet, description: "offline"))
        let engine = ProgressionSyncEngine(service: service, modelContext: context, device: device)

        engine.recordPageTurn(bookID: "b1", page: 5, pageHref: "/pages/5", mediaType: "image/jpeg")
        engine.recordPageTurn(bookID: "b2", page: 8, pageHref: "/pages/8", mediaType: "image/jpeg")
        await engine.flush()

        let rows = try context.fetch(FetchDescriptor<Book>())
        // Not `\.isPending` here: a bare key path passed to `allSatisfy` inside
        // `#expect`'s macro expansion fails to type-check as `rethrows`.
        // swiftformat:disable:next preferKeyPath
        #expect(rows.allSatisfy { $0.isPending })
        #expect(service.putCalls.count == 1, "the rest of the queue will fail the same way, so it isn't worth trying")
    }

    @Test("a book with no local row is untouched by reconciliation")
    func reconcileWithoutLocalRowIsNoop() throws {
        let context = try makeContext()
        let engine = ProgressionSyncEngine(service: MockKomgaServing(), modelContext: context, device: device)

        engine.reconcile(with: Self.book(page: 12, readDate: .now))

        #expect(try context.fetch(FetchDescriptor<Book>()).isEmpty)
    }

    @Test("both sides moved — the further page wins and a conflict notice is published")
    func reconcileBothMovedPublishesNotice() async throws {
        let context = try makeContext()
        let service = MockKomgaServing()
        let engine = ProgressionSyncEngine(service: service, modelContext: context, device: device)

        // Establish a synced baseline, then a local write the server never saw.
        engine.recordPageTurn(bookID: "b1", page: 10, pageHref: "/pages/10", mediaType: "image/jpeg")
        await engine.flush()
        engine.recordPageTurn(bookID: "b1", page: 15, pageHref: "/pages/15", mediaType: "image/jpeg")

        // Meanwhile the server moved further still, from a different device.
        engine.reconcile(with: Self.book(page: 20, readDate: Date(timeIntervalSince1970: 5000)))

        let row = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(row.localPage == 20)
        #expect(row.isPending == false)

        let notice = try #require(engine.conflictNotice)
        #expect(notice.resolvedPage == 20)
        #expect(notice.resolvedToLocal == false)
    }

    private static func book(page: Int, readDate: Date) -> KomgaBook {
        KomgaBook(
            id: "b1",
            seriesId: "s1",
            name: "Book",
            media: KomgaMedia(pagesCount: 40),
            metadata: KomgaBookMetadata(title: "Book"),
            readProgress: KomgaReadProgress(page: page, completed: false, readDate: readDate)
        )
    }
}

/// A `KomgaServing` double covering just what `ProgressionSyncEngine` calls —
/// everything else fatalErrors so an accidental new dependency fails loudly
/// rather than silently returning empty data. `@unchecked Sendable` because
/// the protocol requires it and every test drives this from a single
/// `@MainActor` context; there is no real concurrency to guard against here.
private struct PutCall: Equatable {
    let bookID: String
    let page: Int
    let readDate: Date
}

private final class MockKomgaServing: KomgaServing, @unchecked Sendable {
    private(set) var putCalls: [PutCall] = []
    var putResult: Result<Void, Error> = .success(())
    var bookResult: Result<KomgaBook, Error> = .failure(KomgaError.notFound)

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

    func divinaManifest(forBook _: String) async throws -> KomgaDivinaManifest {
        fatalError("unused")
    }

    func pageImageData(at _: String) async throws -> Data {
        fatalError("unused")
    }

    func book(id _: String) async throws -> KomgaBook {
        try bookResult.get()
    }

    func putProgression(bookID: String, write: ProgressionWrite, device _: KomgaDevice) async throws {
        putCalls.append(PutCall(bookID: bookID, page: write.page, readDate: write.readDate))
        try putResult.get()
    }

    func fileData(forBook _: String) async throws -> Data {
        fatalError("unused")
    }

    func fileDownloadRequest(forBook _: String) -> URLRequest {
        fatalError("unused")
    }
}
