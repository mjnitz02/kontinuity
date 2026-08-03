//
//  OfflineLibraryTests.swift
//  KontinuityTests
//
//  The grouping/filtering/sorting rules PLAN §11 builds the offline fallback
//  views on top of, pinned without a simulator or SwiftData — same reasoning
//  as ProgressionSyncTests.
//

import Testing
@testable import KontinuityCore

@Suite("OfflineLibrary")
struct OfflineLibraryTests {
    private func snapshot(
        id: String,
        seriesID: String? = "series-1",
        seriesTitle: String? = "Windrunner",
        numberSort: Double? = nil,
        downloadState: DownloadState = .downloaded
    ) -> OfflineBookSnapshot {
        OfflineBookSnapshot(
            id: id,
            seriesID: seriesID,
            seriesTitle: seriesTitle,
            numberSort: numberSort,
            downloadState: downloadState
        )
    }

    // MARK: - series(from:)

    @Test("groups downloaded snapshots by series, one summary each")
    func groupsBySeries() {
        let snapshots = [
            snapshot(id: "b1", seriesID: "s1", seriesTitle: "Windrunner"),
            snapshot(id: "b2", seriesID: "s1", seriesTitle: "Windrunner"),
            snapshot(id: "b3", seriesID: "s2", seriesTitle: "Neon Requiem")
        ]
        let series = OfflineLibrary.series(from: snapshots)

        #expect(series.count == 2)
        #expect(series.first { $0.id == "s1" }?.downloadedBookCount == 2)
        #expect(series.first { $0.id == "s2" }?.downloadedBookCount == 1)
    }

    @Test("only downloaded snapshots count — a queued or mid-download book has nothing to read offline")
    func excludesUndownloaded() {
        let snapshots = [
            snapshot(id: "b1", seriesID: "s1", downloadState: .downloaded),
            snapshot(id: "b2", seriesID: "s1", downloadState: .downloading),
            snapshot(id: "b3", seriesID: "s2", downloadState: .queued)
        ]
        let series = OfflineLibrary.series(from: snapshots)

        #expect(series.map(\.id) == ["s1"])
        #expect(series.first?.downloadedBookCount == 1)
    }

    @Test("a snapshot with no series id is dropped rather than crashing the grouping")
    func dropsRowsWithNoSeriesID() {
        let snapshots = [
            snapshot(id: "b1", seriesID: nil),
            snapshot(id: "b2", seriesID: "s1")
        ]
        let series = OfflineLibrary.series(from: snapshots)

        #expect(series.map(\.id) == ["s1"])
    }

    @Test("sorted by title")
    func sortsByTitle() {
        let snapshots = [
            snapshot(id: "b1", seriesID: "s-z", seriesTitle: "Zeta"),
            snapshot(id: "b2", seriesID: "s-a", seriesTitle: "Alpha")
        ]
        let series = OfflineLibrary.series(from: snapshots)

        #expect(series.map(\.title) == ["Alpha", "Zeta"])
    }

    // MARK: - books(inSeries:from:)

    @Test("only the requested series' downloaded books, in numberSort order")
    func booksScopedToSeriesAndOrdered() {
        let snapshots = [
            snapshot(id: "b3", seriesID: "s1", numberSort: 3, downloadState: .downloaded),
            snapshot(id: "b1", seriesID: "s1", numberSort: 1, downloadState: .downloaded),
            snapshot(id: "b2", seriesID: "s1", numberSort: 2, downloadState: .queued),
            snapshot(id: "other", seriesID: "s2", numberSort: 1, downloadState: .downloaded)
        ]
        let books = OfflineLibrary.books(inSeries: "s1", from: snapshots)

        #expect(books.map(\.id) == ["b1", "b3"])
    }

    @Test("a series with nothing downloaded returns an empty list, not an error")
    func booksEmptyForUndownloadedSeries() {
        let snapshots = [snapshot(id: "b1", seriesID: "s1", downloadState: .queued)]
        #expect(OfflineLibrary.books(inSeries: "s1", from: snapshots).isEmpty)
    }
}
