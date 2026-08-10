//
//  Book.swift
//  KontinuityCore
//
//  One row per book that has been read *or downloaded* on this device. It
//  carries three things that could have been three models — the sync outbox,
//  the metadata cache, and download state — for the same reason `isPending`
//  doubles as the outbox entry: less to keep in sync.
//

import Foundation
import SwiftData

@Model
public final class Book {
    /// Komga's book id. Unique per server, and multi-server is a non-goal, so
    /// there's no need to namespace it by server.
    @Attribute(.unique) public var id: String

    /// The last position this device knows about, whether or not it has been
    /// pushed yet. Written synchronously on every page turn — the reader never
    /// waits on the network to record where the user is.
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
    /// coalesced for free by upserting on every page turn.
    public var isPending: Bool

    // MARK: - Metadata cache

    /// Cached from `KomgaBook` at download time so the "Downloaded" root and
    /// the Downloads queue can show a title/series with no server involved.
    public var seriesID: String?
    public var seriesTitle: String?
    public var title: String?
    public var number: String?
    public var numberSort: Double?
    public var pagesCount: Int?
    public var sizeBytes: Int64?

    // MARK: - Download state

    /// Persisted as the raw string, not `DownloadState` directly. Migrating a
    /// custom enum attribute's default value into an existing on-disk store
    /// (this one shipped before download state existed) mis-typed it at
    /// runtime — `Could not cast value of type 'Optional<Any>' to
    /// 'DownloadState'` on first read after migration, verified against a real
    /// store. A plain `String`, the primitive `downloadedBytes` below already
    /// migrates cleanly as, sidesteps it.
    private var downloadStateRaw: String = DownloadState.notDownloaded.rawValue
    public var downloadState: DownloadState {
        get { DownloadState(rawValue: downloadStateRaw) ?? .notDownloaded }
        set { downloadStateRaw = newValue.rawValue }
    }

    // Inline default, not just the initializer's — a non-optional attribute
    // added after the store had already shipped needs one on the
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

    /// 0…1 for a progress bar. Zero until the transfer reports an expected
    /// size, which is the honest reading of "we don't know yet" rather than a
    /// bar that fills and resets.
    public var downloadProgressFraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(expectedBytes)))
    }

    /// Reconstructs a `KomgaBook` from the cached metadata so a downloaded
    /// book can be opened, browsed, or listed with no server involved at all
    /// — the whole point of the "Downloaded" root and of every offline
    /// fallback view. `readProgress` is left
    /// nil: `ReaderModel` resolves the resume position through
    /// `ProgressionSyncEngine` against this same row, not from this field.
    public var asKomgaBook: KomgaBook {
        KomgaBook(
            id: id,
            seriesId: seriesID ?? "",
            seriesTitle: seriesTitle ?? "",
            name: title ?? id,
            sizeBytes: sizeBytes ?? 0,
            media: KomgaMedia(pagesCount: pagesCount ?? 0),
            metadata: KomgaBookMetadata(title: title ?? "", number: number ?? "", numberSort: numberSort ?? 0)
        )
    }
}
