//
//  Book.swift
//  KontinuityCore
//
//  PLAN §4's full `Book` schema, arrived at in two phases. Phase 4 added the
//  sync-tracking half (outbox + reconciliation). Phase 5 adds the metadata
//  cache and download-state fields the download engine needs — one row per
//  book, rather than a parallel model, for the same reason `isPending`
//  doubles as the outbox: less to keep in sync.
//
//  A row now exists for a book that has been read *or downloaded* on this
//  device — broader than phase 4's "read only" scope, since "Download unread"
//  creates rows for books that have never been opened.
//

import Foundation
import SwiftData

@Model
public final class Book {
    /// Komga's book id. Unique per server, and multi-server is a non-goal
    /// (PLAN §1), so there's no need to namespace it by server.
    @Attribute(.unique) public var id: String

    /// The last position this device knows about, whether or not it has been
    /// pushed yet. Written synchronously on every page turn — the reader never
    /// waits on the network to record where the user is (PLAN §5).
    public var localPage: Int
    /// The page turn's own timestamp — carried through to the eventual `PUT`
    /// so Komga's monotonic clock guard sees the write in the order it
    /// actually happened, not the order the outbox happened to flush it.
    public var localReadDate: Date
    public var pageHref: String
    public var mediaType: String

    /// The last state both sides are known to agree on: either the response to
    /// our own successful push, or what a reconciliation pass adopted from the
    /// server. This is what "moved since the last sync" is measured against —
    /// not `localPage`, which may already be ahead of it.
    public var serverPage: Int?
    public var serverReadDate: Date?

    /// True while there's an unpushed write — this row doubles as its own
    /// outbox entry rather than needing a separate table. One entry per book,
    /// coalesced for free by upserting on every page turn (PLAN §5).
    public var isPending: Bool

    // MARK: - Metadata cache (phase 5)

    /// Cached from `KomgaBook` at download time so the "Downloaded" root and
    /// the Downloads queue can show a title/series without the server —
    /// PLAN §7's offline-first requirement for that sidebar entry.
    public var seriesID: String?
    public var seriesTitle: String?
    public var title: String?
    public var number: String?
    public var numberSort: Double?
    public var pagesCount: Int?
    public var sizeBytes: Int64?

    // MARK: - Download state (phase 5)

    /// Persisted as the raw string, not `DownloadState` directly. Migrating a
    /// custom enum attribute's default value into an existing on-disk store
    /// (this one shipped in phase 4, before download state existed) mis-typed
    /// it at runtime — `Could not cast value of type 'Optional<Any>' to
    /// 'DownloadState'` on first read after migration, verified against a
    /// real pre-phase-5 store. A plain `String`, the primitive
    /// `downloadedBytes` below already migrates cleanly as, sidesteps it.
    private var downloadStateRaw: String = DownloadState.notDownloaded.rawValue
    public var downloadState: DownloadState {
        get { DownloadState(rawValue: downloadStateRaw) ?? .notDownloaded }
        set { downloadStateRaw = newValue.rawValue }
    }

    // Inline default, not just the initializer's — a non-optional attribute
    // added after the store had already shipped (phase 4) needs one on the
    // property declaration itself for SwiftData's automatic lightweight
    // migration to backfill it; the initializer's default alone isn't
    // visible to the migration. Without it: "missing attribute values on
    // mandatory destination attribute" opening an existing store.
    public var downloadedBytes: Int64 = 0
    public var expectedBytes: Int64 = 0
    public var downloadError: String?
    /// Set once the download is verified against the manifest's page count —
    /// this, not `localReadDate`, is what retention's "least-recently-read"
    /// eviction falls back to for a downloaded-but-never-opened book.
    public var downloadedDate: Date?

    public init(
        id: String,
        localPage: Int,
        localReadDate: Date,
        pageHref: String,
        mediaType: String,
        serverPage: Int? = nil,
        serverReadDate: Date? = nil,
        isPending: Bool = true,
        seriesID: String? = nil,
        seriesTitle: String? = nil,
        title: String? = nil,
        number: String? = nil,
        numberSort: Double? = nil,
        pagesCount: Int? = nil,
        sizeBytes: Int64? = nil,
        downloadState: DownloadState = .notDownloaded,
        downloadedBytes: Int64 = 0,
        expectedBytes: Int64 = 0,
        downloadError: String? = nil,
        downloadedDate: Date? = nil
    ) {
        self.id = id
        self.localPage = localPage
        self.localReadDate = localReadDate
        self.pageHref = pageHref
        self.mediaType = mediaType
        self.serverPage = serverPage
        self.serverReadDate = serverReadDate
        self.isPending = isPending
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.title = title
        self.number = number
        self.numberSort = numberSort
        self.pagesCount = pagesCount
        self.sizeBytes = sizeBytes
        self.downloadState = downloadState
        self.downloadedBytes = downloadedBytes
        self.expectedBytes = expectedBytes
        self.downloadError = downloadError
        self.downloadedDate = downloadedDate
    }

    /// The date retention/eviction measures recency against: this device's
    /// own read history where this book has actually been opened here,
    /// otherwise when the download landed — so a downloaded-but-unread book
    /// is still evictable rather than treated as infinitely recent just
    /// because `localReadDate` defaults to the row's creation time.
    public var lastActivityDate: Date? {
        localPage > 0 ? localReadDate : downloadedDate
    }
}
