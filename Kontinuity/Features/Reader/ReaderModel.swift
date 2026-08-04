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
//  READER-DESIGN §1: a downloaded book reads purely from disk, no network at
//  all — `load()` checks `LocalBookStore` first and only falls back to the
//  network DIVINA manifest when the book isn't downloaded.
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
    private let downloads: DownloadCoordinator
    private let localStore = LocalBookStore()
    private let glassesSettings: GlassesSettings

    private(set) var pageSources: [PageSource] = []
    private(set) var spreads: [PageSpread] = []
    private(set) var loadError: String?
    private(set) var isLoading = true
    private(set) var nextBook: KomgaBook?
    /// Whether Mode A renders the paging `TabView` or the continuous scroll
    /// surface (PLAN §12) — resolved once at load time from
    /// `BandLayout.resolvedFlow`, the same decision Mode B's
    /// `GlassesCoordinator.enter()` makes, read off the same per-series
    /// override so the two never disagree.
    private(set) var flow: BandFlow = .perPage
    /// The page continuous mode should open on — computed alongside
    /// `currentSpreadIndex` from the same resolved start page, since a
    /// continuous scroll has no spread to land on.
    private(set) var initialPageIndex = 0

    private var localManifest: LocalBookManifest?
    private var remoteManifest: KomgaDivinaManifest?
    private var mode: LayoutMode = .fitPage
    private var hasLoadedInitialPosition = false
    private var lastSentPage: Int?

    var currentSpreadIndex: Int = 0 {
        didSet {
            guard oldValue != currentSpreadIndex, hasLoadedInitialPosition else { return }
            sendProgress()
        }
    }

    init(
        book: KomgaBook,
        service: any KomgaServing,
        sync: ProgressionSyncEngine,
        downloads: DownloadCoordinator,
        glassesSettings: GlassesSettings = GlassesSettings()
    ) {
        self.book = book
        self.service = service
        self.sync = sync
        self.downloads = downloads
        self.glassesSettings = glassesSettings
    }

    var pageCount: Int {
        pageSources.count
    }

    var isAtLastSpread: Bool {
        !spreads.isEmpty && currentSpreadIndex == spreads.count - 1
    }

    func load() async {
        isLoading = true
        loadError = nil

        if let localManifest = localStore.manifest(forBook: book.id) {
            self.localManifest = localManifest
            remoteManifest = nil
            pageSources = Self.localPageSources(bookID: book.id, manifest: localManifest, store: localStore)
            finishLoad()
            return
        }

        do {
            let manifest = try await service.divinaManifest(forBook: book.id)
            remoteManifest = manifest
            localManifest = nil
            pageSources = manifest.readingOrder.map { .remote($0) }
            finishLoad()
        } catch {
            loadError = (error as? KomgaError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }

    private func finishLoad() {
        recomputeSpreads()
        flow = BandLayout.resolvedFlow(
            for: pageGeometries,
            override: glassesSettings.flowOverride(forSeries: book.seriesId)
        )
        initialPageIndex = resolvedStartPageIndex()
        currentSpreadIndex = spreads.firstIndex { $0.pageIndices.contains(initialPageIndex) } ?? 0
        hasLoadedInitialPosition = true
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

    /// Mode A's own correction of `BandLayout.resolvedFlow`'s guess — the
    /// panel counterpart to `GlassesCoordinator.setFlow`, reading and writing
    /// the same per-series override so a correction made here is what glasses
    /// mode sees on its next entry, and vice versa. Position-preserving is
    /// `ReaderView`'s job (mirroring `exitGlassesModeToMatchingPage`), since
    /// this model has no notion of the continuous surface's scroll offset.
    func setFlow(_ newFlow: BandFlow) {
        guard newFlow != flow else { return }
        flow = newFlow
        glassesSettings.setFlowOverride(newFlow, forSeries: book.seriesId)
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
    /// engine's idle debounce — for the reader dismissing. Also the moment a
    /// just-finished, now-synced download becomes eligible for auto-remove
    /// (PLAN §6), so it rides along here too.
    func flushProgress() {
        Task {
            await sync.flush()
            downloads.reapAutoRemovable()
        }
    }

    // MARK: - Layout

    /// Also what Mode B's `BandLayout` computes against (`GlassesCoordinator.enter`)
    /// — glasses mode reuses whatever manifest this model already loaded
    /// rather than re-fetching.
    var pageGeometries: [PageGeometry] {
        if let localManifest {
            localManifest.pages.map { PageGeometry(width: Double($0.width ?? 0), height: Double($0.height ?? 0)) }
        } else if let remoteManifest {
            remoteManifest.readingOrder
                .map { PageGeometry(width: Double($0.width ?? 0), height: Double($0.height ?? 0)) }
        } else {
            []
        }
    }

    private func recomputeSpreads() {
        // TODO: read the series' reading direction once RTL is supported
        // (READER-DESIGN §1) — pinned to LTR everywhere for now.
        spreads = PageLayout.spreads(for: pageGeometries, mode: mode, progression: .ltr)
    }

    /// Resolves via the sync engine rather than trusting `book.readProgress`
    /// outright — that snapshot may be stale if this device has unsynced or
    /// conflicting local progress for the book (phase 4's whole point).
    ///
    /// A completed book always restarts at page 1 rather than resuming on its
    /// stored page — Komga's completion is implicit (`position == pagesCount`,
    /// KOMGA-API §4), so a "Read" book's stored page is the last page, and
    /// resuming there is indistinguishable from never letting the reader move
    /// past it (this is also what stranded the end-of-book advance: a "Read"
    /// next book opened already at its own last spread).
    private func resolvedStartPageIndex() -> Int {
        guard book.readState != .read else { return 0 }
        let resolvedPage = sync.resolvedStartPage(for: book) ?? book.readProgress?.page
        guard let page = resolvedPage, page > 1, pageCount > 0 else { return 0 }
        return min(page - 1, pageCount - 1)
    }

    // MARK: - Progress

    /// Records the page turn with the sync engine, which writes it locally at
    /// once and owns the debounced push from here (PLAN §5).
    private func sendProgress() {
        guard spreads.indices.contains(currentSpreadIndex),
              let lastPageIndex = spreads[currentSpreadIndex].pageIndices.max()
        else { return }
        recordProgress(pageIndex: lastPageIndex)
    }

    /// The progression entry point for both surfaces that have no discrete
    /// page turn to hang `currentSpreadIndex.didSet` off of: Mode B
    /// (READER-DESIGN §5, PLAN 6B §C gap 1), called when
    /// `GlassesCoordinator.currentBandIndex` reaches the **last** band of a
    /// page — bands don't correspond 1:1 with `spreads` — and Mode A's
    /// continuous scroll surface (PLAN §12), called on a debounced scroll
    /// offset. Shares `recordProgress` with the paged path, so `lastSentPage`
    /// de-duplication covers all three: re-entering a page or scrolling
    /// backward costs nothing extra.
    func recordPageRead(pageIndex: Int) {
        recordProgress(pageIndex: pageIndex)
    }

    private func recordProgress(pageIndex: Int) {
        guard pageSources.indices.contains(pageIndex) else { return }
        let page = pageIndex + 1
        guard lastSentPage != page else { return }
        lastSentPage = page

        let locator = progressionLocator(forPageIndex: pageIndex, page: page)
        sync.recordPageTurn(bookID: book.id, page: page, pageHref: locator.href, mediaType: locator.mediaType)
    }

    /// Komga stores but never validates the DIVINA locator's href/type
    /// against the manifest (KOMGA-API §4), so reading offline reconstructs
    /// the same href the network manifest would have given rather than
    /// needing one persisted on disk.
    private func progressionLocator(forPageIndex index: Int, page: Int) -> (href: String, mediaType: String) {
        switch pageSources[index] {
        case let .remote(link):
            (link.href, link.type)
        case let .local(_, mediaType):
            ("/opds/v2/books/\(book.id)/pages/\(page)?contentNegotiation=false", mediaType)
        }
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

    // MARK: - Local page sources

    private static func localPageSources(
        bookID: String,
        manifest: LocalBookManifest,
        store: LocalBookStore
    ) -> [PageSource] {
        manifest.pages.indices.compactMap { index in
            guard let url = store.pageURL(forBook: bookID, index: index) else { return nil }
            return .local(url: url, mediaType: manifest.pages[index].mediaType)
        }
    }
}
