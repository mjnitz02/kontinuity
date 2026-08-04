//
//  ProgressionSyncTests.swift
//  KontinuityTests
//
//  The reconciliation policy table from PLAN §5, pinned case by case so the
//  "never silently discard a position" guarantee is provable without a
//  simulator or a SwiftData container — same reasoning as PageLayoutTests.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("ProgressionSync")
struct ProgressionSyncTests {
    private static let synced = Date(timeIntervalSince1970: 1000)
    private static let later = Date(timeIntervalSince1970: 2000)
    private static let evenLater = Date(timeIntervalSince1970: 3000)

    private func serverProgress(page: Int, readDate: Date) -> KomgaReadProgress {
        KomgaReadProgress(page: page, completed: false, readDate: readDate)
    }

    @Test("no local row at all — nothing was ever written from this device")
    func noLocalRow() {
        let outcome = ProgressionSync.reconcile(
            local: nil,
            server: serverProgress(page: 10, readDate: Self.later)
        )
        #expect(outcome == .noChange)
    }

    @Test("both sides already agree")
    func equalIsNoChange() {
        let local = LocalProgress(
            page: 10, readDate: Self.synced,
            serverPage: 10, serverReadDate: Self.synced,
            isPending: false
        )
        let outcome = ProgressionSync.reconcile(local: local, server: serverProgress(page: 10, readDate: Self.synced))
        #expect(outcome == .noChange)
    }

    @Test("only local moved — the outbox flush will push it")
    func onlyLocalMovedPushesLocal() {
        let local = LocalProgress(
            page: 12, readDate: Self.later,
            serverPage: 10, serverReadDate: Self.synced,
            isPending: true
        )
        let outcome = ProgressionSync.reconcile(local: local, server: serverProgress(page: 10, readDate: Self.synced))
        #expect(outcome == .pushLocal)
    }

    @Test("never pushed, and the server has never seen this book — still just a push")
    func neverOpenedServerSideIsPushLocal() {
        let local = LocalProgress(
            page: 3, readDate: Self.later,
            serverPage: nil, serverReadDate: nil,
            isPending: true
        )
        let outcome = ProgressionSync.reconcile(local: local, server: nil)
        #expect(outcome == .pushLocal)
    }

    @Test("only the server moved — adopt it")
    func onlyServerMovedAdoptsServer() {
        let local = LocalProgress(
            page: 10, readDate: Self.synced,
            serverPage: 10, serverReadDate: Self.synced,
            isPending: false
        )
        let outcome = ProgressionSync.reconcile(local: local, server: serverProgress(page: 15, readDate: Self.later))
        #expect(outcome == .adoptServer(page: 15, readDate: Self.later))
    }

    @Test("both sides moved and local is further — local wins, and it's a conflict worth reporting")
    func bothMovedLocalFurtherWins() {
        let local = LocalProgress(
            page: 20, readDate: Self.evenLater,
            serverPage: 10, serverReadDate: Self.synced,
            isPending: true
        )
        let outcome = ProgressionSync.reconcile(local: local, server: serverProgress(page: 15, readDate: Self.later))
        #expect(outcome == .bothMoved(winner: .local, page: 20, readDate: Self.evenLater))
    }

    @Test("both sides moved and the server is further — server wins")
    func bothMovedServerFurtherWins() {
        let local = LocalProgress(
            page: 12, readDate: Self.later,
            serverPage: 10, serverReadDate: Self.synced,
            isPending: true
        )
        let outcome = ProgressionSync.reconcile(
            local: local,
            server: serverProgress(page: 20, readDate: Self.evenLater)
        )
        #expect(outcome == .bothMoved(winner: .server, page: 20, readDate: Self.evenLater))
    }

    @Test("a stale local row with nothing pending and an absent server progress stays put")
    func absentServerWithNothingPendingIsNoChange() {
        let local = LocalProgress(
            page: 5, readDate: Self.synced,
            serverPage: 5, serverReadDate: Self.synced,
            isPending: false
        )
        let outcome = ProgressionSync.reconcile(local: local, server: nil)
        #expect(outcome == .noChange)
    }
}
