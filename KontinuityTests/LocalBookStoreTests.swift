//
//  LocalBookStoreTests.swift
//  KontinuityTests
//
//  A temp directory stands in for Application Support — `LocalBookStore`
//  takes its base directory as an init parameter for exactly this reason.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("LocalBookStore")
struct LocalBookStoreTests {
    private func makeStore() -> LocalBookStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return LocalBookStore(baseDirectory: root)
    }

    private func page(_ byte: UInt8, width: Int? = 800, height: Int? = 1200) -> LocalPageWrite {
        LocalPageWrite(data: Data([byte, byte, byte]), width: width, height: height, mediaType: "image/jpeg")
    }

    @Test("isDownloaded is false until a book is written")
    func notDownloadedInitially() {
        let store = makeStore()
        #expect(!store.isDownloaded("book-1"))
        #expect(store.manifest(forBook: "book-1") == nil)
    }

    @Test("write persists a manifest that round-trips page metadata")
    func writeRoundTripsManifest() throws {
        let store = makeStore()
        try store.write(pages: [page(1, width: 800, height: 1200), page(2, width: 810, height: 1190)], bookID: "book-1")

        let manifest = try #require(store.manifest(forBook: "book-1"))
        #expect(manifest.bookID == "book-1")
        #expect(manifest.pages.map(\.width) == [800, 810])
        #expect(manifest.pages.map(\.height) == [1200, 1190])
        #expect(manifest.pages.allSatisfy { $0.mediaType == "image/jpeg" })
        #expect(store.isDownloaded("book-1"))
    }

    @Test("pageURL points at the page's actual bytes")
    func pageURLResolvesToWrittenBytes() throws {
        let store = makeStore()
        try store.write(pages: [page(7)], bookID: "book-1")

        let url = try #require(store.pageURL(forBook: "book-1", index: 0))
        #expect(try Data(contentsOf: url) == Data([7, 7, 7]))
        #expect(store.pageURL(forBook: "book-1", index: 1) == nil)
    }

    @Test("a second write replaces the first rather than mixing pages")
    func rewriteReplacesPreviousPages() throws {
        let store = makeStore()
        try store.write(pages: [page(1), page(2), page(3)], bookID: "book-1")
        try store.write(pages: [page(9)], bookID: "book-1")

        let manifest = try #require(store.manifest(forBook: "book-1"))
        #expect(manifest.pages.count == 1)
        #expect(store.pageURL(forBook: "book-1", index: 1) == nil)
        let url = try #require(store.pageURL(forBook: "book-1", index: 0))
        #expect(try Data(contentsOf: url) == Data([9, 9, 9]))
    }

    @Test("deleteBook removes the manifest and all page files")
    func deleteBookRemovesEverything() throws {
        let store = makeStore()
        try store.write(pages: [page(1)], bookID: "book-1")
        #expect(store.isDownloaded("book-1"))

        try store.deleteBook("book-1")

        #expect(!store.isDownloaded("book-1"))
        #expect(store.diskUsage(forBook: "book-1") == 0)
    }

    @Test("deleting a book that was never downloaded is a no-op, not an error")
    func deleteMissingBookIsHarmless() throws {
        let store = makeStore()
        try store.deleteBook("never-downloaded")
    }

    @Test("disk usage reflects written bytes and sums across books")
    func diskUsageSumsAcrossBooks() throws {
        let store = makeStore()
        try store.write(pages: [page(1), page(2)], bookID: "book-1")
        try store.write(pages: [page(3)], bookID: "book-2")

        #expect(store.diskUsage(forBook: "book-1") > 0)
        #expect(store.diskUsage(forBook: "book-2") > 0)
        let total = store.totalDiskUsage(for: ["book-1", "book-2"])
        #expect(total == store.diskUsage(forBook: "book-1") + store.diskUsage(forBook: "book-2"))
    }

    @Test("a downloaded book's directory is excluded from backup")
    func excludesFromBackup() throws {
        let store = makeStore()
        try store.write(pages: [page(1)], bookID: "book-1")

        let values = try store.directory(forBook: "book-1").resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
