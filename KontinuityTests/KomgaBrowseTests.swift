//
//  KomgaBrowseTests.swift
//  KontinuityTests
//
//  Decoding and query construction for the browse surface. The JSON here is
//  trimmed from real Komga 1.25.0 responses rather than hand-written, because
//  the failures worth catching are the ones where our idea of the shape and
//  Komga's have quietly diverged.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("Komga browse")
struct KomgaBrowseTests {
    // MARK: - Fixtures

    /// `GET /api/v1/libraries`, cut down from the ~30 scanner-config fields.
    static let librariesJSON = """
    [ { "id": "0R679Z2BQ3HFP", "name": "Data", "root": "/data",
        "scanInterval": "EVERY_6H", "seriesCover": "FIRST",
        "oneshotsDirectory": null, "unavailable": false } ]
    """

    /// One page of `GET /api/v1/series`, with the metadata trimmed but the
    /// envelope kept intact — the envelope is what pagination depends on.
    static let seriesPageJSON = """
    { "content": [
        { "id": "0R67AVDDK3H37", "libraryId": "0R679Z2BQ3HFP", "name": "data",
          "url": "/data", "created": "2026-08-02T10:43:29Z",
          "lastModified": "2026-08-02T10:43:29Z",
          "fileLastModified": "2026-08-02T05:37:36Z",
          "booksCount": 12, "booksReadCount": 3, "booksUnreadCount": 8,
          "booksInProgressCount": 1,
          "metadata": { "status": "ONGOING", "statusLock": false,
            "title": "Air Gear", "titleLock": false, "titleSort": "Air Gear",
            "summary": "", "readingDirection": "", "publisher": "",
            "ageRating": 13, "language": "en",
            "genres": ["shounen", "action"], "tags": [],
            "totalBookCount": 358, "sharingLabels": [], "links": [],
            "alternateTitles": [], "created": "2026-08-02T10:43:29Z",
            "lastModified": "2026-08-02T10:43:29Z" },
          "booksMetadata": { "authors": [ { "name": "Oh!great", "role": "writer" } ],
            "tags": [], "releaseDate": "2018-01-18", "summary": "A summary.",
            "summaryNumber": "1", "created": "2026-08-02T10:43:29Z",
            "lastModified": "2026-08-02T10:43:29Z" },
          "deleted": false, "oneshot": false } ],
      "pageable": { "pageNumber": 0, "pageSize": 20, "offset": 0,
                    "paged": true, "unpaged": false },
      "totalElements": 41, "totalPages": 3, "last": false, "size": 20,
      "number": 0, "numberOfElements": 20, "first": true, "empty": false }
    """

    /// A book with no read progress — Komga sends an explicit `null`.
    static let unreadBookJSON = """
    { "id": "0R67AVDDQ3H1D", "seriesId": "0R67AVDDK3H37",
      "seriesTitle": "Air Gear", "libraryId": "0R679Z2BQ3HFP",
      "name": "Air Gear - Chapter 001", "url": "/data/ch1.cbz", "number": 1,
      "created": "2026-08-02T10:43:29Z", "lastModified": "2026-08-02T10:43:29Z",
      "fileLastModified": "2026-08-02T10:42:24Z",
      "sizeBytes": 32054882, "size": "30.6 MiB",
      "media": { "status": "READY", "mediaType": "application/zip",
                 "pagesCount": 67, "comment": "",
                 "epubDivinaCompatible": false, "epubIsKepub": false,
                 "mediaProfile": "DIVINA" },
      "metadata": { "title": "Air Gear - Chapter 001", "summary": "",
                    "number": "1", "numberSort": 1.0,
                    "releaseDate": "2018-01-18",
                    "authors": [ { "name": "Oh!great", "role": "writer" } ],
                    "tags": [], "isbn": "", "links": [],
                    "created": "2026-08-02T10:43:29Z",
                    "lastModified": "2026-08-02T10:43:29Z" },
      "readProgress": null, "deleted": false,
      "fileHash": "dcba45d1", "oneshot": false }
    """

    private static func bookJSON(progress: String) -> String {
        unreadBookJSON.replacingOccurrences(of: "\"readProgress\": null", with: "\"readProgress\": \(progress)")
    }

    /// An empty page envelope, for the request tests — they assert on the URL
    /// that went out, so the body only has to decode.
    static func emptyPageJSON(size: Int) -> String {
        """
        { "content": [], "totalElements": 0, "totalPages": 0,
          "number": 0, "size": \(size), "first": true, "last": true }
        """
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try KomgaClient.decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Decoding

    @Test("decodes a library, ignoring the scanner configuration")
    func decodesLibraries() throws {
        let libraries = try decode([KomgaLibrary].self, Self.librariesJSON)

        #expect(libraries.count == 1)
        #expect(libraries.first?.name == "Data")
        #expect(libraries.first?.unavailable == false)
    }

    @Test("decodes a series page and its read counts")
    func decodesSeriesPage() throws {
        let page = try decode(KomgaPage<KomgaSeries>.self, Self.seriesPageJSON)

        #expect(page.totalElements == 41)
        #expect(page.number == 0)

        let series = try #require(page.content.first)
        #expect(series.displayTitle == "Air Gear")
        #expect(series.booksUnreadCount == 8)
        #expect(series.metadata.totalBookCount == 358)
        #expect(series.metadata.genres.contains("shounen"))
        #expect(series.booksMetadata.authors.first?.name == "Oh!great")
        #expect(!series.isFullyRead)
    }

    @Test("falls back to the folder name when a series has no metadata title")
    func fallsBackToFolderName() throws {
        let json = Self.seriesPageJSON.replacingOccurrences(of: "\"title\": \"Air Gear\"", with: "\"title\": \"\"")
        let page = try decode(KomgaPage<KomgaSeries>.self, json)

        #expect(page.content.first?.displayTitle == "data")
    }

    @Test("treats an unset reading direction as absent, not as LTR")
    func readingDirectionEmptyString() throws {
        let page = try decode(KomgaPage<KomgaSeries>.self, Self.seriesPageJSON)

        // Komga's REST DTO types this non-null and sends "" when unset, unlike
        // the OPDS manifest where the key is omitted (KOMGA-API §2). Both mean
        // "the user never set one", and neither means left-to-right.
        #expect(page.content.first?.metadata.direction == nil)
    }

    @Test("decodes a reading direction when the series has one")
    func readingDirectionSet() throws {
        let json = Self.seriesPageJSON.replacingOccurrences(
            of: "\"readingDirection\": \"\"",
            with: "\"readingDirection\": \"RIGHT_TO_LEFT\""
        )
        let page = try decode(KomgaPage<KomgaSeries>.self, json)

        #expect(page.content.first?.metadata.direction == .rightToLeft)
    }

    @Test("decodes a release date without shifting it across a timezone")
    func decodesLocalDate() throws {
        let book = try decode(KomgaBook.self, Self.unreadBookJSON)
        let released = try #require(book.metadata.releaseDate)

        // Komga sends `LocalDate` as yyyy-MM-dd. Routing that through the
        // timestamp decoder is how a release date lands a day early west of
        // UTC, so it decodes to calendar components and stays whole.
        #expect(released.year == 2018)
        #expect(released.month == 1)
        #expect(released.day == 18)
    }

    // MARK: - Read state

    @Test("a book with no progress reads as unread")
    func unreadState() throws {
        let book = try decode(KomgaBook.self, Self.unreadBookJSON)

        #expect(book.readState == .unread)
        #expect(book.readState.fraction == nil)
        #expect(book.isReadable)
    }

    @Test("a partially read book reports its page and fraction")
    func inProgressState() throws {
        let json = Self.bookJSON(progress: """
        { "page": 20, "completed": false, "readDate": "2026-08-02T11:00:00Z",
          "created": "2026-08-02T11:00:00Z", "lastModified": "2026-08-02T11:00:00Z",
          "deviceId": "device-1", "deviceName": "Matt's iPad" }
        """)
        let book = try decode(KomgaBook.self, json)

        #expect(book.readState == .inProgress(page: 20, of: 67))
        let fraction = try #require(book.readState.fraction)
        #expect(abs(fraction - 20.0 / 67.0) < 0.0001)
        #expect(book.readProgress?.deviceName == "Matt's iPad")
    }

    @Test("a completed book reads as read regardless of its page number")
    func readState() throws {
        // Komga computes `completed` as position == pageCount, but the flag is
        // what it sends; trusting the flag keeps us aligned with the server's
        // own definition rather than re-deriving it (KOMGA-API §4).
        let json = Self.bookJSON(progress: """
        { "page": 67, "completed": true, "readDate": "2026-08-02T11:00:00Z",
          "created": "2026-08-02T11:00:00Z", "lastModified": "2026-08-02T11:00:00Z",
          "deviceId": "device-1", "deviceName": "Matt's iPad" }
        """)
        let book = try decode(KomgaBook.self, json)

        #expect(book.readState == .read)
    }

    @Test(
        "an unanalysed or non-DIVINA book is not offered as readable",
        arguments: [
            ("\"status\": \"UNKNOWN\"", "\"status\": \"READY\""),
            ("\"pagesCount\": 0", "\"pagesCount\": 67"),
            ("\"mediaProfile\": \"EPUB\"", "\"mediaProfile\": \"DIVINA\"")
        ]
    )
    func notReadable(replacement: String, original: String) throws {
        let json = Self.unreadBookJSON.replacingOccurrences(of: original, with: replacement)
        let book = try decode(KomgaBook.self, json)

        #expect(!book.isReadable)
    }

    // MARK: - Pagination

    @Test("nextPage advances until the server says it's the last page")
    func pagination() throws {
        let page = try decode(KomgaPage<KomgaSeries>.self, Self.seriesPageJSON)
        #expect(page.nextPage == 1)

        let lastJSON = Self.seriesPageJSON.replacingOccurrences(of: "\"last\": false", with: "\"last\": true")
        let lastPage = try decode(KomgaPage<KomgaSeries>.self, lastJSON)
        #expect(lastPage.nextPage == nil)
    }

    // MARK: - Requests

    private func makeClient(_ stubs: [Stub]) throws -> (KomgaClient, StubTransport) {
        let transport = StubTransport(stubs)
        let client = try KomgaClient(
            address: ServerAddress(normalizing: "http://nas.local:25600"),
            credential: .apiKey("secret-key"),
            session: transport.session
        )
        return (client, transport)
    }

    /// Query items as a dictionary of all values per key, so assertions don't
    /// depend on parameter order.
    private func queryValues(_ request: RecordedRequest) -> [String: [String]] {
        guard let url = request.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            return [:]
        }
        return Dictionary(grouping: items, by: \.name).mapValues { $0.compactMap(\.value) }
    }

    @Test("the series query sends library, paging and sort")
    func seriesQuery() async throws {
        let (client, transport) = try makeClient([.json(Self.seriesPageJSON)])
        _ = try await client.series(matching: SeriesQuery(libraryID: "lib-1", sort: .recentlyAdded, page: 2, size: 30))

        let request = try #require(transport.requests.first)
        #expect(request.path == "/api/v1/series")

        let query = queryValues(request)
        #expect(query["library_id"] == ["lib-1"])
        #expect(query["page"] == ["2"])
        #expect(query["size"] == ["30"])
        #expect(query["sort"] == ["created,desc"])
    }

    @Test("searching drops the sort so Komga can order by relevance")
    func searchDropsSort() async throws {
        let (client, transport) = try makeClient([.json(Self.seriesPageJSON)])
        _ = try await client.series(matching: SeriesQuery(searchTerm: " air gear "))

        let query = try queryValues(#require(transport.requests.first))
        #expect(query["search"] == ["air gear"])
        #expect(query["sort"] == nil)
    }

    @Test("a blank search term is not sent as a filter")
    func blankSearchIgnored() async throws {
        let (client, transport) = try makeClient([.json(Self.seriesPageJSON)])
        _ = try await client.series(matching: SeriesQuery(searchTerm: "   "))

        let query = try queryValues(#require(transport.requests.first))
        #expect(query["search"] == nil)
        #expect(query["sort"] == ["metadata.titleSort,asc"])
    }

    @Test("the series read-status filter is sent, repeated rather than comma-joined")
    func seriesReadStatusFilter() async throws {
        let (client, transport) = try makeClient([.json(Self.seriesPageJSON)])
        _ = try await client.series(matching: SeriesQuery(readStatus: [.unread, .inProgress]))

        let query = try queryValues(#require(transport.requests.first))
        #expect(query["read_status"] == ["UNREAD", "IN_PROGRESS"])
    }

    @Test("a series' books are requested in reading order")
    func booksSortedByNumber() async throws {
        let (
            client,
            transport
        ) =
            try makeClient(
                [.json(Self.emptyPageJSON(size: 100))]
            )
        _ = try await client.books(inSeries: "s-1", matching: BookQuery(readStatus: [.unread, .inProgress]))

        let request = try #require(transport.requests.first)
        #expect(request.path == "/api/v1/series/s-1/books")

        let query = queryValues(request)
        // numberSort, not the book's `number` string: "12.5" and "Extra" only
        // order correctly on the field Komga built for it.
        #expect(query["sort"] == ["metadata.numberSort,asc"])
        // Repeated rather than comma-joined — Komga binds a List<ReadStatus>.
        #expect(query["read_status"] == ["UNREAD", "IN_PROGRESS"])
    }

    @Test("on deck sends no sort, which the endpoint rejects")
    func onDeckSendsNoSort() async throws {
        let (
            client,
            transport
        ) =
            try makeClient(
                [.json(Self.emptyPageJSON(size: 20))]
            )
        _ = try await client.onDeck(matching: BookQuery(libraryID: "lib-1", size: 20))

        let request = try #require(transport.requests.first)
        #expect(request.path == "/api/v1/books/ondeck")

        let query = queryValues(request)
        #expect(query["sort"] == nil)
        #expect(query["library_id"] == ["lib-1"])
    }

    @Test("keep reading filters to in-progress, most recently read first")
    func keepReadingQuery() async throws {
        let (
            client,
            transport
        ) =
            try makeClient(
                [.json(Self.emptyPageJSON(size: 20))]
            )
        _ = try await client.keepReading(matching: BookQuery(size: 20))

        let request = try #require(transport.requests.first)
        #expect(request.path == "/api/v1/books")

        let query = queryValues(request)
        #expect(query["read_status"] == ["IN_PROGRESS"])
        #expect(query["sort"] == ["readProgress.readDate,desc"])
    }

    @Test("thumbnails ask for an image and come back as bytes")
    func thumbnailRequest() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let stub = Stub(status: 200, body: bytes, headers: ["Content-Type": "image/jpeg"], error: nil)
        let (client, transport) = try makeClient([stub])

        let data = try await client.thumbnailData(for: .series("s-1"))

        #expect(data == bytes)
        let request = try #require(transport.requests.first)
        #expect(request.path == "/api/v1/series/s-1/thumbnail")
        #expect(request.header("Accept") == "image/jpeg")
        #expect(request.header("X-API-Key") == "secret-key")
    }

    @Test("a missing thumbnail is nil, not an error")
    func missingThumbnail() async throws {
        // Normal mid-scan: Komga has the book but hasn't generated a poster.
        // Surfacing this as an error would put a banner over a healthy library.
        let (client, _) = try makeClient([.status(404)])

        #expect(try await client.thumbnailData(for: .book("b-1")) == nil)
    }
}
