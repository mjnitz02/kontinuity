//
//  OfflineLibrary.swift
//  KontinuityCore
//
//  PLAN §11: what "offline" browsing derives from what's already sitting in
//  `Book` rows for anything downloaded — no new model, just grouping and
//  filtering over the metadata cache phase 5 already writes. Pure and
//  SwiftData-free, same precedent as Sync/ProgressionSync.swift: the app
//  layer maps a `@Query` result of `Book` into `[OfflineBookSnapshot]` at the
//  call site, and everything past that point is unit-testable without a
//  simulator.
//

import Foundation

/// A plain mirror of the `Book` fields the offline views need. The app layer
/// builds these from `Book` rows; `KontinuityCore` never touches SwiftData.
public struct OfflineBookSnapshot: Sendable, Hashable, Identifiable {
    public let id: String
    public let seriesID: String?
    public let seriesTitle: String?
    public let numberSort: Double?
    public let downloadState: DownloadState

    public init(
        id: String,
        seriesID: String?,
        seriesTitle: String?,
        numberSort: Double?,
        downloadState: DownloadState
    ) {
        self.id = id
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.numberSort = numberSort
        self.downloadState = downloadState
    }
}

/// One row of the offline All Series grid — just enough to draw a cell and
/// build a provisional `KomgaSeries` for it (`SeriesReference.swift`).
public struct OfflineSeriesSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let downloadedBookCount: Int

    public init(id: String, title: String, downloadedBookCount: Int) {
        self.id = id
        self.title = title
        self.downloadedBookCount = downloadedBookCount
    }
}

/// The two offline-fallback queries PLAN §11 needs. Every one filters to
/// `downloadState == .downloaded` first — a book only queued or mid-download
/// has no page files to actually read offline.
public enum OfflineLibrary {
    /// Downloaded snapshots grouped by series, sorted by title.
    public static func series(from snapshots: [OfflineBookSnapshot]) -> [OfflineSeriesSummary] {
        let downloaded = snapshots.filter { $0.downloadState == .downloaded }
        let grouped = Dictionary(grouping: downloaded) { $0.seriesID }
        return grouped.compactMap { seriesID, books -> OfflineSeriesSummary? in
            guard let seriesID else { return nil }
            let title = books.first(where: { !($0.seriesTitle ?? "").isEmpty })?.seriesTitle ?? seriesID
            return OfflineSeriesSummary(id: seriesID, title: title, downloadedBookCount: books.count)
        }
        .sorted { $0.title < $1.title }
    }

    /// A series' downloaded snapshots, in reading order.
    public static func books(
        inSeries seriesID: String,
        from snapshots: [OfflineBookSnapshot]
    ) -> [OfflineBookSnapshot] {
        snapshots
            .filter { $0.downloadState == .downloaded && $0.seriesID == seriesID }
            .sorted { ($0.numberSort ?? 0) < ($1.numberSort ?? 0) }
    }
}
