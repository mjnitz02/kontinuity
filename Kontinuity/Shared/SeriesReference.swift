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
}
