//
//  StubKomgaService.swift
//  Kontinuity
//
//  A `KomgaServing` backed by fixtures instead of a server, so UI tests and
//  SwiftUI previews get a library that is the same on every run and on a machine
//  with no Komga at all.
//
//  It implements the real filtering, sorting and paging rather than returning a
//  fixed list — a stub that ignores its query can't tell you whether the search
//  field is wired up, which is most of what these tests are for.
//
//  DEBUG-only: `make deploy` and `make ipa` build Debug, so it's there when
//  wanted; an archived Release build carries none of it.
//

#if DEBUG

    import Foundation
    import KontinuityCore
    import UIKit

    /// `nonisolated` on the type itself, not inferred from `KomgaServing:
    /// Sendable` — Sendable conformance alone doesn't opt a declaration out
    /// of the module's default `MainActor` isolation, so every method here
    /// would otherwise silently go back to being main-actor-isolated (and
    /// unable to read `Fixtures`, itself `nonisolated`) the next time one is
    /// added without a manual annotation.
    nonisolated struct StubKomgaService: KomgaServing {
        var user = KomgaUser(
            id: "stub-user",
            email: "uitest@example.com",
            roles: ["USER", "FILE_DOWNLOAD", "PAGE_STREAMING"]
        )

        /// PLAN §11's offline-simulation mode (`UITestMode.offline` /
        /// `.offlineWithDownloads`): every server-hit method fails the same
        /// way a real dropped connection would, so the app's own
        /// `KomgaError.isOffline` classification is what's under test, not a
        /// faked-out shortcut.
        var offline = false

        private func checkOnline() throws {
            guard !offline else {
                throw KomgaError.transport(code: .notConnectedToInternet, description: "No connection to the server.")
            }
        }

        // MARK: - Connect surface

        func checkReachable() async throws {
            try checkOnline()
        }

        func currentUser() async throws -> KomgaUser {
            try checkOnline()
            return user
        }

        func createAPIKey(comment: String) async throws -> KomgaAPIKey {
            try checkOnline()
            return KomgaAPIKey(id: "stub-key", userId: user.id, key: "stub", comment: comment, createdDate: .now)
        }

        func deleteAPIKey(id _: String) async throws {
            try checkOnline()
        }

        // MARK: - Browse

        func libraries() async throws -> [KomgaLibrary] {
            try checkOnline()
            return Fixtures.libraries
        }

        func series(matching query: SeriesQuery) async throws -> KomgaPage<KomgaSeries> {
            try checkOnline()
            var matches = Fixtures.series
            if let libraryID = query.libraryID {
                matches = matches.filter { $0.libraryId == libraryID }
            }
            if let term = query.searchTerm?.trimmed, !term.isEmpty {
                matches = matches.filter { $0.displayTitle.localizedCaseInsensitiveContains(term) }
            }
            if let oneshot = query.oneshot {
                matches = matches.filter { $0.oneshot == oneshot }
            }
            if !query.readStatus.isEmpty {
                let wanted = Set(query.readStatus)
                matches = matches.filter { wanted.contains($0.readStatus) }
            }
            matches.sort { $0.metadata.titleSort.localizedCompare($1.metadata.titleSort) == .orderedAscending }
            return Self.page(matches, page: query.page, size: query.size)
        }

        func series(id: String) async throws -> KomgaSeries {
            try checkOnline()
            guard let series = Fixtures.series.first(where: { $0.id == id }) else {
                throw KomgaError.notFound
            }
            return series
        }

        func books(inSeries seriesID: String, matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
            try checkOnline()
            var matches = Fixtures.books.filter { $0.seriesId == seriesID }
            if !query.readStatus.isEmpty {
                let wanted = Set(query.readStatus)
                matches = matches.filter { wanted.contains($0.status) }
            }
            matches.sort {
                query.ascending
                    ? $0.metadata.numberSort < $1.metadata.numberSort
                    : $0.metadata.numberSort > $1.metadata.numberSort
            }
            return Self.page(matches, page: query.page, size: query.size)
        }

        func book(id: String) async throws -> KomgaBook {
            try checkOnline()
            guard let book = Fixtures.books.first(where: { $0.id == id }) else {
                throw KomgaError.notFound
            }
            return book
        }

        func keepReading(matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
            try checkOnline()
            var matches = Fixtures.books.filter { $0.status == .inProgress }
            if let libraryID = query.libraryID {
                matches = matches.filter { $0.libraryId == libraryID }
            }
            matches.sort { ($0.readProgress?.readDate ?? .distantPast) > ($1.readProgress?.readDate ?? .distantPast) }
            return Self.page(matches, page: query.page, size: query.size)
        }

        func onDeck(matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
            try checkOnline()
            // Komga's rule: the first unread book of a series that has at least one
            // book read and nothing in progress.
            let eligible = Fixtures.series.filter { $0.booksReadCount > 0 && $0.booksInProgressCount == 0 }
            let matches = eligible.compactMap { series in
                Fixtures.books
                    .filter { $0.seriesId == series.id && $0.status == .unread }
                    .min { $0.metadata.numberSort < $1.metadata.numberSort }
            }
            return Self.page(matches, page: query.page, size: query.size)
        }

        func thumbnailData(for target: KomgaThumbnail) async throws -> Data? {
            try checkOnline()
            return Fixtures.poster(for: target)
        }

        // MARK: - Reader

        func divinaManifest(forBook bookID: String) async throws -> KomgaDivinaManifest {
            try checkOnline()
            guard let book = Fixtures.books.first(where: { $0.id == bookID }) else {
                throw KomgaError.notFound
            }
            let count = max(book.media.pagesCount, 0)
            // Portrait, aspect ≈ 0.66 — matches KOMGA-API §2's measurement
            // against a real CBZ, so the layout engine sees realistic input.
            let readingOrder = (0 ..< count).map { index in
                KomgaPageLink(
                    href: "/opds/v2/books/\(bookID)/pages/\(index + 1)?contentNegotiation=false",
                    type: "image/jpeg",
                    width: 800,
                    height: 1200
                )
            }
            return KomgaDivinaManifest(
                metadata: .init(title: book.displayTitle, numberOfPages: count),
                readingOrder: readingOrder
            )
        }

        func pageImageData(at href: String) async throws -> Data {
            try checkOnline()
            return Fixtures.pageImage(at: href)
        }

        func putProgression(bookID _: String, write _: ProgressionWrite, device _: KomgaDevice) async throws {
            try checkOnline()
            // Verifying the real write path is LiveKomgaTests's job, not the
            // stub's — the UI tests only need paging and the resume position to
            // work, neither of which depends on this landing anywhere.
        }

        func markRead(bookID _: String) async throws {
            try checkOnline()
        }

        func markUnread(bookID _: String) async throws {
            try checkOnline()
        }

        // MARK: - Download

        /// A real ZIP, built from the same fixture page images the reader
        /// uses — so a UI test's download actually exercises
        /// `CBZArchive`/`LocalBookStore`, not a faked-out shortcut.
        func fileData(forBook bookID: String) async throws -> Data {
            try checkOnline()
            return try Self.zipFixture(forBook: bookID)
        }

        /// The stub has no real server to point at, so this writes the same
        /// fixture archive to a temp file and hands back a `file://` request —
        /// `DownloadCoordinator`'s UI-test session (plain, not background)
        /// downloads it exactly like it would an `https://` URL.
        func fileDownloadRequest(forBook bookID: String) -> URLRequest {
            guard let data = try? Self.zipFixture(forBook: bookID) else {
                return URLRequest(url: URL(fileURLWithPath: "/dev/null"))
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(bookID)-fixture.cbz")
            try? data.write(to: url)
            return URLRequest(url: url)
        }

        private static func zipFixture(forBook bookID: String) throws -> Data {
            guard let book = Fixtures.books.first(where: { $0.id == bookID }) else {
                throw KomgaError.notFound
            }
            let pages = (0 ..< max(book.media.pagesCount, 0)).map { index in
                Fixtures.pageImage(at: "/opds/v2/books/\(bookID)/pages/\(index + 1)?contentNegotiation=false")
            }
            return StoredZipWriter.make(pages: pages)
        }

        // MARK: - Paging

        private static func page<T: Decodable & Sendable>(_ all: [T], page: Int, size: Int) -> KomgaPage<T> {
            let size = max(1, size)
            let start = min(page * size, all.count)
            let end = min(start + size, all.count)
            let totalPages = all.isEmpty ? 0 : Int(ceil(Double(all.count) / Double(size)))
            return KomgaPage(
                content: Array(all[start ..< end]),
                totalElements: all.count,
                totalPages: totalPages,
                number: page,
                size: size,
                first: page == 0,
                last: end >= all.count
            )
        }
    }

    private nonisolated extension KomgaBook {
        /// The stub filters on read status the way Komga's query does.
        var status: KomgaReadStatus {
            switch readState {
            case .unread: .unread
            case .inProgress: .inProgress
            case .read: .read
            }
        }
    }

    private nonisolated extension KomgaSeries {
        /// Mirrors `SeriesSearchHelper.kt`'s `SearchCondition.ReadStatus`: READ
        /// when every book is, UNREAD when none have been touched, IN_PROGRESS
        /// for everything in between.
        var readStatus: KomgaReadStatus {
            if isFullyRead {
                return .read
            }
            if booksReadCount == 0, booksInProgressCount == 0 {
                return .unread
            }
            return .inProgress
        }
    }

#endif
