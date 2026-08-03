//
//  SeriesDetailView.swift
//  Kontinuity
//
//  Hero cover, metadata, and the books in reading order with their read state.
//

import KontinuityCore
import SwiftData
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
    @State private var isEnqueuingDownloads = false
    /// Reading order (1, 2, 3…) vs. newest-first. Server-side, since the feed
    /// is paged and only some books may be loaded.
    @State private var ascending = true
    @Query private var bookRows: [Book]

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
        .task(id: FeedQuery(seriesID: series.id, ascending: ascending)) {
            let service = session.service
            let sync = session.sync
            let id = series.id
            let order = ascending
            feed.start { page in
                try await service.books(inSeries: id, matching: BookQuery(ascending: order, page: page))
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
                headerContent
            }
            VStack(alignment: .leading, spacing: 16) {
                CoverImage(target: .series(current.id))
                    .frame(maxWidth: 220)
                headerContent
            }
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        if isOfflineFallback {
            offlineMetadata
        } else {
            metadata
        }
    }

    /// No live series metadata while offline (PLAN §11) — no summary, genres,
    /// status, author line, or unread count, none of which this device has a
    /// cached answer for. Just the title (from the cached `seriesTitle`) and
    /// how much of it is actually here to read.
    private var offlineMetadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.displayTitle)
                .font(.title.bold())
                .accessibilityIdentifier(AID.seriesDetailTitle)

            Text("\(offlineBooks.count) downloaded")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.displayTitle)
                .font(.title.bold())
                .accessibilityIdentifier(AID.seriesDetailTitle)

            HStack(spacing: 8) {
                if let bookCountSummary {
                    Text(bookCountSummary)
                }
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

            downloadUnreadButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var downloadUnreadButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isEnqueuingDownloads = true
                Task {
                    await session.downloads.enqueueUnread(seriesID: series.id)
                    isEnqueuingDownloads = false
                }
            } label: {
                if isEnqueuingDownloads {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Download unread", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isEnqueuingDownloads || current.booksUnreadCount == 0)
            .accessibilityIdentifier(AID.seriesDownloadUnread)

            if activeDownloadCount > 0 {
                Text("Downloading \(activeDownloadCount) book\(activeDownloadCount == 1 ? "" : "s")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Counts against `bookRows` rather than `feed.items` — a download queued
    /// from this button keeps going after the user navigates away and back,
    /// and the SwiftData row is the thing that's actually still true then.
    private var activeDownloadCount: Int {
        let seriesBookIDs = Set(feed.items.map(\.id))
        return bookRows.filter {
            seriesBookIDs.contains($0.id) && [.queued, .downloading, .decompressing].contains($0.downloadState)
        }.count
    }

    // MARK: - Books

    private var books: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Books")
                    .font(.title3.bold())
                Spacer()
                sortOrderButton
            }

            if isOfflineFallback {
                offlineBookList
            } else if feed.phase == .loading {
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
                            BookRow(book: book, downloadState: downloadState(for: book.id))
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

    private var sortOrderButton: some View {
        Button {
            ascending.toggle()
        } label: {
            Label(
                ascending ? "Reading order" : "Newest first",
                systemImage: ascending ? "arrow.up" : "arrow.down"
            )
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityIdentifier(AID.seriesSortOrder)
    }

    private func reload() async {
        await session.flushAndReconcileDownloads()
        refreshed = try? await session.service.series(id: series.id)
        await feed.refresh()
    }

    private func downloadState(for bookID: String) -> DownloadState {
        bookRows.first { $0.id == bookID }?.downloadState ?? .notDownloaded
    }

    // MARK: - Offline fallback (PLAN §11)

    /// True once a request has failed offline-shaped and this series has at
    /// least one downloaded book to show instead. Reached with none (a stale
    /// deep link, say) falls straight through to the same error state as any
    /// other failed fetch — there's nothing to fall back to.
    private var isOfflineFallback: Bool {
        feed.phase.isOffline && !offlineBooks.isEmpty
    }

    /// `OfflineLibrary.books` decides which books and what order; this just
    /// resolves those ids back to the `Book` rows they came from — kept
    /// around as `Book`, not `KomgaBook`, since `offlineBookList` also needs
    /// `offlineReadState` off each row.
    private var offlineBookRows: [Book] {
        let ordered = OfflineLibrary.books(inSeries: series.id, from: bookRows.map(\.offlineSnapshot))
        let byID = Dictionary(uniqueKeysWithValues: bookRows.map { ($0.id, $0) })
        return ordered.compactMap { byID[$0.id] }
    }

    private var offlineBooks: [KomgaBook] {
        offlineBookRows.map(\.asKomgaBook)
    }

    /// A local sort, not a re-fetch — `OfflineLibrary.books` already returns
    /// reading order, so `ascending` only decides whether to reverse it.
    private var offlineBookList: some View {
        let rows = ascending ? offlineBookRows : Array(offlineBookRows.reversed())
        return LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                NavigationLink(value: row.asKomgaBook) {
                    BookRow(book: row.asKomgaBook, downloadState: .downloaded, readStateOverride: row.offlineReadState)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .accessibilityIdentifier(AID.seriesBookList)
    }

    // MARK: - Presentation

    /// Nil while the only thing on screen is a `KomgaSeries.reference` built
    /// from a book (`SeriesReference.swift`) — its counts are zeroes standing in
    /// for "not fetched yet", and "0 books" is a worse answer than no answer for
    /// the instant before the real row lands. A genuinely empty series says
    /// "0 books" once `refreshed` proves that's what it is.
    private var bookCountSummary: String? {
        let count = current.booksCount
        guard count > 0 || refreshed != nil else { return nil }
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

    /// What should cause the book feed to restart, bundled so `.task(id:)`
    /// watches both without two modifiers racing each other.
    private struct FeedQuery: Hashable {
        let seriesID: String
        let ascending: Bool
    }
}

struct BookRow: View {
    let book: KomgaBook
    var downloadState: DownloadState = .notDownloaded
    /// Overrides `book.readState` for an offline-reconstructed book, whose
    /// `readProgress` is deliberately nil (`Book.offlineReadState`'s doc
    /// comment) — the offline branches supply this instead.
    var readStateOverride: KomgaReadState?

    private var readState: KomgaReadState {
        readStateOverride ?? book.readState
    }

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

            if let downloadSymbol {
                Image(systemName: downloadSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ReadStateLabel(state: readState)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        // As with the grid cell: one element for VoiceOver, so the read state
        // — and the download state — live in this label rather than in a
        // separately queryable child (PLAN phase 2's lesson: `.combine`
        // removes child elements from the tree, so a badge inside couldn't be
        // queried on its own anyway).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AID.bookRow(book.id))
    }

    private var accessibilityLabel: String {
        var label = "\(book.displayTitle), \(readState.label)"
        if let downloadLabel {
            label += ", \(downloadLabel)"
        }
        return label
    }

    private var downloadSymbol: String? {
        switch downloadState {
        case .notDownloaded, .failed: nil
        case .queued, .downloading, .decompressing: "arrow.down.circle"
        case .downloaded: "checkmark.circle.fill"
        }
    }

    private var downloadLabel: String? {
        switch downloadState {
        case .notDownloaded: nil
        case .queued: "Queued for download"
        case .downloading, .decompressing: "Downloading"
        case .downloaded: "Downloaded"
        case .failed: "Download failed"
        }
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
