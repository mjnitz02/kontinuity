//
//  DownloadRetentionTests.swift
//  KontinuityTests
//
//  The eviction decision table from PLAN §6, pinned case by case the same way
//  ProgressionSyncTests pins reconciliation — no SwiftData, no disk, no
//  simulator.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("DownloadRetention")
struct DownloadRetentionTests {
    private static let older = Date(timeIntervalSince1970: 1000)
    private static let newer = Date(timeIntervalSince1970: 2000)

    private func candidate(
        _ id: String,
        size: Int64 = 100,
        lastActivity: Date? = newer,
        isPending: Bool = false,
        isOpen: Bool = false
    ) -> RetentionCandidate {
        RetentionCandidate(
            bookID: id,
            sizeBytes: size,
            lastActivityDate: lastActivity,
            isPending: isPending,
            isOpen: isOpen
        )
    }

    @Test("under the cap evicts nothing")
    func underCapEvictsNothing() {
        let result = DownloadRetention.plan(
            candidates: [candidate("a"), candidate("b")],
            usedBytes: 150,
            capBytes: 500
        )
        #expect(result == DownloadRetention.Result(toEvict: [], insufficientSpace: false))
    }

    @Test("over the cap evicts least-recently-active first")
    func evictsOldestFirst() {
        let result = DownloadRetention.plan(
            candidates: [
                candidate("recent", size: 100, lastActivity: Self.newer),
                candidate("stale", size: 100, lastActivity: Self.older)
            ],
            usedBytes: 200,
            capBytes: 100
        )
        #expect(result.toEvict == ["stale"])
        #expect(!result.insufficientSpace)
    }

    @Test("stops evicting as soon as usage is back under the cap")
    func stopsOnceUnderCap() {
        let result = DownloadRetention.plan(
            candidates: [
                candidate("a", size: 100, lastActivity: Date(timeIntervalSince1970: 1)),
                candidate("b", size: 100, lastActivity: Date(timeIntervalSince1970: 2)),
                candidate("c", size: 100, lastActivity: Date(timeIntervalSince1970: 3))
            ],
            usedBytes: 300,
            capBytes: 250
        )
        #expect(result.toEvict == ["a"])
    }

    @Test("a book with unsynced local progress is never evicted")
    func skipsPendingBooks() {
        let result = DownloadRetention.plan(
            candidates: [
                candidate("pending", size: 100, lastActivity: Self.older, isPending: true),
                candidate("clean", size: 100, lastActivity: Self.newer)
            ],
            usedBytes: 200,
            capBytes: 100
        )
        #expect(result.toEvict == ["clean"])
    }

    @Test("the currently-open book is never evicted")
    func skipsOpenBook() {
        let result = DownloadRetention.plan(
            candidates: [
                candidate("open", size: 100, lastActivity: Self.older, isOpen: true),
                candidate("closed", size: 100, lastActivity: Self.newer)
            ],
            usedBytes: 200,
            capBytes: 100
        )
        #expect(result.toEvict == ["closed"])
    }

    @Test("a book with no read history sorts as the oldest")
    func noHistorySortsOldest() {
        let result = DownloadRetention.plan(
            candidates: [
                candidate("never-read", size: 100, lastActivity: nil),
                candidate("read-recently", size: 100, lastActivity: Self.newer)
            ],
            usedBytes: 200,
            capBytes: 100
        )
        #expect(result.toEvict == ["never-read"])
    }

    @Test("when pending/open exclusions leave nothing evictable, it says so rather than thrashing")
    func reportsInsufficientSpace() {
        let result = DownloadRetention.plan(
            candidates: [
                candidate("pending", size: 100, isPending: true),
                candidate("open", size: 100, isOpen: true)
            ],
            usedBytes: 200,
            capBytes: 50
        )
        #expect(result.toEvict.isEmpty)
        #expect(result.insufficientSpace)
    }

    @Test("partial eviction still reports insufficient space if the cap isn't met")
    func partialEvictionCanStillBeInsufficient() {
        let result = DownloadRetention.plan(
            candidates: [
                candidate("evictable", size: 50, lastActivity: Self.older),
                candidate("open", size: 200, lastActivity: Self.newer, isOpen: true)
            ],
            usedBytes: 250,
            capBytes: 100
        )
        #expect(result.toEvict == ["evictable"])
        #expect(result.insufficientSpace)
    }
}
