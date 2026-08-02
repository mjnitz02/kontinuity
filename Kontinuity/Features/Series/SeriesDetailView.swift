//
//  SeriesDetailView.swift
//  Kontinuity
//
//  Hero cover, metadata, and the books in reading order with their read state.
//  The "Download unread" affordance this screen is eventually built around
//  arrives in phase 5; its place is held here rather than left as a surprise.
//

import KontinuityCore
import SwiftUI

struct SeriesDetailView: View {
    /// The row the user tapped, shown immediately so the screen has a title and
    /// a cover before any request comes back.
    let series: KomgaSeries

    @Environment(KomgaSession.self) private var session
    @State private var feed = PagedFeed<KomgaBook>()
    /// Refreshed detail, which carries counts the grid's copy may have gone
    /// stale on. Falls back to the passed-in series until it lands.
    @State private var refreshed: KomgaSeries?

    private var current: KomgaSeries {
        refreshed ?? series
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                Divider()
                books
            }
            .padding(20)
        }
        .navigationTitle(current.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: series.id) {
            let service = session.service
            let sync = session.sync
            let id = series.id
            feed.start { page in
                try await service.books(inSeries: id, matching: BookQuery(page: page))
            }
            didReplace: { books in
                books.forEach { sync.reconcile(with: $0) }
            }
            refreshed = try? await service.series(id: id)
        }
    }

    // MARK: - Header

    private var header: some View {
        // Side-by-side on a regular-width iPad, which is the whole target; the
        // compact fallback is phase 7's problem but costs nothing to allow for.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                CoverImage(target: .series(current.id))
                    .frame(width: 220)
                metadata
            }
            VStack(alignment: .leading, spacing: 16) {
                CoverImage(target: .series(current.id))
                    .frame(maxWidth: 220)
                metadata
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.displayTitle)
                .font(.title.bold())
                .accessibilityIdentifier(AID.seriesDetailTitle)

            HStack(spacing: 8) {
                Text(bookCountSummary)
                if current.oneshot {
                    Text("Oneshot").badgeStyle()
                }
                if let status = statusLabel {
                    Text(status).badgeStyle()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !authors.isEmpty {
                Text(authors)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !summary.isEmpty {
                MarkdownText(raw: summary)
                    .font(.callout)
                    .accessibilityIdentifier(AID.seriesDetailSummary)
            }

            if !current.metadata.genres.isEmpty {
                Text(current.metadata.genres.sorted().joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                // Phase 5.
            } label: {
                Label("Download unread", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Downloads arrive in a later version.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Books

    private var books: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Books")
                .font(.title3.bold())

            if feed.phase == .loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let message = feed.phase.errorMessage, feed.items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load books", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { feed.retry() }
                }
            } else if feed.isEmpty {
                Text("This series has no books yet.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(feed.items) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book)
                        }
                        .buttonStyle(.plain)
                        .onAppear { feed.loadMoreIfNeeded(currentItem: book) }
                        Divider()
                    }
                }
                .accessibilityIdentifier(AID.seriesBookList)

                if feed.phase == .loadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 8)
                }
            }
        }
    }

    private func reload() async {
        await session.sync.flush()
        refreshed = try? await session.service.series(id: series.id)
        await feed.refresh()
    }

    // MARK: - Presentation

    private var bookCountSummary: String {
        let count = current.booksCount
        var text = "\(count) book\(count == 1 ? "" : "s")"
        // Komga knows the published total for many series, and "12 of 358" is
        // the difference between a gap in the library and a series still running.
        if let total = current.metadata.totalBookCount, total > count {
            text += " of \(total)"
        }
        if current.booksUnreadCount > 0 {
            text += " · \(current.booksUnreadCount) unread"
        }
        return text
    }

    private var statusLabel: String? {
        let status = current.metadata.status
        guard !status.isEmpty else { return nil }
        return status.capitalized
    }

    /// Komga aggregates every role across a series' books, so the same person
    /// appears six times. Writers first, de-duplicated, capped.
    private var authors: String {
        let writers = current.booksMetadata.authors.filter { $0.role == "writer" }
        let names = (writers.isEmpty ? current.booksMetadata.authors : writers).map(\.name)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.prefix(3).joined(separator: ", ")
    }

    private var summary: String {
        current.metadata.summary.isEmpty ? current.booksMetadata.summary : current.metadata.summary
    }
}

struct BookRow: View {
    let book: KomgaBook

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(target: .book(book.id))
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            ReadStateLabel(state: book.readState)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        // As with the grid cell: one element for VoiceOver, so the read state
        // lives in this label rather than in a separately queryable child.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.displayTitle), \(book.readState.label)")
        .accessibilityIdentifier(AID.bookRow(book.id))
    }

    private var details: String {
        var parts: [String] = []
        if !book.metadata.number.isEmpty {
            parts.append("#\(book.metadata.number)")
        }
        // An unanalysed book reports zero pages; saying "0 pages" reads like
        // corruption, so say what's actually happening instead.
        parts.append(book.isReadable ? "\(book.media.pagesCount) pages" : mediaNote)
        if !book.size.isEmpty {
            parts.append(book.size)
        }
        return parts.joined(separator: " · ")
    }

    private var mediaNote: String {
        switch book.media.status {
        case "READY": "Not a CBZ"
        case "ERROR": "Unreadable"
        default: "Not analysed yet"
        }
    }
}

private extension View {
    /// The small capped chips beside a series title.
    func badgeStyle() -> some View {
        font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }
}
