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
        .accessibilityIdentifier(AID.seriesGrid)
        .overlay { status }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search series")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort", selection: $sort) {
                    ForEach(SeriesSort.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                // Sorting is server-side, so it's meaningless while a search is
                // running — Komga orders those by relevance instead.
                .disabled(!searchText.trimmed.isEmpty)
            }
        }
        .refreshable { await feed.refresh() }
        // Re-runs on any of the three, and the 250ms only bites for search:
        // typing "air gear" would otherwise be eight round trips.
        .task(id: Query(libraryID: libraryID, search: searchText.trimmed, sort: sort)) {
            if !searchText.trimmed.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let service = session.service
            let library = libraryID
            let term = searchText.trimmed
            let order = sort
            feed.start { page in
                try await service.series(
                    matching: SeriesQuery(
                        libraryID: library,
                        searchTerm: term.isEmpty ? nil : term,
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
            ContentUnavailableView(
                searchText.trimmed.isEmpty ? "No series" : "No matches",
                systemImage: searchText.trimmed.isEmpty ? "books.vertical" : "magnifyingglass",
                description: Text(
                    searchText.trimmed.isEmpty
                        ? "This library has nothing in it yet, or Komga is still scanning."
                        : "Nothing here matches “\(searchText.trimmed)”."
                )
            )
            .accessibilityIdentifier(AID.browseEmpty)
        }
    }

    /// The inputs that should cause a reload, bundled so `.task(id:)` watches
    /// all three without three separate modifiers racing each other.
    private struct Query: Hashable {
        let libraryID: String?
        let search: String
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
