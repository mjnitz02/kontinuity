//
//  LiveKomgaTests.swift
//  KontinuityTests
//
//  Opt-in tests against a real Komga instance (see `make komga-up`). They skip
//  themselves unless the environment is configured, so `make test-unit` — the CI
//  gate — stays hermetic and Docker-free. Run them with `make test-integration`.
//
//  These exist because stubs can only assert what we already believe about the
//  wire format. Hand-written JSON in the stubbed suite is a restatement of our
//  assumptions; these tests decode what Komga actually sends.
//

import Foundation
import Testing
@testable import KontinuityCore

/// Injected by `make test-integration` through `TEST_RUNNER_*` build settings,
/// which Xcode strips the prefix from before handing to the test process.
enum LiveKomga {
    static var url: String? {
        value("KOMGA_URL")
    }

    static var apiKey: String? {
        value("KOMGA_API_KEY")
    }

    static var email: String? {
        value("KOMGA_EMAIL")
    }

    static var password: String? {
        value("KOMGA_PASSWORD")
    }

    static var isConfigured: Bool {
        url != nil && apiKey != nil
    }

    static var canBootstrap: Bool {
        isConfigured && email != nil && password != nil
    }

    static func address() throws -> ServerAddress {
        try ServerAddress(normalizing: url ?? "")
    }

    private static func value(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return raw
    }
}

@Suite("Live Komga", .enabled(if: LiveKomga.isConfigured))
struct LiveKomgaTests {
    private func client(_ credential: KomgaCredential) throws -> KomgaClient {
        try KomgaClient(address: LiveKomga.address(), credential: credential)
    }

    @Test("reaches the unauthenticated health endpoint")
    func health() async throws {
        // Also proves Info.plist's NSAllowsLocalNetworking is doing its job:
        // without it, plain HTTP to localhost would be blocked by ATS.
        try await client(.apiKey("")).checkReachable()
    }

    @Test("decodes the real current-user payload")
    func currentUser() async throws {
        let key = try #require(LiveKomga.apiKey)
        let user = try await client(.apiKey(key)).currentUser()

        #expect(!user.id.isEmpty)
        if let email = LiveKomga.email {
            #expect(user.email == email)
        }
        // Roles the reader and downloader depend on. Komga's real payload also
        // carries KOBO_SYNC / KOREADER_SYNC, which must not trip up decoding.
        #expect(user.canStreamPages)
    }

    @Test("rejects a bogus API key")
    func bogusKey() async throws {
        await #expect(throws: KomgaError.unauthorized) {
            try await client(.apiKey("definitely-not-a-real-key")).currentUser()
        }
    }

    @Test("bootstraps and revokes a real API key", .enabled(if: LiveKomga.canBootstrap))
    func bootstrapRoundTrip() async throws {
        let email = try #require(LiveKomga.email)
        let password = try #require(LiveKomga.password)
        // Unique per run so a leaked key from an interrupted run can't collide.
        let deviceName = "IntegrationTest-\(UUID().uuidString.prefix(8))"

        let connection = try await ServerConnector().connect(
            to: #require(LiveKomga.url),
            using: .credentials(email: email, password: password),
            deviceName: deviceName
        )

        #expect(!connection.apiKey.isEmpty)
        #expect(connection.user.email == email)

        let keyID = try #require(connection.apiKeyID, "we minted it, so the id must come back")

        // Clean up before asserting anything else, so a later failure can't
        // leave a key behind on the server.
        try await client(.apiKey(connection.apiKey)).deleteAPIKey(id: keyID)

        // The minted key worked for the verification call inside connect(), and
        // is now revoked.
        await #expect(throws: KomgaError.unauthorized) {
            try await client(.apiKey(connection.apiKey)).currentUser()
        }
    }

    @Test(
        "decodes Komga's nanosecond timestamps as the right instant",
        .enabled(if: LiveKomga.canBootstrap)
    )
    func decodesRealTimestamps() async throws {
        let email = try #require(LiveKomga.email)
        let password = try #require(LiveKomga.password)
        let bootstrap = try client(.basic(email: email, password: password))

        let before = Date()
        let key = try await bootstrap.createAPIKey(comment: "Kontinuity date probe \(UUID().uuidString.prefix(8))")
        let after = Date()
        try await client(.apiKey(key.key)).deleteAPIKey(id: key.id)

        // Komga sends nine fractional digits (2026-08-02T10:42:11.858195884Z).
        // Foundation handles that today; this pins it against a future Komga
        // changing format, which would otherwise surface as a decoding failure
        // deep inside a sync flush rather than here.
        #expect(key.createdDate >= before.addingTimeInterval(-120))
        #expect(key.createdDate <= after.addingTimeInterval(120))
    }

    // MARK: - Browse

    /// Every browse assertion needs a series to hang off, and the container's
    /// contents depend on whatever was scanned into it. Tests that need one skip
    /// rather than fail on an empty library.
    private func anySeries() async throws -> KomgaSeries? {
        let key = try #require(LiveKomga.apiKey)
        let page = try await client(.apiKey(key)).series(matching: SeriesQuery(size: 1))
        return page.content.first
    }

    @Test("decodes the real libraries payload")
    func liveLibraries() async throws {
        let key = try #require(LiveKomga.apiKey)
        let libraries = try await client(.apiKey(key)).libraries()

        // ~30 fields of scanner configuration we deliberately don't decode; this
        // proves ignoring them is actually free rather than a decoding failure.
        for library in libraries {
            #expect(!library.id.isEmpty)
            #expect(!library.name.isEmpty)
        }
    }

    @Test("decodes a real series page, envelope included")
    func liveSeriesPage() async throws {
        let key = try #require(LiveKomga.apiKey)
        let page = try await client(.apiKey(key)).series(matching: SeriesQuery(size: 5))

        #expect(page.number == 0)
        #expect(page.size == 5)
        #expect(page.content.count <= 5)
        #expect(page.totalElements >= page.content.count)

        for series in page.content {
            #expect(!series.displayTitle.isEmpty)
            // The three counts are what the unread badge and the phase-5
            // download gesture both read.
            #expect(series.booksReadCount + series.booksUnreadCount + series.booksInProgressCount == series.booksCount)
        }
    }

    @Test("decodes a real book list with inline read progress")
    func liveBooks() async throws {
        guard let series = try await anySeries() else { return }
        let key = try #require(LiveKomga.apiKey)
        let page = try await client(.apiKey(key)).books(inSeries: series.id, matching: BookQuery(size: 10))

        // This inline `readProgress` is the entire reason browse goes through
        // /api/v1 rather than OPDS v2 (KOMGA-API §3). If it ever stops arriving,
        // the architecture's premise is gone and this is where we find out.
        for book in page.content {
            #expect(book.seriesId == series.id)
            #expect(book.media.pagesCount > 0 || book.media.status != "READY")
            if let progress = book.readProgress {
                #expect(progress.page >= 1)
            }
        }

        // Sorted ascending by numberSort — the reading order.
        let sorted = page.content.map(\.metadata.numberSort)
        #expect(sorted == sorted.sorted())
    }

    @Test("fetches a real series poster")
    func liveThumbnail() async throws {
        guard let series = try await anySeries() else { return }
        let key = try #require(LiveKomga.apiKey)
        let data = try await client(.apiKey(key)).thumbnailData(for: .series(series.id))

        let bytes = try #require(data, "a scanned series should have a generated poster")
        #expect(bytes.count > 1000)
        // JPEG SOI marker — proves we got image bytes rather than an error page
        // a reverse proxy answered with a 200.
        #expect(bytes.prefix(2) == Data([0xFF, 0xD8]))
    }

    // MARK: - Reader

    /// Every reader assertion needs a readable book to open. Scans series
    /// until one turns up rather than assuming the first series has one —
    /// never a hardcoded real title, since the container's contents depend on
    /// whatever was scanned into it.
    private func anyReadableBook() async throws -> KomgaBook? {
        let key = try #require(LiveKomga.apiKey)
        let client = try client(.apiKey(key))
        let seriesPage = try await client.series(matching: SeriesQuery(size: 20))
        for series in seriesPage.content {
            let books = try await client.books(inSeries: series.id, matching: BookQuery(size: 20))
            if let readable = books.content.first(where: \.isReadable) {
                return readable
            }
        }
        return nil
    }

    @Test("reads a real DIVINA manifest, fetches a page, and writes progression")
    func readerRoundTrip() async throws {
        guard let book = try await anyReadableBook() else { return }
        let key = try #require(LiveKomga.apiKey)
        let live = try client(.apiKey(key))

        let manifest = try await live.divinaManifest(forBook: book.id)
        #expect(!manifest.readingOrder.isEmpty)
        let firstPage = try #require(manifest.readingOrder.first)
        // Width/height come from Komga's own analysis — this is the whole
        // premise the layout engine is built on (KOMGA-API §2).
        #expect((firstPage.width ?? 0) > 0)
        #expect((firstPage.height ?? 0) > 0)

        let pageData = try await live.pageImageData(at: firstPage.href)
        #expect(pageData.count > 1000)
        #expect(pageData.prefix(2) == Data([0xFF, 0xD8]))

        try await live.putProgression(
            bookID: book.id,
            write: ProgressionWrite(page: 1, pageHref: firstPage.href, mediaType: firstPage.type, readDate: .now),
            device: KomgaDevice(id: UUID(), name: "Kontinuity integration test")
        )
        let refetched = try await live.book(id: book.id)
        #expect(refetched.readProgress?.page == 1)
    }

    @Test("a PUT with an older `modified` than what's stored gets a real 409")
    func progressionConflictIsReal() async throws {
        guard let book = try await anyReadableBook() else { return }
        let key = try #require(LiveKomga.apiKey)
        let live = try client(.apiKey(key))
        let manifest = try await live.divinaManifest(forBook: book.id)
        let firstPage = try #require(manifest.readingOrder.first)

        let device = KomgaDevice(id: UUID(), name: "Kontinuity conflict test")

        // Establish a baseline "now" write, then try to write an older one —
        // the exact shape PLAN §5's outbox must never retry (KOMGA-API §4).
        try await live.putProgression(
            bookID: book.id,
            write: ProgressionWrite(page: 1, pageHref: firstPage.href, mediaType: firstPage.type, readDate: .now),
            device: device
        )

        await #expect(throws: KomgaError.conflict) {
            try await live.putProgression(
                bookID: book.id,
                write: ProgressionWrite(
                    page: 2, pageHref: firstPage.href, mediaType: firstPage.type,
                    readDate: Date().addingTimeInterval(-3600)
                ),
                device: device
            )
        }

        // And the rejected write must not have landed — the stored position
        // is still the baseline, proving there's nothing to "retry" toward.
        let refetched = try await live.book(id: book.id)
        #expect(refetched.readProgress?.page == 1)
    }

    // MARK: - Download

    /// The empirical check behind `CBZArchive`'s natural-sort assumption
    /// (KOMGA-API has nothing documenting archive-entry order): a real CBZ's
    /// filenames, once junk is filtered and sorted numerically, should
    /// decompress to exactly as many pages as Komga's own manifest reports.
    @Test("a downloaded CBZ decompresses to the same page count as the manifest")
    func downloadedPageCountMatchesManifest() async throws {
        guard let book = try await anyReadableBook() else { return }
        let key = try #require(LiveKomga.apiKey)
        let live = try client(.apiKey(key))

        let manifest = try await live.divinaManifest(forBook: book.id)
        guard !manifest.readingOrder.isEmpty else { return }

        let fileData: Data
        do {
            fileData = try await live.fileData(forBook: book.id)
        } catch KomgaError.forbidden {
            // This account lacks FILE_DOWNLOAD — exactly the case the
            // download engine's per-page fallback exists for, not this test.
            return
        }

        #expect(fileData.count > 1000)
        let pages = try CBZArchive.extractImagePages(from: fileData)
        #expect(pages.count == manifest.readingOrder.count)
    }

    @Test("the on-deck and keep-reading feeds decode")
    func liveFeeds() async throws {
        let key = try #require(LiveKomga.apiKey)
        let live = try client(.apiKey(key))

        // Both are usually empty on a fresh container. What's under test is that
        // the request shape is accepted — on deck in particular 400s if a sort
        // is sent, which a stub can't catch.
        _ = try await live.onDeck(matching: BookQuery(size: 5))
        _ = try await live.keepReading(matching: BookQuery(size: 5))
    }
}
