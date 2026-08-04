//
//  BookShelfView.swift
//  Kontinuity
//
//  Keep Reading and On Deck. Both are flat lists of books rather than series, so
//  they share one grid — the only thing that differs is which endpoint fills it.
//

import KontinuityCore
import SwiftUI

struct BookShelfView: View {
    enum Shelf: Hashable {
        /// Books with progress, most recently read first.
        case keepReading
        /// The next unread book of each series you've started — computed
        /// server-side, because deriving it needs the whole library.
        case onDeck

        var title: String {
            switch self {
            case .keepReading: "Keep Reading"
            case .onDeck: "On Deck"
            }
        }

        var emptyMessage: String {
            switch self {
            case .keepReading: "Books you're partway through show up here."
            case .onDeck: "Finish a book and the next one in its series appears here."
            }
        }

        var systemImage: String {
            switch self {
            case .keepReading: "bookmark"
            case .onDeck: "square.stack"
            }
        }
    }

    let shelf: Shelf
    /// Nil spans every library.
    var libraryID: String?

    @Environment(KomgaSession.self) private var session
    @State private var feed = PagedFeed<KomgaBook>()

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(feed.items) { book in
                    BookCell(book: book)
                        .onAppear { feed.loadMoreIfNeeded(currentItem: book) }
                }
            }
            .padding(20)

            if feed.phase == .loadingMore {
                ProgressView().padding(.bottom, 24)
            }
        }
        .overlay { status }
        .navigationTitle(shelf.title)
        .refreshable {
            await session.flushAndReconcileDownloads()
            await feed.refresh()
        }
        .task(id: Query(shelf: shelf, libraryID: libraryID)) {
            let service = session.service
            let sync = session.sync
            let library = libraryID
            let shelf = shelf
            feed.start { page in
                let query = BookQuery(libraryID: library, page: page, size: 40)
                return switch shelf {
                case .keepReading: try await service.keepReading(matching: query)
                case .onDeck: try await service.onDeck(matching: query)
                }
            } didReplace: { books in
                books.forEach { sync.reconcile(with: $0) }
            }
        }
        .navigationDestination(for: KomgaBook.self) { book in
            BookDetailView(book: book)
        }
        // A shelf shows the *next* book of a series, which is the one thing you
        // want most of the time and no help at all when you want the series'
        // whole state. Without this the only route there is back to the grid and
        // a search for a title you're already looking at.
        .navigationDestination(for: KomgaSeries.self) { series in
            SeriesDetailView(series: series)
        }
    }

    @ViewBuilder
    private var status: some View {
        if feed.phase == .loading {
            ProgressView()
        } else if let message = feed.phase.errorMessage, feed.items.isEmpty {
            ContentUnavailableView {
                Label(errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { feed.retry() }
            }
            .accessibilityIdentifier(AID.browseError)
        } else if feed.isEmpty {
            ContentUnavailableView(
                "Nothing here",
                systemImage: shelf.systemImage,
                description: Text(shelf.emptyMessage)
            )
            .accessibilityIdentifier(AID.browseEmpty)
        }
    }

    /// Both shelves are server-computed (Keep Reading needs the whole
    /// library's read state; On Deck needs the whole library's series
    /// structure) — neither has an offline fallback, so a connection
    /// failure reads as an expected limitation rather than a bug.
    private var errorTitle: String {
        if feed.phase.isOffline {
            return "\(shelf.title) needs a connection to your server"
        }
        return "Couldn't load \(shelf.title)"
    }

    private struct Query: Hashable {
        let shelf: Shelf
        let libraryID: String?
    }
}

/// A book on a shelf, where the series it belongs to is the useful context —
/// unlike a book in a series list, where it's already obvious.
///
/// Two targets, deliberately: the cover opens the book (the shelf's whole point
/// is that it's the one you'd read next), and the series title opens the series.
/// They're siblings rather than nested, because a link inside a link is
/// ambiguous about which one a tap meant.
struct BookCell: View {
    let book: KomgaBook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: book) {
                CoverImage(target: .book(book.id))
                    .overlay(alignment: .bottom) {
                        if let fraction = book.readState.fraction {
                            ReadProgressBar(fraction: fraction)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(book.seriesTitle) \(book.displayTitle), \(book.readState.label)")
                    .accessibilityIdentifier(AID.bookRow(book.id))
            }
            .buttonStyle(.plain)

            SeriesLink(book: book)

            Text(book.readState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The series title as a link to the whole series, for the screens that show a
/// single book of one — a shelf cell and book detail.
///
/// Tinted and chevroned rather than styled `.plain`: it sits directly under a
/// cover that's also tappable and goes somewhere else, so it has to *read* as a
/// separate destination rather than as this cell's caption.
struct SeriesLink: View {
    let book: KomgaBook
    var font: Font = .subheadline

    var body: some View {
        NavigationLink(value: KomgaSeries.reference(forSeriesOf: book)) {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .imageScale(.small)
            }
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), whole series")
            .accessibilityIdentifier(AID.seriesLink(book.seriesId))
        }
    }

    /// A oneshot has no series title of its own; its own title is the honest
    /// label, and the series it nominally belongs to is still where the link goes.
    private var title: String {
        book.seriesTitle.isEmpty ? book.displayTitle : book.seriesTitle
    }
}
