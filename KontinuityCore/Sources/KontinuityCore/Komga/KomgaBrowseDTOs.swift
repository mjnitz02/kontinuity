//
//  KomgaBrowseDTOs.swift
//  KontinuityCore
//
//  Wire types for the browse surface (PLAN §2: read-status queries go through
//  /api/v1, not OPDS v2). Shapes taken from Komga 1.25.0's LibraryDto.kt /
//  SeriesDto.kt / BookDto.kt and checked against a live instance's responses.
//
//  These decode a deliberate subset. Komga sends a `*Lock` boolean beside every
//  metadata field for its own editing UI, and metadata editing is an explicit
//  non-goal (PLAN §1) — decoding them would be a hundred properties of pure
//  liability. Unknown keys are ignored by Codable, so omission is free.
//

import Foundation

// MARK: - Paging

/// Spring's `Page<T>` as Komga serialises it. Only the fields a client needs to
/// page through a list; `pageable`/`sort` are echoes of the request.
public struct KomgaPage<Element: Decodable & Sendable>: Decodable, Sendable {
    public let content: [Element]
    public let totalElements: Int
    public let totalPages: Int
    /// Zero-based, matching the `page` query parameter.
    public let number: Int
    public let size: Int
    public let first: Bool
    public let last: Bool

    public init(
        content: [Element],
        totalElements: Int,
        totalPages: Int,
        number: Int,
        size: Int,
        first: Bool,
        last: Bool
    ) {
        self.content = content
        self.totalElements = totalElements
        self.totalPages = totalPages
        self.number = number
        self.size = size
        self.first = first
        self.last = last
    }

    /// The page index to request next, or nil at the end. Pagination is driven
    /// off `last` rather than comparing counts: a library being scanned while
    /// you scroll changes `totalElements` between requests, and `last` is
    /// computed server-side against the same query.
    public var nextPage: Int? {
        last ? nil : number + 1
    }
}

// MARK: - Library

/// `GET /api/v1/libraries`. Komga returns ~30 fields of scanner configuration
/// here; a browser needs the name and whether the box is currently reachable.
public struct KomgaLibrary: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Komga sets this when the library's root path has gone away — a NAS that
    /// didn't mount. Worth showing rather than presenting an empty library as
    /// though the user deleted everything.
    public let unavailable: Bool

    public init(id: String, name: String, unavailable: Bool = false) {
        self.id = id
        self.name = name
        self.unavailable = unavailable
    }
}

// MARK: - Series

public struct KomgaSeries: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let libraryId: String
    /// The folder name. ``displayTitle`` prefers the metadata title, which is
    /// what the user actually curated.
    public let name: String
    public let booksCount: Int
    public let booksReadCount: Int
    public let booksUnreadCount: Int
    public let booksInProgressCount: Int
    public let metadata: KomgaSeriesMetadata
    public let booksMetadata: KomgaBooksMetadata
    public let oneshot: Bool
    public let deleted: Bool

    public init(
        id: String,
        libraryId: String,
        name: String,
        booksCount: Int,
        booksReadCount: Int = 0,
        booksUnreadCount: Int = 0,
        booksInProgressCount: Int = 0,
        metadata: KomgaSeriesMetadata,
        booksMetadata: KomgaBooksMetadata = KomgaBooksMetadata(),
        oneshot: Bool = false,
        deleted: Bool = false
    ) {
        self.id = id
        self.libraryId = libraryId
        self.name = name
        self.booksCount = booksCount
        self.booksReadCount = booksReadCount
        self.booksUnreadCount = booksUnreadCount
        self.booksInProgressCount = booksInProgressCount
        self.metadata = metadata
        self.booksMetadata = booksMetadata
        self.oneshot = oneshot
        self.deleted = deleted
    }

    public var displayTitle: String {
        metadata.title.isEmpty ? name : metadata.title
    }

    /// True once every book has been read. Derived rather than stored because
    /// Komga has no such field and the three counts are authoritative.
    public var isFullyRead: Bool {
        booksCount > 0 && booksUnreadCount == 0 && booksInProgressCount == 0
    }
}

public struct KomgaSeriesMetadata: Decodable, Sendable, Hashable {
    public let title: String
    public let titleSort: String
    public let summary: String
    public let status: String
    public let publisher: String
    public let language: String
    public let ageRating: Int?
    public let genres: Set<String>
    public let tags: Set<String>
    /// What the publisher says the series will total, when known — often larger
    /// than `booksCount` for an ongoing series that isn't fully acquired.
    public let totalBookCount: Int?
    /// `""` when unset, not absent — Komga's REST DTO types this as a non-null
    /// String, unlike the OPDS manifest where the key is omitted entirely
    /// (KOMGA-API §2). ``readingDirection`` turns that back into an optional.
    public let readingDirection: String

    public init(
        title: String,
        titleSort: String = "",
        summary: String = "",
        status: String = "ONGOING",
        publisher: String = "",
        language: String = "",
        ageRating: Int? = nil,
        genres: Set<String> = [],
        tags: Set<String> = [],
        totalBookCount: Int? = nil,
        readingDirection: String = ""
    ) {
        self.title = title
        self.titleSort = titleSort
        self.summary = summary
        self.status = status
        self.publisher = publisher
        self.language = language
        self.ageRating = ageRating
        self.genres = genres
        self.tags = tags
        self.totalBookCount = totalBookCount
        self.readingDirection = readingDirection
    }

    /// Nil when the series has no direction set. The reader pins LTR regardless
    /// (READER-DESIGN §1); this is kept so that stays a switch, not a rewrite.
    public var direction: KomgaReadingDirection? {
        KomgaReadingDirection(rawValue: readingDirection)
    }
}

public enum KomgaReadingDirection: String, Sendable, Hashable, CaseIterable {
    case leftToRight = "LEFT_TO_RIGHT"
    case rightToLeft = "RIGHT_TO_LEFT"
    case vertical = "VERTICAL"
    case webtoon = "WEBTOON"
}

/// Komga's aggregate of the metadata across a series' books.
public struct KomgaBooksMetadata: Decodable, Sendable, Hashable {
    public let authors: [KomgaAuthor]
    public let summary: String
    public let releaseDate: KomgaDay?

    public init(authors: [KomgaAuthor] = [], summary: String = "", releaseDate: KomgaDay? = nil) {
        self.authors = authors
        self.summary = summary
        self.releaseDate = releaseDate
    }
}

public struct KomgaAuthor: Decodable, Sendable, Hashable {
    public let name: String
    /// Lowercase in the wire format: "writer", "penciller", "colorist", …
    public let role: String

    public init(name: String, role: String) {
        self.name = name
        self.role = role
    }
}

// MARK: - Book

public struct KomgaBook: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let seriesId: String
    public let seriesTitle: String
    public let libraryId: String
    public let name: String
    public let sizeBytes: Int64
    /// Komga's own human-readable size ("30.6 MiB"), reused rather than
    /// recomputed so the app and the web UI agree to the digit.
    public let size: String
    public let media: KomgaMedia
    public let metadata: KomgaBookMetadata
    /// Nil when the book has never been opened — the same "never opened" that
    /// the progression endpoint expresses as 204 (KOMGA-API §4).
    public let readProgress: KomgaReadProgress?
    public let oneshot: Bool
    public let deleted: Bool

    public init(
        id: String,
        seriesId: String,
        seriesTitle: String = "",
        libraryId: String = "",
        name: String,
        sizeBytes: Int64 = 0,
        size: String = "",
        media: KomgaMedia,
        metadata: KomgaBookMetadata,
        readProgress: KomgaReadProgress? = nil,
        oneshot: Bool = false,
        deleted: Bool = false
    ) {
        self.id = id
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.libraryId = libraryId
        self.name = name
        self.sizeBytes = sizeBytes
        self.size = size
        self.media = media
        self.metadata = metadata
        self.readProgress = readProgress
        self.oneshot = oneshot
        self.deleted = deleted
    }

    public var displayTitle: String {
        metadata.title.isEmpty ? name : metadata.title
    }

    /// Where this book sits for the reader. Derived here so the UI, and later
    /// the download queue's "what's unread" question, agree on one definition.
    public var readState: KomgaReadState {
        guard let readProgress else { return .unread }
        if readProgress.completed {
            return .read
        }
        return .inProgress(page: readProgress.page, of: media.pagesCount)
    }

    /// Only DIVINA books are readable by this app (PLAN §1 rules out EPUB/PDF),
    /// and Komga reports `pagesCount == 0` until analysis finishes — so an
    /// unanalysed book must not be offered as readable (KOMGA-API §6).
    public var isReadable: Bool {
        media.status == "READY" && media.mediaProfile == "DIVINA" && media.pagesCount > 0
    }
}

public struct KomgaMedia: Decodable, Sendable, Hashable {
    /// `READY`, `UNKNOWN`, `ERROR`, `OUTDATED`.
    public let status: String
    public let mediaType: String
    public let pagesCount: Int
    /// `DIVINA`, `PDF` or `EPUB` — computed server-side from `mediaType`.
    public let mediaProfile: String
    /// Komga's explanation when `status` is `ERROR`; worth surfacing, since the
    /// alternative is a book that silently refuses to open.
    public let comment: String

    public init(
        status: String = "READY",
        mediaType: String = "application/zip",
        pagesCount: Int,
        mediaProfile: String = "DIVINA",
        comment: String = ""
    ) {
        self.status = status
        self.mediaType = mediaType
        self.pagesCount = pagesCount
        self.mediaProfile = mediaProfile
        self.comment = comment
    }
}

public struct KomgaBookMetadata: Decodable, Sendable, Hashable {
    public let title: String
    /// The volume/chapter label as text ("1", "12.5", "Extra"). Free-form.
    public let number: String
    /// The sortable form of `number`, and the field the API sorts on.
    public let numberSort: Double
    public let summary: String
    public let releaseDate: KomgaDay?
    public let authors: [KomgaAuthor]
    public let tags: Set<String>

    public init(
        title: String,
        number: String = "",
        numberSort: Double = 0,
        summary: String = "",
        releaseDate: KomgaDay? = nil,
        authors: [KomgaAuthor] = [],
        tags: Set<String> = []
    ) {
        self.title = title
        self.number = number
        self.numberSort = numberSort
        self.summary = summary
        self.releaseDate = releaseDate
        self.authors = authors
        self.tags = tags
    }
}

/// `GET /api/v1/…/books` inlines this, which is the whole reason browse goes
/// through `/api/v1` instead of OPDS v2 (PLAN §2 / KOMGA-API §3).
public struct KomgaReadProgress: Decodable, Sendable, Hashable {
    /// 1-based, matching the progression API's `locations.position`.
    public let page: Int
    public let completed: Bool
    public let readDate: Date
    public let deviceId: String
    public let deviceName: String

    public init(page: Int, completed: Bool, readDate: Date, deviceId: String = "", deviceName: String = "") {
        self.page = page
        self.completed = completed
        self.readDate = readDate
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

public enum KomgaReadState: Sendable, Hashable {
    case unread
    case inProgress(page: Int, of: Int)
    case read

    /// 0…1, or nil when there's no meaningful bar to draw.
    public var fraction: Double? {
        guard case let .inProgress(page, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(page) / Double(total)))
    }
}

/// Komga's read-status filter values.
public enum KomgaReadStatus: String, Sendable, Hashable, CaseIterable {
    case unread = "UNREAD"
    case inProgress = "IN_PROGRESS"
    case read = "READ"

    public var label: String {
        switch self {
        case .unread: "Unread"
        case .inProgress: "In progress"
        case .read: "Read"
        }
    }
}

// MARK: - Dates

/// A calendar date with no time — Komga's `LocalDate` fields (`releaseDate`),
/// serialised as `2018-01-18`.
///
/// It gets its own type rather than a `Date` because the client's decoder maps
/// every `Date` through the timestamp parser, and feeding a date-only string
/// through a timestamp formatter is how you end up a day off in a timezone west
/// of UTC. Keeping the calendar date whole avoids the question entirely.
public struct KomgaDay: Decodable, Sendable, Hashable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a yyyy-MM-dd date, got \(raw)"
            )
        }
        self.init(year: year, month: month, day: day)
    }

    public var dateComponents: DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    /// Resolved in the current calendar, for display only.
    public var date: Date? {
        Calendar.current.date(from: dateComponents)
    }
}
