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

    struct StubKomgaService: KomgaServing {
        var user = KomgaUser(
            id: "stub-user",
            email: "uitest@example.com",
            roles: ["USER", "FILE_DOWNLOAD", "PAGE_STREAMING"]
        )

        // MARK: - Connect surface

        func checkReachable() async throws {}

        func currentUser() async throws -> KomgaUser {
            user
        }

        func createAPIKey(comment: String) async throws -> KomgaAPIKey {
            KomgaAPIKey(id: "stub-key", userId: user.id, key: "stub", comment: comment, createdDate: .now)
        }

        func deleteAPIKey(id _: String) async throws {}

        // MARK: - Browse

        func libraries() async throws -> [KomgaLibrary] {
            Fixtures.libraries
        }

        func series(matching query: SeriesQuery) async throws -> KomgaPage<KomgaSeries> {
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
            matches.sort { $0.metadata.titleSort.localizedCompare($1.metadata.titleSort) == .orderedAscending }
            return Self.page(matches, page: query.page, size: query.size)
        }

        func series(id: String) async throws -> KomgaSeries {
            guard let series = Fixtures.series.first(where: { $0.id == id }) else {
                throw KomgaError.notFound
            }
            return series
        }

        func books(inSeries seriesID: String, matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
            var matches = Fixtures.books.filter { $0.seriesId == seriesID }
            if !query.readStatus.isEmpty {
                let wanted = Set(query.readStatus)
                matches = matches.filter { wanted.contains($0.status) }
            }
            matches.sort { $0.metadata.numberSort < $1.metadata.numberSort }
            return Self.page(matches, page: query.page, size: query.size)
        }

        func book(id: String) async throws -> KomgaBook {
            guard let book = Fixtures.books.first(where: { $0.id == id }) else {
                throw KomgaError.notFound
            }
            return book
        }

        func keepReading(matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
            var matches = Fixtures.books.filter { $0.status == .inProgress }
            if let libraryID = query.libraryID {
                matches = matches.filter { $0.libraryId == libraryID }
            }
            matches.sort { ($0.readProgress?.readDate ?? .distantPast) > ($1.readProgress?.readDate ?? .distantPast) }
            return Self.page(matches, page: query.page, size: query.size)
        }

        func onDeck(matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
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
            Fixtures.poster(for: target)
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

    private extension KomgaBook {
        /// The stub filters on read status the way Komga's query does.
        var status: KomgaReadStatus {
            switch readState {
            case .unread: .unread
            case .inProgress: .inProgress
            case .read: .read
            }
        }
    }

    // MARK: - Fixtures

    enum Fixtures {
        static let libraries = [
            KomgaLibrary(id: UITestFixture.mangaLibraryID, name: "Manga"),
            KomgaLibrary(id: UITestFixture.comicsLibraryID, name: "Comics")
        ]

        static let series: [KomgaSeries] = [
            KomgaSeries(
                id: UITestFixture.inProgressSeriesID,
                libraryId: UITestFixture.mangaLibraryID,
                name: "air-gear",
                booksCount: 4,
                booksReadCount: 1,
                booksUnreadCount: 2,
                booksInProgressCount: 1,
                metadata: KomgaSeriesMetadata(
                    title: "Air Gear",
                    titleSort: "Air Gear",
                    summary: "Ikki discovers Air Trecks and the world of Storm Riders.",
                    status: "ONGOING",
                    publisher: "Kodansha",
                    language: "en",
                    ageRating: 13,
                    genres: ["action", "shounen"],
                    totalBookCount: 37
                ),
                booksMetadata: KomgaBooksMetadata(
                    authors: [KomgaAuthor(name: "Oh!great", role: "writer")],
                    summary: "Air Gear, volume by volume."
                )
            ),
            KomgaSeries(
                id: UITestFixture.finishedSeriesID,
                libraryId: UITestFixture.mangaLibraryID,
                name: "akira",
                booksCount: 2,
                booksReadCount: 2,
                metadata: KomgaSeriesMetadata(
                    title: "Akira",
                    titleSort: "Akira",
                    summary: "Neo-Tokyo is about to explode.",
                    status: "ENDED",
                    publisher: "Kodansha",
                    genres: ["cyberpunk"],
                    readingDirection: KomgaReadingDirection.rightToLeft.rawValue
                )
            ),
            KomgaSeries(
                id: UITestFixture.comicsSeriesID,
                libraryId: UITestFixture.comicsLibraryID,
                name: "saga",
                booksCount: 1,
                booksUnreadCount: 1,
                metadata: KomgaSeriesMetadata(
                    title: "Saga",
                    titleSort: "Saga",
                    summary: "Two soldiers from opposite sides of a galactic war.",
                    status: "ONGOING",
                    publisher: "Image"
                )
            )
        ]

        static let books: [KomgaBook] = [
            book(
                id: UITestFixture.readBookID,
                number: 1,
                title: "Air Gear, Vol. 1",
                progress: KomgaReadProgress(
                    page: 190,
                    completed: true,
                    readDate: Date(timeIntervalSince1970: 1_770_000_000),
                    deviceName: "Matt's iPad"
                )
            ),
            book(
                id: UITestFixture.inProgressBookID,
                number: 2,
                title: "Air Gear, Vol. 2",
                progress: KomgaReadProgress(
                    page: 42,
                    completed: false,
                    readDate: Date(timeIntervalSince1970: 1_780_000_000),
                    deviceName: "Matt's iPad"
                )
            ),
            book(id: UITestFixture.unreadBookID, number: 3, title: "Air Gear, Vol. 3"),
            // Zero pages and status UNKNOWN: Komga has the file but hasn't analysed
            // it. The UI must say so rather than offering an empty reader.
            book(
                id: UITestFixture.unanalysedBookID,
                number: 4,
                title: "Air Gear, Vol. 4",
                pages: 0,
                mediaStatus: "UNKNOWN"
            ),
            book(
                id: "book-akira-1",
                number: 1,
                title: "Akira, Vol. 1",
                seriesID: UITestFixture.finishedSeriesID,
                seriesTitle: "Akira",
                progress: KomgaReadProgress(
                    page: 364,
                    completed: true,
                    readDate: Date(timeIntervalSince1970: 1_760_000_000),
                    deviceName: "Matt's iPad"
                )
            ),
            book(
                id: "book-akira-2",
                number: 2,
                title: "Akira, Vol. 2",
                seriesID: UITestFixture.finishedSeriesID,
                seriesTitle: "Akira",
                progress: KomgaReadProgress(
                    page: 296,
                    completed: true,
                    readDate: Date(timeIntervalSince1970: 1_765_000_000),
                    deviceName: "Matt's iPad"
                )
            ),
            book(
                id: "book-saga-1",
                number: 1,
                title: "Saga, Vol. 1",
                seriesID: UITestFixture.comicsSeriesID,
                seriesTitle: "Saga",
                libraryID: UITestFixture.comicsLibraryID
            )
        ]

        private static func book(
            id: String,
            number: Int,
            title: String,
            seriesID: String = UITestFixture.inProgressSeriesID,
            seriesTitle: String = "Air Gear",
            libraryID: String = UITestFixture.mangaLibraryID,
            pages: Int = 190,
            mediaStatus: String = "READY",
            progress: KomgaReadProgress? = nil
        ) -> KomgaBook {
            KomgaBook(
                id: id,
                seriesId: seriesID,
                seriesTitle: seriesTitle,
                libraryId: libraryID,
                name: title,
                sizeBytes: 32_000_000,
                size: "30.5 MiB",
                media: KomgaMedia(status: mediaStatus, pagesCount: pages),
                metadata: KomgaBookMetadata(
                    title: title,
                    number: String(number),
                    numberSort: Double(number),
                    summary: "Volume \(number).",
                    releaseDate: KomgaDay(year: 2018, month: 1, day: number),
                    authors: [KomgaAuthor(name: "Oh!great", role: "writer")]
                ),
                readProgress: progress
            )
        }

        /// A flat-colour JPEG, drawn rather than bundled so there are no binary
        /// fixtures in the repo. The colour is derived from the id, so a given
        /// series looks the same on every run — which is what makes the launch
        /// screenshots comparable between CI runs.
        static func poster(for target: KomgaThumbnail) -> Data? {
            let seed: String = switch target {
            case let .series(id): id
            case let .book(id): id
            }
            // Not `hashValue`: Swift seeds string hashing per process, so that would
            // give a different colour on every launch — the opposite of the point.
            let digest = seed.unicodeScalars.reduce(UInt32(2_166_136_261)) { hash, scalar in
                (hash ^ (scalar.value & 0xFF)) &* 16_777_619
            }
            let hue = Double(digest % 360) / 360.0
            let size = CGSize(width: 200, height: 300)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(hue: hue, saturation: 0.45, brightness: 0.65, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            return image.jpegData(compressionQuality: 0.8)
        }
    }

#endif
