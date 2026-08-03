//
//  SeriesGridView.swift
//  Kontinuity
//
//  The cover grid: one library, or everything. Search and sort live here rather
//  than in a separate sidebar root — on an iPad the grid is already on screen,
//  and `.searchable` puts the field where the platform puts it.
//

import KontinuityCore
import SwiftUI

struct SeriesGridView: View {
    /// Nil browses every library the account can see.
    let libraryID: String?
    let title: String

    @Environment(KomgaSession.self) private var session
    @State private var feed = PagedFeed<KomgaSeries>()
    @State private var searchText = ""
    @State private var sort: SeriesSort = .title
    /// Nil shows every series regardless of read state.
    @State private var readFilter: KomgaReadStatus?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(feed.items) { series in
                    NavigationLink(value: series) {
                        SeriesCell(series: series)
                    }
                    .buttonStyle(.plain)
                    .onAppear { feed.loadMoreIfNeeded(currentItem: series) }
                }
            }
            .padding(20)

            if feed.phase == .loadingMore {
                ProgressView().padding(.bottom, 24)
            }
        }
        // `.searchable`'s floating bottom field (iPhone/compact width) isn't
        // reflected in a plain `ScrollView`'s own safe area the way it is for
        // `List`, so without this the last row's title sits behind it and its
        // tap target is unreachable (PLAN 6B §A). Sized generously rather than
        // to the field's exact height, which isn't published API.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 60)
        }
        .accessibilityIdentifier(AID.seriesGrid)
        .overlay { status }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search series")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Read status", selection: $readFilter) {
                        Text("All").tag(KomgaReadStatus?.none)
                        ForEach(KomgaReadStatus.allCases, id: \.self) { status in
                            Text(status.label).tag(KomgaReadStatus?.some(status))
                        }
                    }
                } label: {
                    Label(
                        "Filter",
                        systemImage: readFilter == nil
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SeriesSort.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                // Sorting is server-side, so it's meaningless while a search is
                // running — Komga orders those by relevance instead.
                .disabled(!searchText.trimmed.isEmpty)
            }
        }
        .refreshable { await feed.refresh() }
        // Re-runs on any of the four, and the 250ms only bites for search:
        // typing "air gear" would otherwise be eight round trips.
        .task(id: Query(libraryID: libraryID, search: searchText.trimmed, readFilter: readFilter, sort: sort)) {
            if !searchText.trimmed.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let service = session.service
            let library = libraryID
            let term = searchText.trimmed
            let filter = readFilter
            let order = sort
            feed.start { page in
                try await service.series(
                    matching: SeriesQuery(
                        libraryID: library,
                        searchTerm: term.isEmpty ? nil : term,
                        readStatus: filter.map { [$0] } ?? [],
                        sort: order,
                        page: page
                    )
                )
            }
        }
        .navigationDestination(for: KomgaSeries.self) { series in
            SeriesDetailView(series: series)
        }
        .navigationDestination(for: KomgaBook.self) { book in
            BookDetailView(book: book)
        }
    }

    /// The three states a grid can be in besides "showing series".
    @ViewBuilder
    private var status: some View {
        if feed.phase == .loading {
            ProgressView()
        } else if let message = feed.phase.errorMessage, feed.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load series", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { feed.retry() }
            }
            .accessibilityIdentifier(AID.browseError)
        } else if feed.isEmpty {
            let term = searchText.trimmed
            ContentUnavailableView(
                term.isEmpty && readFilter == nil ? "No series" : "No matches",
                systemImage: !term.isEmpty
                    ? "magnifyingglass"
                    : (readFilter == nil ? "books.vertical" : "line.3.horizontal.decrease.circle"),
                description: Text(emptyDescription(term: term))
            )
            .accessibilityIdentifier(AID.browseEmpty)
        }
    }

    private func emptyDescription(term: String) -> String {
        if !term.isEmpty {
            return "Nothing here matches “\(term)”."
        }
        if let readFilter {
            return "No series in this library are \(readFilter.label.lowercased())."
        }
        return "This library has nothing in it yet, or Komga is still scanning."
    }

    /// The inputs that should cause a reload, bundled so `.task(id:)` watches
    /// all four without four separate modifiers racing each other.
    private struct Query: Hashable {
        let libraryID: String?
        let search: String
        let readFilter: KomgaReadStatus?
        let sort: SeriesSort
    }
}

struct SeriesCell: View {
    let series: KomgaSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(target: .series(series.id))
                .overlay(alignment: .topTrailing) {
                    if series.booksUnreadCount > 0 {
                        UnreadBadge(count: series.booksUnreadCount)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if series.booksInProgressCount > 0 {
                        ReadProgressBar(fraction: progressFraction)
                    }
                }

            Text(series.displayTitle)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Combined, so VoiceOver reads a cell as one thing rather than three
        // fragments. That collapses the badge and the bar into this label —
        // which is why the unread count is spelled out in `subtitle` and asserted
        // there, rather than by looking for a badge element that no longer
        // exists once the children are merged.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(series.displayTitle), \(subtitle)")
        .accessibilityIdentifier(AID.seriesCell(series.id))
    }

    /// Books finished, as a share of the series — the same thing the badge
    /// counts down, drawn as a bar.
    private var progressFraction: Double {
        guard series.booksCount > 0 else { return 0 }
        return Double(series.booksReadCount) / Double(series.booksCount)
    }

    private var subtitle: String {
        let books = "\(series.booksCount) book\(series.booksCount == 1 ? "" : "s")"
        if series.isFullyRead {
            return "\(books) · Read"
        }
        if series.booksUnreadCount > 0 {
            return "\(books) · \(series.booksUnreadCount) unread"
        }
        return books
    }
}
