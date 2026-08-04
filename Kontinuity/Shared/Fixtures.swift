//
//  Fixtures.swift
//  Kontinuity
//
//  The canned library `StubKomgaService` serves, plus the tiny CBZ writer that
//  turns its page images into something `CBZArchive` can actually decompress.
//  Split out of StubKomgaService.swift once the offline-simulation guard
//  rails (PLAN §11) pushed that file over the line-count limit — this half is
//  pure data and has no `KomgaServing` conformance of its own to justify
//  staying there.
//
//  DEBUG-only, same reasoning as StubKomgaService.swift.
//

#if DEBUG

    import Foundation
    import KontinuityCore
    import UIKit

    /// Explicit `Sendable` opts this out of the module's default `MainActor`
    /// isolation (SE-0466) — every member is pure, immutable fixture data,
    /// and `StubKomgaService`'s methods (nonisolated, since `KomgaServing:
    /// Sendable` gets the same opt-out) need to read it from off the main
    /// actor.
    enum Fixtures: Sendable {
        static let libraries = [
            KomgaLibrary(id: UITestFixture.mangaLibraryID, name: "Manga"),
            KomgaLibrary(id: UITestFixture.comicsLibraryID, name: "Comics")
        ]

        static let series: [KomgaSeries] = [
            KomgaSeries(
                id: UITestFixture.inProgressSeriesID,
                libraryId: UITestFixture.mangaLibraryID,
                name: "windrunner",
                booksCount: 4,
                booksReadCount: 1,
                booksUnreadCount: 2,
                booksInProgressCount: 1,
                metadata: KomgaSeriesMetadata(
                    title: "Windrunner",
                    titleSort: "Windrunner",
                    summary: "Mika discovers a pair of storm-powered skates and a rooftop city of racers.",
                    status: "ONGOING",
                    publisher: "Kessho House",
                    language: "en",
                    ageRating: 13,
                    genres: ["action", "shounen"],
                    totalBookCount: 37
                ),
                booksMetadata: KomgaBooksMetadata(
                    authors: [KomgaAuthor(name: "R. Kessho", role: "writer")],
                    summary: "Windrunner, volume by volume."
                )
            ),
            KomgaSeries(
                id: UITestFixture.finishedSeriesID,
                libraryId: UITestFixture.mangaLibraryID,
                name: "neon-requiem",
                booksCount: 2,
                booksReadCount: 2,
                metadata: KomgaSeriesMetadata(
                    title: "Neon Requiem",
                    titleSort: "Neon Requiem",
                    summary: "A city of chrome towers is about to explode.",
                    status: "ENDED",
                    publisher: "Kessho House",
                    genres: ["cyberpunk"],
                    readingDirection: KomgaReadingDirection.rightToLeft.rawValue
                )
            ),
            KomgaSeries(
                id: UITestFixture.comicsSeriesID,
                libraryId: UITestFixture.comicsLibraryID,
                name: "halcyon-drift",
                booksCount: 1,
                booksUnreadCount: 1,
                metadata: KomgaSeriesMetadata(
                    title: "Halcyon Drift",
                    titleSort: "Halcyon Drift",
                    summary: "Two deserters from opposite sides of a galactic war.",
                    status: "ONGOING",
                    publisher: "Driftwood Press"
                )
            )
        ]

        static let books: [KomgaBook] = [
            book(
                id: UITestFixture.readBookID,
                number: 1,
                title: "Windrunner, Vol. 1",
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
                title: "Windrunner, Vol. 2",
                progress: KomgaReadProgress(
                    page: 42,
                    completed: false,
                    readDate: Date(timeIntervalSince1970: 1_780_000_000),
                    deviceName: "Matt's iPad"
                )
            ),
            // Readable, with fixture pages behind it — what the reader UI tests open.
            book(id: UITestFixture.unreadBookID, number: 3, title: "Windrunner, Vol. 3", pages: 6),
            // Zero pages and status UNKNOWN: Komga has the file but hasn't analysed
            // it. The UI must say so rather than offering an empty reader.
            book(
                id: UITestFixture.unanalysedBookID,
                number: 4,
                title: "Windrunner, Vol. 4",
                pages: 0,
                mediaStatus: "UNKNOWN"
            ),
            book(
                id: "book-neon-requiem-1",
                number: 1,
                title: "Neon Requiem, Vol. 1",
                seriesID: UITestFixture.finishedSeriesID,
                seriesTitle: "Neon Requiem",
                progress: KomgaReadProgress(
                    page: 364,
                    completed: true,
                    readDate: Date(timeIntervalSince1970: 1_760_000_000),
                    deviceName: "Matt's iPad"
                )
            ),
            book(
                id: "book-neon-requiem-2",
                number: 2,
                title: "Neon Requiem, Vol. 2",
                seriesID: UITestFixture.finishedSeriesID,
                seriesTitle: "Neon Requiem",
                progress: KomgaReadProgress(
                    page: 296,
                    completed: true,
                    readDate: Date(timeIntervalSince1970: 1_765_000_000),
                    deviceName: "Matt's iPad"
                )
            ),
            book(
                id: "book-halcyon-drift-1",
                number: 1,
                title: "Halcyon Drift, Vol. 1",
                seriesID: UITestFixture.comicsSeriesID,
                seriesTitle: "Halcyon Drift",
                libraryID: UITestFixture.comicsLibraryID
            )
        ]

        private static func book(
            id: String,
            number: Int,
            title: String,
            seriesID: String = UITestFixture.inProgressSeriesID,
            seriesTitle: String = "Windrunner",
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
                    authors: [KomgaAuthor(name: "R. Kessho", role: "writer")]
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

        /// A flat-colour JPEG for a reader page, keyed by its href so the same
        /// page looks the same across a run without any binary fixtures in the
        /// repo — same technique as ``poster(for:)``, sized to what the stub's
        /// manifest declares (800×1200, matching KOMGA-API §2's measured aspect).
        static func pageImage(at href: String) -> Data {
            let digest = href.unicodeScalars.reduce(UInt32(2_166_136_261)) { hash, scalar in
                (hash ^ (scalar.value & 0xFF)) &* 16_777_619
            }
            let hue = Double(digest % 360) / 360.0
            let size = CGSize(width: 800, height: 1200)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(hue: hue, saturation: 0.55, brightness: 0.5, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            return image.jpegData(compressionQuality: 0.8) ?? Data()
        }
    }

    /// The smallest possible ZIP writer — stored (uncompressed) entries only,
    /// zero-padded page numbers so natural sort matches insertion order.
    /// `CBZArchive` is a reader; this is its mirror image, kept here rather
    /// than in Core because nothing at runtime ever needs to *write* a CBZ.
    enum StoredZipWriter {
        static func make(pages: [Data]) -> Data {
            var body = Data()
            var central = Data()
            var offsets: [Int] = []

            let names = pages.indices.map { String(format: "%04d.jpg", $0 + 1) }
            for (page, name) in zip(pages, names) {
                offsets.append(body.count)
                let nameBytes = Data(name.utf8)
                body.appendUInt32(0x0403_4B50)
                body.appendUInt16(20)
                body.appendUInt16(0)
                body.appendUInt16(0) // method: stored
                body.appendUInt16(0)
                body.appendUInt16(0)
                body.appendUInt32(0) // crc32 — unchecked by CBZArchive
                body.appendUInt32(UInt32(page.count))
                body.appendUInt32(UInt32(page.count))
                body.appendUInt16(UInt16(nameBytes.count))
                body.appendUInt16(0)
                body.append(nameBytes)
                body.append(page)
            }

            for (index, name) in names.enumerated() {
                let nameBytes = Data(name.utf8)
                let size = UInt32(pages[index].count)
                central.appendUInt32(0x0201_4B50)
                central.appendUInt16(20)
                central.appendUInt16(20)
                central.appendUInt16(0)
                central.appendUInt16(0)
                central.appendUInt16(0)
                central.appendUInt16(0)
                central.appendUInt32(0)
                central.appendUInt32(size)
                central.appendUInt32(size)
                central.appendUInt16(UInt16(nameBytes.count))
                central.appendUInt16(0)
                central.appendUInt16(0)
                central.appendUInt16(0)
                central.appendUInt16(0)
                central.appendUInt32(0)
                central.appendUInt32(UInt32(offsets[index]))
                central.append(nameBytes)
            }

            var archive = body
            let centralDirOffset = archive.count
            archive.append(central)
            archive.appendUInt32(0x0605_4B50)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(UInt16(pages.count))
            archive.appendUInt16(UInt16(pages.count))
            archive.appendUInt32(UInt32(central.count))
            archive.appendUInt32(UInt32(centralDirOffset))
            archive.appendUInt16(0)
            return archive
        }
    }

    extension Data {
        mutating func appendUInt16(_ value: UInt16) {
            append(UInt8(value & 0xFF))
            append(UInt8((value >> 8) & 0xFF))
        }

        mutating func appendUInt32(_ value: UInt32) {
            append(UInt8(value & 0xFF))
            append(UInt8((value >> 8) & 0xFF))
            append(UInt8((value >> 16) & 0xFF))
            append(UInt8((value >> 24) & 0xFF))
        }
    }

#endif
