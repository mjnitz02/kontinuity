//
//  ReaderModel.swift
//  Kontinuity
//
//  Owns the manifest and the current position. Progress sync itself — the
//  outbox, the debounce, the 409/offline handling — lives in
//  `ProgressionSyncEngine` (phase 4); this model just records page turns into
//  it and asks it to resolve where to resume, rather than trusting whatever
//  `book.readProgress` happened to be when this screen was reached.
//

import KontinuityCore
import Observation
import SwiftUI

@MainActor
@Observable
final class ReaderModel {
    let book: KomgaBook
    private let service: any KomgaServing
    private let sync: ProgressionSyncEngine

    private(set) var manifest: KomgaDivinaManifest?
    private(set) var spreads: [PageSpread] = []
    private(set) var loadError: String?
    private(set) var isLoading = true
    private(set) var nextBook: KomgaBook?

    private var mode: LayoutMode = .fitPage
    private var hasLoadedInitialPosition = false
    private var lastSentPage: Int?

    var currentSpreadIndex: Int = 0 {
        didSet {
            guard oldValue != currentSpreadIndex, hasLoadedInitialPosition else { return }
            sendProgress()
        }
    }

    init(book: KomgaBook, service: any KomgaServing, sync: ProgressionSyncEngine) {
        self.book = book
        self.service = service
        self.sync = sync
    }

    var pageCount: Int {
        manifest?.readingOrder.count ?? 0
    }

    var isAtLastSpread: Bool {
        !spreads.isEmpty && currentSpreadIndex == spreads.count - 1
    }

    func load() async {
        isLoading = true
        loadError = nil
        do {
            let manifest = try await service.divinaManifest(forBook: book.id)
            self.manifest = manifest
            recomputeSpreads()
            currentSpreadIndex = initialSpreadIndex()
            hasLoadedInitialPosition = true
        } catch {
            loadError = (error as? KomgaError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// Re-paginates for a container size change (portrait ↔ landscape),
    /// preserving the page the reader was looking at rather than resetting to
    /// the start.
    func updateLayout(for containerSize: CGSize) {
        let newMode: LayoutMode = containerSize.width > containerSize.height ? .spread : .fitPage
        guard newMode != mode else { return }
        mode = newMode

        let currentPage = spreads.indices.contains(currentSpreadIndex) ? spreads[currentSpreadIndex].pageIndices
            .first : nil
        recomputeSpreads()
        if let currentPage, let newIndex = spreads.firstIndex(where: { $0.pageIndices.contains(currentPage) }) {
            currentSpreadIndex = newIndex
        }
    }

    func advance() {
        guard currentSpreadIndex < spreads.count - 1 else { return }
        currentSpreadIndex += 1
    }

    func retreat() {
        guard currentSpreadIndex > 0 else { return }
        currentSpreadIndex -= 1
    }

    /// Pushes any unpushed progress immediately rather than waiting for the
    /// engine's idle debounce — for the reader dismissing.
    func flushProgress() {
        Task { await sync.flush() }
    }

    // MARK: - Layout

    private func recomputeSpreads() {
        guard let manifest else { return }
        let pages = manifest.readingOrder.map {
            PageGeometry(width: Double($0.width ?? 0), height: Double($0.height ?? 0))
        }
        // TODO: read the series' reading direction once RTL is supported
        // (READER-DESIGN §1) — pinned to LTR everywhere for now.
        spreads = PageLayout.spreads(for: pages, mode: mode, progression: .ltr)
    }

    /// Resolves via the sync engine rather than trusting `book.readProgress`
    /// outright — that snapshot may be stale if this device has unsynced or
    /// conflicting local progress for the book (phase 4's whole point).
    private func initialSpreadIndex() -> Int {
        let resolvedPage = sync.resolvedStartPage(for: book) ?? book.readProgress?.page
        guard let page = resolvedPage, page > 1, pageCount > 0 else { return 0 }
        let pageIndex = min(page - 1, pageCount - 1)
        return spreads.firstIndex { $0.pageIndices.contains(pageIndex) } ?? 0
    }

    // MARK: - Progress

    /// Records the page turn with the sync engine, which writes it locally at
    /// once and owns the debounced push from here (PLAN §5).
    private func sendProgress() {
        guard let manifest,
              spreads.indices.contains(currentSpreadIndex),
              let lastPageIndex = spreads[currentSpreadIndex].pageIndices.max(),
              manifest.readingOrder.indices.contains(lastPageIndex)
        else { return }

        let page = lastPageIndex + 1
        guard lastSentPage != page else { return }
        lastSentPage = page

        let link = manifest.readingOrder[lastPageIndex]
        sync.recordPageTurn(bookID: book.id, page: page, pageHref: link.href, mediaType: link.type)
    }

    // MARK: - Edge of book

    /// Resolves the next volume in the series, once, for the "swiping past the
    /// last page" affordance (READER-DESIGN §2). A full ordered fetch rather
    /// than an incremental one — fine for a home library, and simpler than
    /// trying to page around a known id.
    func loadNextBookIfNeeded() async {
        guard nextBook == nil else { return }
        guard let page = try? await service.books(inSeries: book.seriesId, matching: BookQuery(size: 500))
        else { return }
        let ordered = page.content.sorted { $0.metadata.numberSort < $1.metadata.numberSort }
        guard let currentIndex = ordered.firstIndex(where: { $0.id == book.id }) else { return }
        let nextIndex = ordered.index(after: currentIndex)
        nextBook = ordered.indices.contains(nextIndex) ? ordered[nextIndex] : nil
    }
}
