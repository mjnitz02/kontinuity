//
//  ProgressionSyncEngine.swift
//  Kontinuity
//
//  The impure half of PLAN §5's sync design: persists `Book` rows and talks to
//  `KomgaServing`, deferring every actual decision to the pure
//  `ProgressionSync.reconcile` in KontinuityCore. Same split as
//  `ReaderModel`/`PageLayout` — the policy is provable without a simulator,
//  the orchestration around it isn't.
//

import Foundation
import KontinuityCore
import Network
import Observation
import SwiftData

@MainActor
@Observable
final class ProgressionSyncEngine {
    private let service: any KomgaServing
    private let modelContext: ModelContext
    private let device: KomgaDevice

    /// The most recent "both sides moved" event, for a small non-modal note
    /// (PLAN §5) — never silently discarding a position is the whole point of
    /// this phase. Self-clears a few seconds after being set.
    private(set) var conflictNotice: ConflictNotice?

    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var pathMonitor: NWPathMonitor?
    private var monitorTask: Task<Void, Never>?
    private var networkWasSatisfied = true

    init(service: any KomgaServing, modelContext: ModelContext, device: KomgaDevice) {
        self.service = service
        self.modelContext = modelContext
        self.device = device
        startNetworkMonitor()
    }

    // MARK: - Recording (PLAN §5: local writes are authoritative and immediate)

    /// Writes the new position synchronously — the reader never awaits the
    /// network, not even while streaming — then schedules a debounced flush.
    func recordPageTurn(bookID: String, page: Int, pageHref: String, mediaType: String, at date: Date = .now) {
        let book = fetchOrCreate(bookID: bookID)
        book.localPage = page
        book.localReadDate = date
        book.pageHref = pageHref
        book.mediaType = mediaType
        book.isPending = true
        try? modelContext.save()
        scheduleFlush()
    }

    /// Called after the detail screen's explicit read/unread toggle pushes to
    /// Komga — updates the local row directly rather than through
    /// `reconcile`, since a `DELETE read-progress` collapses the server side
    /// back to "never opened" (nil), a state `ProgressionSync.reconcile`
    /// can't tell apart from "no local row has ever pushed" and would
    /// therefore leave stale. No-op when this device has no row for the book
    /// at all — nothing here needs resetting, and the next fetch already
    /// carries the real server state.
    func applyExplicitReadState(bookID: String, read: Bool, pagesCount: Int, at date: Date = .now) {
        guard let existing = fetchExisting(bookID: bookID) else { return }
        existing.localPage = read ? pagesCount : 0
        existing.localReadDate = date
        existing.serverPage = read ? pagesCount : nil
        existing.serverReadDate = read ? date : nil
        existing.isPending = false
        try? modelContext.save()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    // MARK: - Flush

    /// Pushes every pending row. Safe to call from several triggers at once
    /// (dismiss, backgrounding, reconnect, manual refresh) — a flush already
    /// in flight is left alone rather than doubled up.
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        flushTask?.cancel()
        flushTask = nil

        for book in fetchPending() {
            do {
                let write = ProgressionWrite(
                    page: book.localPage,
                    pageHref: book.pageHref,
                    mediaType: book.mediaType,
                    readDate: book.localReadDate
                )
                try await service.putProgression(bookID: book.id, write: write, device: device)
                book.isPending = false
                book.serverPage = book.localPage
                book.serverReadDate = book.localReadDate
            } catch KomgaError.conflict {
                // The clock guard rejected us: the server is ahead. Never
                // retry — that loops forever (PLAN §5) — so clear the pending
                // flag unconditionally, then best-effort adopt the real
                // value. If the follow-up fetch also fails, the next
                // `reconcile(with:)` call corrects it.
                book.isPending = false
                if let fresh = try? await service.book(id: book.id), let progress = fresh.readProgress {
                    book.localPage = progress.page
                    book.localReadDate = progress.readDate
                    book.serverPage = progress.page
                    book.serverReadDate = progress.readDate
                }
            } catch {
                if (error as? KomgaError)?.isOffline == true {
                    // The rest of the queue will fail the same way.
                    break
                }
                // Anything else: leave pending, retry on the next trigger.
            }
        }
        try? modelContext.save()
    }

    // MARK: - Reconciliation

    /// Reconciles a freshly-fetched `KomgaBook` against this device's local
    /// row, if it has one. Free of any extra network call — `readProgress`
    /// already rode along on whatever fetch produced `book` (KOMGA-API §3).
    func reconcile(with book: KomgaBook) {
        guard let existing = fetchExisting(bookID: book.id) else { return }
        let local = LocalProgress(
            page: existing.localPage,
            readDate: existing.localReadDate,
            serverPage: existing.serverPage,
            serverReadDate: existing.serverReadDate,
            isPending: existing.isPending
        )

        switch ProgressionSync.reconcile(local: local, server: book.readProgress) {
        case .noChange, .pushLocal:
            break

        case let .adoptServer(page, readDate):
            existing.localPage = page
            existing.localReadDate = readDate
            existing.serverPage = page
            existing.serverReadDate = readDate
            existing.isPending = false

        case let .bothMoved(winner, page, readDate):
            applyBothMoved(winner: winner, page: page, readDate: readDate, book: book, row: existing)
            publishConflictNotice(bookID: book.id, resolvedPage: page, wonByLocal: winner == .local)
            scheduleFlush()
        }

        try? modelContext.save()
    }

    /// Reconciles `book`, then returns the page this device should resume
    /// at. Nil when there's no local row at all — the caller should fall back
    /// to `book.readProgress` directly, since nothing here has ever diverged
    /// from the server.
    func resolvedStartPage(for book: KomgaBook) -> Int? {
        reconcile(with: book)
        return fetchExisting(bookID: book.id)?.localPage
    }

    private func applyBothMoved(
        winner: SyncOutcome.Side,
        page: Int,
        readDate: Date,
        book: KomgaBook,
        row: Book
    ) {
        switch winner {
        case .server:
            row.localPage = page
            row.localReadDate = readDate
            row.serverPage = page
            row.serverReadDate = readDate
            row.isPending = false
        case .local:
            // Reconciliation decided local wins regardless of raw clock
            // order; bump the timestamp so the eventual push satisfies
            // Komga's monotonic guard instead of 409-ing against a decision
            // already made here (KOMGA-API §4).
            if let serverReadDate = book.readProgress?.readDate, row.localReadDate <= serverReadDate {
                row.localReadDate = serverReadDate.addingTimeInterval(1)
            }
            row.isPending = true
        }
    }

    private func publishConflictNotice(bookID: String, resolvedPage: Int, wonByLocal: Bool) {
        let notice = ConflictNotice(bookID: bookID, resolvedPage: resolvedPage, resolvedToLocal: wonByLocal)
        conflictNotice = notice
        Task {
            try? await Task.sleep(for: .seconds(6))
            if conflictNotice?.id == notice.id {
                conflictNotice = nil
            }
        }
    }

    // MARK: - Fetch helpers

    /// Filters in plain Swift rather than a `#Predicate` — a library's worth
    /// of `Book` rows is small, and fetching the lot sidesteps a real crash
    /// observed in SwiftData's predicate compilation when several in-memory
    /// containers are queried concurrently (a test-harness scenario; a real
    /// app session only ever has one, but the fetch shape shouldn't depend on
    /// that).
    private func allBooks() -> [Book] {
        (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
    }

    private func fetchExisting(bookID: String) -> Book? {
        allBooks().first { $0.id == bookID }
    }

    private func fetchOrCreate(bookID: String) -> Book {
        if let existing = fetchExisting(bookID: bookID) {
            return existing
        }
        let book = Book(id: bookID, localPage: 0, localReadDate: .now, pageHref: "", mediaType: "")
        modelContext.insert(book)
        return book
    }

    private func fetchPending() -> [Book] {
        allBooks().filter(\.isPending)
    }

    // MARK: - Network regained (PLAN §5's fifth flush trigger)

    /// Piped through an `AsyncStream` rather than capturing `self` in
    /// `pathUpdateHandler` directly — that closure's type is `@Sendable` and
    /// runs on the monitor's own queue, so reaching back into this
    /// `@MainActor` instance from inside it is exactly the kind of unsafe
    /// cross-actor capture the compiler warns about. Only a `Bool` crosses
    /// the boundary; reacting to it happens back on `MainActor`.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        monitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "kontinuity.progressionSync.pathMonitor"))
        pathMonitor = monitor

        monitorTask = Task { @MainActor in
            for await satisfied in stream {
                handlePathUpdate(satisfied: satisfied)
            }
        }
    }

    private func handlePathUpdate(satisfied: Bool) {
        defer { networkWasSatisfied = satisfied }
        guard satisfied, !networkWasSatisfied else { return }
        Task { await flush() }
    }
}

/// A small, non-modal "your progress on another device won and we kept it"
/// or "-and we kept yours-" event, per PLAN §5's "say so" requirement.
struct ConflictNotice: Equatable, Identifiable {
    let id = UUID()
    let bookID: String
    let resolvedPage: Int
    let resolvedToLocal: Bool
}
