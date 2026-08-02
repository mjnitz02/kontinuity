//
//  Book.swift
//  KontinuityCore
//
//  Phase 4's sync-tracking record — the subset of PLAN §4's full `Book` schema
//  that the outbox and reconciliation need. Title, page count and the rest of
//  the metadata cache arrive with phase 5's download engine; until then this
//  app doesn't cache books at all, it re-fetches them live.
//
//  A row exists only for a book that has been read *on this device* — that's
//  what scopes reconciliation to books this device could plausibly have
//  diverged from the server on, rather than every book in the library.
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

    public init(
        id: String,
        localPage: Int,
        localReadDate: Date,
        pageHref: String,
        mediaType: String,
        serverPage: Int? = nil,
        serverReadDate: Date? = nil,
        isPending: Bool = true
    ) {
        self.id = id
        self.localPage = localPage
        self.localReadDate = localReadDate
        self.pageHref = pageHref
        self.mediaType = mediaType
        self.serverPage = serverPage
        self.serverReadDate = serverReadDate
        self.isPending = isPending
    }
}
