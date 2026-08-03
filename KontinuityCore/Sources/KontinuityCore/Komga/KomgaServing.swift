//
//  KomgaServing.swift
//  KontinuityCore
//
//  The single boundary between the app and the server. PLAN §2 splits transports
//  (OPDS v2 for reading and sync, /api for read-status queries) deliberately —
//  this protocol is where that split stays contained instead of smearing across
//  the feature code. It grows one phase at a time; today it's phase 1's surface.
//

import Foundation

public protocol KomgaServing: Sendable {
    /// Unauthenticated reachability probe against `/actuator/health`, which
    /// Komga's `SecurityConfiguration` leaves open to all. Lets the connect
    /// screen tell "wrong address" apart from "wrong credentials".
    func checkReachable() async throws

    /// `GET /api/v2/users/me` — the authenticated identity check.
    func currentUser() async throws -> KomgaUser

    /// `POST /api/v2/users/me/api-keys`. The response is the only time the key
    /// itself is returned; afterwards Komga redacts it.
    func createAPIKey(comment: String) async throws -> KomgaAPIKey

    /// `DELETE /api/v2/users/me/api-keys/{id}` — used to revoke on disconnect so
    /// signing out doesn't leave an orphaned key on the server forever.
    func deleteAPIKey(id: String) async throws

    // MARK: - Browse (phase 2)

    /// `GET /api/v1/libraries` — unpaged; Komga returns the lot.
    func libraries() async throws -> [KomgaLibrary]

    /// `GET /api/v1/series` — the series grid, with search and library filter.
    func series(matching query: SeriesQuery) async throws -> KomgaPage<KomgaSeries>

    /// `GET /api/v1/series/{id}`
    func series(id: String) async throws -> KomgaSeries

    /// `GET /api/v1/series/{id}/books`, sorted by `metadata.numberSort` — the
    /// reading order, which is also the order phase 5 enqueues downloads in.
    func books(inSeries seriesID: String, matching query: BookQuery) async throws -> KomgaPage<KomgaBook>

    /// `GET /api/v1/books/{id}`
    func book(id: String) async throws -> KomgaBook

    /// `GET /api/v1/books?read_status=IN_PROGRESS`, most recently read first.
    func keepReading(matching query: BookQuery) async throws -> KomgaPage<KomgaBook>

    /// `GET /api/v1/books/ondeck` — the next unread book of each series that's
    /// been started and has nothing in progress. Komga computes this; there is
    /// no sane way to derive it client-side without reading the whole library.
    func onDeck(matching query: BookQuery) async throws -> KomgaPage<KomgaBook>

    /// Poster bytes for a series or book. Returns nil when Komga has no
    /// thumbnail yet (404), which is a normal state during a library scan
    /// rather than something worth showing an error for.
    func thumbnailData(for target: KomgaThumbnail) async throws -> Data?

    // MARK: - Reader (phase 3)

    /// `GET /opds/v2/books/{id}/manifest/divina` — the reader's page list, with
    /// width/height known before any image is fetched (KOMGA-API §2).
    func divinaManifest(forBook bookID: String) async throws -> KomgaDivinaManifest

    /// Fetches the bytes at a manifest-provided link — a page or its alternate.
    /// Takes the raw href Komga gave us rather than reconstructing a path, since
    /// the href already carries its own query string.
    func pageImageData(at href: String) async throws -> Data

    /// `PUT .../progression`.
    func putProgression(bookID: String, write: ProgressionWrite, device: KomgaDevice) async throws

    // MARK: - Download (phase 5)

    /// `GET /opds/v2/books/{id}/file` — the whole CBZ, one request. Requires
    /// role `FILE_DOWNLOAD`; the download coordinator falls back to per-page
    /// fetches through ``pageImageData(at:)`` on a 403 (KOMGA-API §6).
    func fileData(forBook bookID: String) async throws -> Data

    /// The authenticated request for the same endpoint, built but not sent.
    /// The download coordinator hands this to its own dedicated `URLSession`
    /// — a background configuration in production, so the transfer survives
    /// app suspension (PLAN §6) — rather than the service's own foreground
    /// session, which ``fileData(forBook:)`` uses.
    func fileDownloadRequest(forBook bookID: String) -> URLRequest
}

/// The `device.id`/`device.name` pair every progression write carries
/// (KOMGA-API §4), bundled so `putProgression` stays under the line-count limit
/// rather than taking both as loose parameters.
public struct KomgaDevice: Sendable, Hashable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// One page turn's worth of progression — the locator half of the PUT body
/// (KOMGA-API §4), bundled for the same reason as ``KomgaDevice``. `readDate`
/// is the timestamp of the page turn itself, not of the call — an outbox
/// entry flushed later must carry the original turn time so Komga's
/// monotonic clock guard sees the write in the order it actually happened,
/// not the order it was sent.
public struct ProgressionWrite: Sendable, Hashable {
    public let page: Int
    public let pageHref: String
    public let mediaType: String
    public let readDate: Date

    public init(page: Int, pageHref: String, mediaType: String, readDate: Date) {
        self.page = page
        self.pageHref = pageHref
        self.mediaType = mediaType
        self.readDate = readDate
    }
}

// MARK: - Queries

public struct SeriesQuery: Sendable, Hashable {
    public var libraryID: String?
    /// Free-text search across series metadata. Komga switches the default sort
    /// to relevance when this is set, so ``sort`` is skipped while searching.
    public var searchTerm: String?
    /// Nil includes both; Komga's own series feeds pass `false`, which is why
    /// oneshots are invisible in most clients (KOMGA-API §6).
    public var oneshot: Bool?
    /// Empty means no filter. Komga ORs multiple values together, and evaluates
    /// each series as a whole — READ means every book is, UNREAD means none are,
    /// IN_PROGRESS is everything in between (`SeriesSearchHelper.kt`).
    public var readStatus: [KomgaReadStatus]
    public var sort: SeriesSort
    public var page: Int
    public var size: Int

    public init(
        libraryID: String? = nil,
        searchTerm: String? = nil,
        oneshot: Bool? = nil,
        readStatus: [KomgaReadStatus] = [],
        sort: SeriesSort = .title,
        page: Int = 0,
        size: Int = 60
    ) {
        self.libraryID = libraryID
        self.searchTerm = searchTerm
        self.oneshot = oneshot
        self.readStatus = readStatus
        self.sort = sort
        self.page = page
        self.size = size
    }

    /// The same query pointed at a later page.
    public func page(_ page: Int) -> SeriesQuery {
        var copy = self
        copy.page = page
        return copy
    }
}

public enum SeriesSort: String, Sendable, Hashable, CaseIterable {
    case title = "metadata.titleSort,asc"
    case recentlyAdded = "created,desc"
    case recentlyUpdated = "lastModified,desc"

    public var label: String {
        switch self {
        case .title: "Title"
        case .recentlyAdded: "Recently added"
        case .recentlyUpdated: "Recently updated"
        }
    }
}

public struct BookQuery: Sendable, Hashable {
    /// Empty means no filter. Komga ORs multiple values together.
    public var readStatus: [KomgaReadStatus]
    /// Only meaningful for the library-wide feeds; ignored when listing a
    /// series' books, which are already scoped.
    public var libraryID: String?
    /// Only meaningful when listing a series' books, which are always ordered
    /// by `metadata.numberSort`. `false` reverses it, newest chapter first.
    public var ascending: Bool
    public var page: Int
    public var size: Int

    public init(
        readStatus: [KomgaReadStatus] = [],
        libraryID: String? = nil,
        ascending: Bool = true,
        page: Int = 0,
        size: Int = 100
    ) {
        self.readStatus = readStatus
        self.libraryID = libraryID
        self.ascending = ascending
        self.page = page
        self.size = size
    }

    public func page(_ page: Int) -> BookQuery {
        var copy = self
        copy.page = page
        return copy
    }
}

/// The two poster endpoints, which differ only in their path.
public enum KomgaThumbnail: Sendable, Hashable {
    case series(String)
    case book(String)

    public var path: String {
        switch self {
        case let .series(id): "/api/v1/series/\(id)/thumbnail"
        case let .book(id): "/api/v1/books/\(id)/thumbnail"
        }
    }
}
