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
                    NavigationLink(value: book) {
                        BookCell(book: book)
                    }
                    .buttonStyle(.plain)
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
        .refreshable { await feed.refresh() }
        .task(id: Query(shelf: shelf, libraryID: libraryID)) {
            let service = session.service
            let library = libraryID
            let shelf = shelf
            feed.start { page in
                let query = BookQuery(libraryID: library, page: page, size: 40)
                return switch shelf {
                case .keepReading: try await service.keepReading(matching: query)
                case .onDeck: try await service.onDeck(matching: query)
                }
            }
        }
        .navigationDestination(for: KomgaBook.self) { book in
            BookDetailView(book: book)
        }
    }

    @ViewBuilder
    private var status: some View {
        if feed.phase == .loading {
            ProgressView()
        } else if let message = feed.phase.errorMessage, feed.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load \(shelf.title)", systemImage: "exclamationmark.triangle")
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

    private struct Query: Hashable {
        let shelf: Shelf
        let libraryID: String?
    }
}

/// A book on a shelf, where the series it belongs to is the useful context —
/// unlike a book in a series list, where it's already obvious.
struct BookCell: View {
    let book: KomgaBook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(target: .book(book.id))
                .overlay(alignment: .bottom) {
                    if let fraction = book.readState.fraction {
                        ReadProgressBar(fraction: fraction)
                    }
                }

            Text(book.seriesTitle.isEmpty ? book.displayTitle : book.seriesTitle)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(book.readState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.seriesTitle) \(book.displayTitle), \(book.readState.label)")
        .accessibilityIdentifier(AID.bookRow(book.id))
    }
}
