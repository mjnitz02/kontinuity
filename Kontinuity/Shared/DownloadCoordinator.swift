//
//  DownloadCoordinator.swift
//  Kontinuity
//
//  The impure half of PLAN §6's download design — mirrors the
//  ProgressionSync/ProgressionSyncEngine split: `CBZArchive`, `LocalBookStore`
//  and `DownloadRetention` in KontinuityCore hold every decision that's
//  provable without a simulator; this owns the queue, the SwiftData
//  persistence, and the `URLSession` that talks to Komga.
//
//  Whole-file transfers ride a dedicated `URLSession` (background in
//  production, ephemeral under `-UITestMode`) rather than the service's own
//  session, because a background transfer needs its own delegate lifecycle
//  that survives app suspension — the whole point of PLAN §6's "URLSession
//  background configuration" decision. `KomgaServing.fileDownloadRequest`
//  keeps the auth header logic in one place regardless of which session ends
//  up sending it.
//

import Foundation
import KontinuityCore
import Observation
import SwiftData

@MainActor
@Observable
final class DownloadCoordinator: NSObject {
    private let service: any KomgaServing
    private let modelContext: ModelContext
    private let store: LocalBookStore
    private let settings: DownloadSettings
    private let maxConcurrent = 3

    private var session: URLSession!
    private let eventStream: AsyncStream<DownloadEvent>
    private let eventContinuation: AsyncStream<DownloadEvent>.Continuation

    private var pendingQueue: [String] = []
    private var activeCount = 0
    private var tasksByBookID: [String: URLSessionDownloadTask] = [:]
    private var waiters: [String: CheckedContinuation<URL, Error>] = [:]

    /// Set by the reader while a book is open, so retention and auto-remove
    /// never delete files out from under the person reading them.
    var openBookID: String?

    /// A "couldn't free enough space" note for the Downloads screen — set
    /// when retention's pending/open exclusions leave the library still over
    /// the cap (PLAN §6: pause and say so, don't thrash).
    private(set) var retentionWarning: String?

    init(
        service: any KomgaServing,
        modelContext: ModelContext,
        store: LocalBookStore = LocalBookStore(),
        settings: DownloadSettings = DownloadSettings(),
        sessionConfiguration: URLSessionConfiguration
    ) {
        self.service = service
        self.modelContext = modelContext
        self.store = store
        self.settings = settings
        (eventStream, eventContinuation) = AsyncStream<DownloadEvent>.makeStream()
        super.init()
        session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
        startEventLoop()

        // Snapshotted synchronously, before any `await` — otherwise a book
        // `enqueue`d moments after construction (very plausible: "Download
        // unread" tapped right after launch) could still be `.queued` when
        // `reconcileAfterLaunch`'s first `await` finally yields back, and get
        // mistaken for a stale row left behind by a killed process, starting
        // a second concurrent download of the same book.
        let staleBookIDs = allBooks()
            .filter { $0.downloadState == .downloading || $0.downloadState == .queued }
            .map(\.id)
        Task { await reconcileAfterLaunch(candidateBookIDs: staleBookIDs) }
    }

    // MARK: - Enqueueing

    /// The headline gesture (PLAN §6): every unread, readable book in the
    /// series, in reading order — `books(inSeries:)` already sorts by
    /// `metadata.numberSort`.
    func enqueueUnread(seriesID: String) async {
        guard let page = try? await service.books(
            inSeries: seriesID,
            matching: BookQuery(readStatus: [.unread], size: 500)
        ) else { return }
        for book in page.content where book.isReadable {
            enqueue(book: book)
        }
    }

    func enqueue(book: KomgaBook) {
        let row = fetchOrCreate(bookID: book.id)
        guard row.downloadState == .notDownloaded || row.downloadState == .failed else { return }
        row.seriesID = book.seriesId
        row.seriesTitle = book.seriesTitle
        row.title = book.displayTitle
        row.number = book.metadata.number
        row.numberSort = book.metadata.numberSort
        row.pagesCount = book.media.pagesCount
        row.sizeBytes = book.sizeBytes
        row.downloadState = .queued
        row.downloadError = nil
        try? modelContext.save()
        pendingQueue.append(book.id)
        pumpQueue()
    }

    func cancel(bookID: String) {
        tasksByBookID.removeValue(forKey: bookID)?.cancel()
        waiters.removeValue(forKey: bookID)?.resume(throwing: CancellationError())
        pendingQueue.removeAll { $0 == bookID }
        guard let book = fetchExisting(bookID: bookID) else { return }
        book.downloadState = .notDownloaded
        book.downloadedBytes = 0
        book.expectedBytes = 0
        try? modelContext.save()
    }

    /// Deletes a downloaded book's files — a user-initiated remove, an
    /// eviction, or auto-remove-on-finish all funnel through this. The
    /// metadata cache is left alone: "the UI shows downloaded-vs-cloud state
    /// per book" (PLAN §6) needs a title to show even after the files are gone.
    func remove(bookID: String) {
        cancel(bookID: bookID)
        try? store.deleteBook(bookID)
        guard let book = fetchExisting(bookID: bookID) else { return }
        book.downloadState = .notDownloaded
        book.downloadedDate = nil
        book.downloadedBytes = 0
        book.expectedBytes = 0
        try? modelContext.save()
    }

    // MARK: - Queue

    private func pumpQueue() {
        while activeCount < maxConcurrent, !pendingQueue.isEmpty {
            let bookID = pendingQueue.removeFirst()
            guard let book = fetchExisting(bookID: bookID), book.downloadState == .queued else { continue }
            start(bookID: book.id)
        }
    }

    private func start(bookID: String) {
        guard let book = fetchExisting(bookID: bookID) else { return }
        book.downloadState = .downloading
        book.downloadError = nil
        try? modelContext.save()
        activeCount += 1

        Task {
            do {
                let manifest = try await service.divinaManifest(forBook: bookID)
                do {
                    let fileURL = try await downloadWholeFile(bookID: bookID)
                    try extractAndStore(fileURL: fileURL, manifest: manifest, bookID: bookID)
                } catch DownloadTransportError.forbidden {
                    try await downloadPerPage(bookID: bookID, manifest: manifest)
                } catch is CBZArchiveError {
                    try await downloadPerPage(bookID: bookID, manifest: manifest)
                } catch DownloadPipelineError.pageCountMismatch {
                    try await downloadPerPage(bookID: bookID, manifest: manifest)
                }
                finishSuccess(bookID: bookID)
            } catch {
                finishFailure(bookID: bookID, error: error)
            }
            activeCount -= 1
            tasksByBookID.removeValue(forKey: bookID)
            pumpQueue()
        }
    }

    private func finishSuccess(bookID: String) {
        guard let book = fetchExisting(bookID: bookID) else { return }
        book.downloadState = .downloaded
        book.downloadedDate = .now
        book.downloadedBytes = store.diskUsage(forBook: bookID)
        book.downloadError = nil
        try? modelContext.save()
        Task { await applyRetention() }
    }

    private func finishFailure(bookID: String, error: Error) {
        guard let book = fetchExisting(bookID: bookID) else { return }
        book.downloadState = .failed
        book.downloadError = (error as? KomgaError)?.errorDescription ?? error.localizedDescription
        try? modelContext.save()
    }

    // MARK: - Whole-file path

    private func downloadWholeFile(bookID: String) async throws -> URL {
        let request = service.fileDownloadRequest(forBook: bookID)
        let task = session.downloadTask(with: request)
        task.taskDescription = bookID
        tasksByBookID[bookID] = task
        return try await withCheckedThrowingContinuation { continuation in
            waiters[bookID] = continuation
            task.resume()
        }
    }

    /// Positional zip against the manifest's `readingOrder`, not the archive's
    /// own filenames — `CBZArchive` already put pages in natural order, and
    /// the manifest is the authoritative source for each page's width/height/
    /// type (KOMGA-API §2), fetched moments earlier rather than re-derived.
    private func extractAndStore(fileURL: URL, manifest: KomgaDivinaManifest, bookID: String) throws {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let data = try Data(contentsOf: fileURL)
        let pages = try CBZArchive.extractImagePages(from: data)
        guard !pages.isEmpty, pages.count == manifest.readingOrder.count else {
            throw DownloadPipelineError.pageCountMismatch
        }
        let writes = zip(pages, manifest.readingOrder).map { data, link in
            LocalPageWrite(data: data, width: link.width, height: link.height, mediaType: link.type)
        }
        try store.write(pages: writes, bookID: bookID)
    }

    // MARK: - Per-page fallback (403, PLAN §6)

    /// Slower but always works on a restricted account. Prefers the
    /// manifest's `alternate` link outright — unlike the reader's
    /// decode-and-fall-back approach, the download already knows up front
    /// which pages Komga flagged as non-recommended (KOMGA-API §5).
    private func downloadPerPage(bookID: String, manifest: KomgaDivinaManifest) async throws {
        var writes: [LocalPageWrite] = []
        writes.reserveCapacity(manifest.readingOrder.count)
        for link in manifest.readingOrder {
            let href = link.alternate.first?.href ?? link.href
            let data = try await service.pageImageData(at: href)
            writes.append(LocalPageWrite(data: data, width: link.width, height: link.height, mediaType: link.type))
            if let book = fetchExisting(bookID: bookID) {
                book.downloadedBytes = Int64(writes.reduce(0) { $0 + $1.data.count })
            }
        }
        try store.write(pages: writes, bookID: bookID)
    }

    // MARK: - Retention (PLAN §6)

    func applyRetention() async {
        let downloaded = allBooks().filter { $0.downloadState == .downloaded }
        let usedBytes = downloaded.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        let candidates = downloaded.map {
            RetentionCandidate(
                bookID: $0.id,
                sizeBytes: $0.downloadedBytes,
                lastActivityDate: $0.lastActivityDate,
                isPending: $0.isPending,
                isOpen: $0.id == openBookID
            )
        }
        let result = DownloadRetention.plan(
            candidates: candidates,
            usedBytes: usedBytes,
            capBytes: settings.storageCapBytes
        )
        for bookID in result.toEvict {
            remove(bookID: bookID)
        }
        retentionWarning = result.insufficientSpace
            ? "The storage limit is reached and everything downloaded is either open or has unsynced "
            + "progress. Raise the limit in Downloads or free it up by hand."
            : nil
    }

    /// A book counts as finished once its last-known local page reaches the
    /// page count *and* nothing is still queued to sync — "confirmed synced",
    /// not just "read", is what makes deleting the files safe (PLAN §6).
    func reapAutoRemovable() {
        guard settings.autoRemoveOnFinish else { return }
        for book in allBooks() {
            guard book.downloadState == .downloaded,
                  !book.isPending,
                  book.id != openBookID,
                  let pages = book.pagesCount, pages > 0,
                  book.localPage >= pages
            else { continue }
            remove(bookID: book.id)
        }
    }

    // MARK: - Launch reconciliation

    /// Re-attaches to any background tasks the OS kept alive across a
    /// relaunch; anything among `candidateBookIDs` with no live task just
    /// restarts, which is the honest thing to do rather than guessing at
    /// partial progress from a killed process (PLAN §6). `candidateBookIDs`
    /// is a snapshot taken before this method's first `await`, so a book
    /// `enqueue`d in the meantime is never mistaken for one of these.
    private func reconcileAfterLaunch(candidateBookIDs: [String]) async {
        guard !candidateBookIDs.isEmpty else { return }

        let existingTasks = await session.allTasks
        var liveBookIDs: Set<String> = []
        for task in existingTasks {
            guard let bookID = task.taskDescription,
                  let downloadTask = task as? URLSessionDownloadTask else { continue }
            tasksByBookID[bookID] = downloadTask
            liveBookIDs.insert(bookID)
        }

        for bookID in candidateBookIDs {
            guard !liveBookIDs.contains(bookID),
                  !pendingQueue.contains(bookID),
                  tasksByBookID[bookID] == nil,
                  let book = fetchExisting(bookID: bookID),
                  book.downloadState == .downloading || book.downloadState == .queued
            else { continue }
            book.downloadState = .queued
            pendingQueue.append(bookID)
        }
        try? modelContext.save()
        pumpQueue()
    }

    // MARK: - Event bridge

    /// Delegate methods run on the session's own queue and must not touch
    /// `self` directly — same reasoning as `ProgressionSyncEngine`'s
    /// `NWPathMonitor` bridge. Only `Sendable` payloads cross into this
    /// stream; everything that reads coordinator state happens back here on
    /// the main actor.
    private func startEventLoop() {
        Task { @MainActor [eventStream] in
            for await event in eventStream {
                handle(event)
            }
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case let .progress(bookID, received, expected):
            guard let book = fetchExisting(bookID: bookID) else { return }
            book.downloadedBytes = received
            if expected > 0 {
                book.expectedBytes = expected
            }

        case let .finished(bookID, fileURL):
            waiters.removeValue(forKey: bookID)?.resume(returning: fileURL)

        case let .failed(bookID, statusCode, error):
            guard let continuation = waiters.removeValue(forKey: bookID) else { return }
            if statusCode == 403 {
                continuation.resume(throwing: DownloadTransportError.forbidden)
            } else if let statusCode {
                continuation.resume(throwing: DownloadTransportError.status(statusCode))
            } else {
                continuation.resume(throwing: error ?? URLError(.unknown))
            }
        }
    }

    // MARK: - Fetch helpers (mirrors ProgressionSyncEngine's — Book is shared,

    // but the two engines are deliberately not coupled to each other)

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
}

// MARK: - URLSessionDownloadDelegate

extension DownloadCoordinator: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let bookID = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else {
            eventContinuation.yield(.failed(bookID: bookID, statusCode: status, error: nil))
            return
        }

        // The OS deletes `location` the instant this method returns, so the
        // move has to happen synchronously, right here — not after hopping
        // back to the main actor.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("kontinuity-download-\(bookID).cbz")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            eventContinuation.yield(.finished(bookID: bookID, fileURL: destination))
        } catch {
            eventContinuation.yield(.failed(bookID: bookID, statusCode: nil, error: error))
        }
    }

    nonisolated func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let bookID = task.taskDescription, let error else { return }
        eventContinuation.yield(.failed(bookID: bookID, statusCode: nil, error: error))
    }

    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let bookID = downloadTask.taskDescription else { return }
        eventContinuation.yield(.progress(
            bookID: bookID,
            received: totalBytesWritten,
            expected: totalBytesExpectedToWrite
        ))
    }

    /// The system calls this once every event for a background session has
    /// been delivered — the signal the app-launch completion handler
    /// (`AppDelegate.handleEventsForBackgroundURLSession`) is waiting on.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        DispatchQueue.main.async {
            AppDelegate.backgroundCompletionHandler?()
            AppDelegate.backgroundCompletionHandler = nil
        }
    }
}

private enum DownloadEvent: Sendable {
    case progress(bookID: String, received: Int64, expected: Int64)
    case finished(bookID: String, fileURL: URL)
    case failed(bookID: String, statusCode: Int?, error: Error?)
}

private enum DownloadTransportError: Error {
    case forbidden
    case status(Int)
}

private enum DownloadPipelineError: Error {
    case pageCountMismatch
}
