//
//  PagedFeed.swift
//  Kontinuity
//
//  Every browse screen is the same shape: fetch page 0, append pages as the user
//  scrolls, and be refreshable. Writing that three times would mean three
//  slightly different answers to "what happens when a refresh lands while page 4
//  is in flight", so it lives here once.
//

import Foundation
import KontinuityCore
import SwiftUI

enum FeedPhase: Equatable {
    /// Nothing requested yet.
    case idle
    /// First page in flight, nothing on screen.
    case loading
    case loaded
    /// A further page in flight; the items already shown stay put.
    case loadingMore
    /// `isOffline` mirrors `KomgaError.isOffline` on whatever failed the
    /// request — an offline-classified browse screen falls back to a
    /// locally-derived view instead of this error; a 401 or 500
    /// still shows it as-is.
    case failed(String, isOffline: Bool)

    var errorMessage: String? {
        if case let .failed(message, _) = self {
            return message
        }
        return nil
    }

    var isOffline: Bool {
        if case let .failed(_, offline) = self {
            return offline
        }
        return false
    }
}

@MainActor
@Observable
final class PagedFeed<Element: Identifiable & Hashable & Sendable & Decodable> {
    private(set) var items: [Element] = []
    private(set) var phase: FeedPhase = .idle
    /// What the server says the whole list totals, which is worth showing even
    /// when only the first page has arrived.
    private(set) var totalCount = 0

    private var fetch: ((Int) async throws -> KomgaPage<Element>)?
    /// Called with every fully-replaced page 0, not on a "load more" append —
    /// what a manual refresh means for reconciling read progress across
    /// what's in view. `PagedFeed` doesn't know what a `KomgaBook` is,
    /// so it just hands the items back to whoever does.
    private var didReplace: (([Element]) -> Void)?
    private var nextPage: Int?
    private var task: Task<Void, Never>?

    var isEmpty: Bool {
        items.isEmpty && phase == .loaded
    }

    /// Points the feed at a query and loads its first page. Calling this with a
    /// new query replaces everything — switching library must not leave the
    /// previous library's covers on screen.
    func start(
        _ fetch: @escaping (Int) async throws -> KomgaPage<Element>,
        didReplace: (([Element]) -> Void)? = nil
    ) {
        self.fetch = fetch
        self.didReplace = didReplace
        items = []
        totalCount = 0
        nextPage = nil
        load(page: 0, replacing: true)
    }

    /// Re-fetches page 0 and discards anything past it. Deliberately not a
    /// merge: after a pull-to-refresh the list should match the server, and
    /// stitching a fresh page 0 onto stale later pages is how duplicates and
    /// phantom rows appear.
    func refresh() async {
        guard fetch != nil else { return }
        load(page: 0, replacing: true)
        await task?.value
    }

    /// Called as cells appear. Fires only near the end of what's loaded, so a
    /// fast scroll doesn't queue a page per row.
    func loadMoreIfNeeded(currentItem: Element) {
        guard let nextPage, phase == .loaded else { return }
        let threshold = max(0, items.count - 8)
        guard let index = items.firstIndex(of: currentItem), index >= threshold else { return }
        load(page: nextPage, replacing: false)
    }

    func retry() {
        load(page: nextPage ?? 0, replacing: items.isEmpty)
    }

    private func load(page: Int, replacing: Bool) {
        guard let fetch else { return }
        // A newer request always wins. Without this, a refresh started while
        // page 4 was in flight would have page 4's results appended after the
        // refresh replaced the list.
        task?.cancel()
        phase = replacing ? .loading : .loadingMore

        task = Task {
            do {
                let result = try await fetch(page)
                guard !Task.isCancelled else { return }

                if replacing {
                    items = result.content
                    didReplace?(result.content)
                } else {
                    // Komga pages a live query: a scan finishing mid-scroll can
                    // shift items across page boundaries and hand us one twice.
                    let known = Set(items.map(\.id))
                    items += result.content.filter { !known.contains($0.id) }
                }
                totalCount = result.totalElements
                nextPage = result.nextPage
                phase = .loaded
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // A failed *further* page shouldn't blank a list the user is
                // reading; keep the items and report the failure alongside.
                let isOffline = (error as? KomgaError)?.isOffline ?? false
                phase = .failed(error.userMessage, isOffline: isOffline)
            }
        }
    }
}
