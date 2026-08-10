//
//  SeriesReference.swift
//  Kontinuity
//
//  Navigating to a series from a book we're holding.
//
//  `SeriesDetailView` takes a whole `KomgaSeries` so it can render a title and a
//  cover before any request comes back — but a shelf or a book detail only ever
//  has the book, which carries `seriesId` and `seriesTitle` and nothing else.
//  Rather than gate the push behind a fetch (a spinner where the user expected a
//  screen), this builds the same kind of provisional row the grid would have
//  handed over, and `SeriesDetailView.task` replaces it with the real thing on
//  its very first await — the identical path it already takes for a genuinely
//  stale row tapped in the grid.
//
//  The counts are the honest part: they're left at zero and the status left
//  empty, so the header shows nothing rather than "0 books · Ongoing" for the
//  moment before the fetch lands. Anything derived from a count stays quiet
//  until it's real.
//

import KontinuityCore

extension KomgaSeries {
    static func reference(forSeriesOf book: KomgaBook) -> KomgaSeries {
        KomgaSeries(
            id: book.seriesId,
            libraryId: book.libraryId,
            name: book.seriesTitle,
            booksCount: 0,
            metadata: KomgaSeriesMetadata(title: book.seriesTitle, status: "")
        )
    }

    /// The same kind of provisional row, built from an offline grid cell
    /// instead of a book — `SeriesDetailView` doesn't know or care
    /// which one handed it this reference; the offline branch it falls into
    /// once there behaves exactly like an empty `refreshed` does everywhere
    /// else. `libraryId` is left empty: `Book` doesn't cache which library a
    /// series belongs to, and nothing downstream of this reference reads it.
    ///
    /// Unlike ``reference(forSeriesOf:)``, `booksCount` isn't zeroed out —
    /// that convention only works because the online reference is transient,
    /// replaced within the same task's first await. There's no fetch coming
    /// to replace this one, so it carries the one count that's actually
    /// known: how many of this series are downloaded. The read-state counts
    /// stay at their defaults, and `SeriesCell(showsReadState: false)` is
    /// what keeps that honest rather than reading as "fully read".
    static func reference(forOfflineSeries series: OfflineSeriesSummary) -> KomgaSeries {
        KomgaSeries(
            id: series.id,
            libraryId: "",
            name: series.title,
            booksCount: series.downloadedBookCount,
            metadata: KomgaSeriesMetadata(title: series.title, status: "")
        )
    }
}
