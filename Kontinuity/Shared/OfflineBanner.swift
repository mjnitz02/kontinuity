//
//  OfflineBanner.swift
//  Kontinuity
//
//  PLAN §11: when a browse screen has fallen back to a locally-derived view
//  because the server can't be reached, this is what makes sure it's never
//  mistaken for the whole library — mounted persistently (not a toast like
//  `ConflictNoticeBanner`) on every screen that can show one.
//

import KontinuityCore
import SwiftUI

struct OfflineBanner: View {
    var body: some View {
        Label("Offline — showing downloaded series only", systemImage: "wifi.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            .accessibilityIdentifier(AID.offlineBanner)
    }
}

extension Book {
    /// Bridges the SwiftData row into `KontinuityCore`'s offline query layer
    /// (`OfflineLibrary.swift`) — that module stays SwiftData-free, so the
    /// mapping from a `@Query` result happens here, at the app-layer call
    /// sites, rather than in Core.
    var offlineSnapshot: OfflineBookSnapshot {
        OfflineBookSnapshot(
            id: id,
            seriesID: seriesID,
            seriesTitle: seriesTitle,
            numberSort: numberSort,
            downloadState: downloadState
        )
    }

    /// The read state this row's own local progress represents.
    ///
    /// `asKomgaBook`'s reconstructed `readProgress` is deliberately nil — that
    /// field means "what the server last said" to `ProgressionSyncEngine
    /// .reconcile(with:)`, and stuffing local progress into it would read as
    /// a fabricated server answer the next time that book round-trips
    /// through sync. So it can't carry the local state, but an offline view
    /// still needs to show it — this is what those call sites use instead of
    /// `asKomgaBook.readState`.
    var offlineReadState: KomgaReadState {
        guard let pagesCount, pagesCount > 0 else { return .unread }
        if localPage <= 0 {
            return .unread
        }
        if localPage >= pagesCount {
            return .read
        }
        return .inProgress(page: localPage, of: pagesCount)
    }
}
