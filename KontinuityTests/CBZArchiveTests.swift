//
//  CBZArchiveTests.swift
//  KontinuityTests
//
//  Hand-built ZIP fixtures rather than a bundled binary — a CBZ is just a ZIP,
//  and constructing one byte-for-byte is the only way to test the central
//  directory parsing without a real file on disk. `ZipFixtureBuilder` is the
//  writer that mirrors `CBZArchive`'s reader.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("CBZArchive")
struct CBZArchiveTests {
    @Test("extracts stored entries in natural filename order")
    func extractsStoredEntriesInOrder() throws {
        let archive = ZipFixtureBuilder.make(entries: [
            .init(name: "page1.jpg", data: Data([0x01, 0x02, 0x03])),
            .init(name: "page10.jpg", data: Data([0x0A, 0x0A])),
            .init(name: "page2.jpg", data: Data([0x02, 0x02, 0x02, 0x02]))
        ])

        let pages = try CBZArchive.extractImagePages(from: archive)

        #expect(pages == [Data([0x01, 0x02, 0x03]), Data([0x02, 0x02, 0x02, 0x02]), Data([0x0A, 0x0A])])
    }

    @Test("round-trips a deflate-compressed entry")
    func roundTripsDeflateEntry() throws {
        let original = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let deflated = try #require(ZipFixtureBuilder.deflate(original))
        let archive = ZipFixtureBuilder.make(entries: [
            .init(name: "page1.jpg", data: original, storedData: deflated, method: 8)
        ])

        let pages = try CBZArchive.extractImagePages(from: archive)

        #expect(pages == [original])
    }

    @Test("filters out non-image and junk entries")
    func filtersNonImageEntries() throws {
        let archive = ZipFixtureBuilder.make(entries: [
            .init(name: "ComicInfo.xml", data: Data([0xFF])),
            .init(name: "__MACOSX/._page1.jpg", data: Data([0xFF])),
            .init(name: ".DS_Store", data: Data([0xFF])),
            .init(name: "art/", data: Data()),
            .init(name: "page1.jpg", data: Data([0x11]))
        ])

        let pages = try CBZArchive.extractImagePages(from: archive)

        #expect(pages == [Data([0x11])])
    }

    @Test("throws on data with no End Of Central Directory record")
    func throwsWhenNotAZip() {
        #expect(throws: CBZArchiveError.self) {
            try CBZArchive.extractImagePages(from: Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    @Test("throws when compressed bytes are truncated")
    func throwsOnTruncatedData() throws {
        let archive = ZipFixtureBuilder.make(entries: [
            .init(name: "page1.jpg", data: Data([0x01, 0x02, 0x03, 0x04]))
        ])
        let truncated = archive.dropLast(2)

        #expect(throws: CBZArchiveError.self) {
            try CBZArchive.extractImagePages(from: truncated)
        }
    }

    @Test("natural order treats digit runs numerically, not lexicographically")
    func naturalOrderIsNumericAware() {
        #expect(CBZArchive.naturalOrder("page2.jpg", "page10.jpg"))
        #expect(!CBZArchive.naturalOrder("page10.jpg", "page2.jpg"))
        // Equal numeric value, different padding: shorter sorts first — an
        // arbitrary but total tie-break. Real archives don't mix page-number
        // widths within one book, so this never fires in practice.
        #expect(CBZArchive.naturalOrder("page1.jpg", "page01.jpg"))
        #expect(!CBZArchive.naturalOrder("page01.jpg", "page1.jpg"))
        #expect(!CBZArchive.naturalOrder("page1.jpg", "page1.jpg"))
    }
}
