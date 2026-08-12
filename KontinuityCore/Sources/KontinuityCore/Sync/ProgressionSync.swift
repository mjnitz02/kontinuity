//
//  ProgressionSync.swift
//  KontinuityCore
//
//  The reconciliation policy, pure and UIKit/network-free — same
//  precedent as Layout/PageLayout.swift: the logic that's actually worth
//  getting right lives somewhere it can be unit-tested without a simulator or
//  a SwiftData container. `ProgressionSyncEngine` (app target) is the impure
//  half that persists `Book` rows and talks to `KomgaServing`.
//

import Foundation

/// A snapshot of one book's local sync state — everything `reconcile` needs,
/// with no dependency on how it's stored. `ProgressionSyncEngine` builds this
/// from a `Book` row rather than handing the row itself across the boundary.
public struct LocalProgress: Equatable, Sendable {
    /// The last position this device knows about, pushed or not.
    public let page: Int
    public let readDate: Date
    /// The last state both sides are known to agree on — what "moved since
    /// the last sync" is measured against, not `page`.
    public let serverPage: Int?
    public let serverReadDate: Date?
    /// True when there's an unpushed local write.
    public let isPending: Bool

    public init(page: Int, readDate: Date, serverPage: Int?, serverReadDate: Date?, isPending: Bool) {
        self.page = page
        self.readDate = readDate
        self.serverPage = serverPage
        self.serverReadDate = serverReadDate
        self.isPending = isPending
    }
}

public enum SyncOutcome: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        case local, server
    }

    /// Nothing to do — the two sides already agree.
    case noChange
    /// The local write is the only thing that moved; the caller's outbox
    /// flush will push it.
    case pushLocal
    /// The server moved and local didn't — overwrite the local row with it.
    case adoptServer(page: Int, readDate: Date)
    /// Both sides moved since the last sync: take the further page
    /// rather than silently discarding either one, and tell the user.
    case bothMoved(winner: Side, page: Int, readDate: Date)
}

public enum ProgressionSync {
    /// `local` is nil when this book has no row at all — nothing was ever
    /// written from this device, so there is nothing to reconcile.
    public static func reconcile(local: LocalProgress?, server: KomgaReadProgress?) -> SyncOutcome {
        guard let local else { return .noChange }

        guard let server else {
            // Never opened server-side (204 decoded to nil). The only
            // meaningful case is an unpushed local write waiting to create it.
            return local.isPending ? .pushLocal : .noChange
        }

        let serverMoved = local.serverPage != server.page || local.serverReadDate != server.readDate

        switch (local.isPending, serverMoved) {
        case (false, false):
            return .noChange
        case (true, false):
            return .pushLocal
        case (false, true):
            return .adoptServer(page: server.page, readDate: server.readDate)
        case (true, true):
            if local.page >= server.page {
                return .bothMoved(winner: .local, page: local.page, readDate: local.readDate)
            }
            return .bothMoved(winner: .server, page: server.page, readDate: server.readDate)
        }
    }
}
