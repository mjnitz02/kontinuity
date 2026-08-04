//
//  DownloadRetention.swift
//  KontinuityCore
//
//  The eviction decision table from PLAN §6: over the storage cap, evict
//  whole books least-recently-read first, never touching a book with
//  unsynced local progress or the one currently open. Pure — no SwiftData,
//  no disk access — mirroring `ProgressionSync`'s split from its engine.
//

import Foundation

public struct RetentionCandidate: Sendable, Hashable {
    public let bookID: String
    public let sizeBytes: Int64
    /// Nil for a book with no read history at all, which sorts as the
    /// oldest — evicting an untouched download before one that's actually
    /// been read is the right default.
    public let lastActivityDate: Date?
    /// A book with unsynced local progress is never evicted — deleting its
    /// files would throw away the only copy of that progress (PLAN §6).
    public let isPending: Bool
    /// The book currently open in the reader is never evicted out from under
    /// the person reading it.
    public let isOpen: Bool

    public init(bookID: String, sizeBytes: Int64, lastActivityDate: Date?, isPending: Bool, isOpen: Bool) {
        self.bookID = bookID
        self.sizeBytes = sizeBytes
        self.lastActivityDate = lastActivityDate
        self.isPending = isPending
        self.isOpen = isOpen
    }
}

public enum DownloadRetention {
    public struct Result: Sendable, Equatable {
        public let toEvict: [String]
        /// True when the pending/open exclusions leave nothing left to evict
        /// (or not enough of it) and usage is still over the cap — the queue
        /// should pause and say so rather than silently thrash (PLAN §6).
        public let insufficientSpace: Bool
    }

    /// `usedBytes` is the total across every downloaded book, not just the
    /// candidates passed in, so callers can score the whole library while
    /// only offering up books that are actually eviction-eligible.
    public static func plan(candidates: [RetentionCandidate], usedBytes: Int64, capBytes: Int64) -> Result {
        guard usedBytes > capBytes else {
            return Result(toEvict: [], insufficientSpace: false)
        }

        let evictable = candidates
            .filter { !$0.isPending && !$0.isOpen }
            .sorted { ($0.lastActivityDate ?? .distantPast) < ($1.lastActivityDate ?? .distantPast) }

        var remaining = usedBytes
        var evicted: [String] = []
        for candidate in evictable {
            guard remaining > capBytes else { break }
            evicted.append(candidate.bookID)
            remaining -= candidate.sizeBytes
        }

        return Result(toEvict: evicted, insufficientSpace: remaining > capBytes)
    }
}
