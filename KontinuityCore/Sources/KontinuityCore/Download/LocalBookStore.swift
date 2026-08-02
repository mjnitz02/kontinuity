//
//  LocalBookStore.swift
//  KontinuityCore
//
//  PLAN §4: downloaded pages live as files on disk, not in SwiftData —
//  `Application Support/books/{bookId}/pages/` plus a `manifest.json`
//  recording each page's dimensions and media type (carried over from the
//  network DIVINA manifest at download time, not re-derived). The reader
//  never unzips at read time; this is the only thing it needs to open a
//  downloaded book.
//
//  File-system only — no networking, no UIKit — so it's unit-testable with a
//  temporary directory standing in for Application Support.
//

import Foundation

public struct LocalPageRef: Codable, Sendable, Hashable {
    public let width: Int?
    public let height: Int?
    public let mediaType: String

    public init(width: Int?, height: Int?, mediaType: String) {
        self.width = width
        self.height = height
        self.mediaType = mediaType
    }
}

public struct LocalBookManifest: Codable, Sendable, Hashable {
    public let bookID: String
    public let pages: [LocalPageRef]

    public init(bookID: String, pages: [LocalPageRef]) {
        self.bookID = bookID
        self.pages = pages
    }
}

/// One decompressed page, ready to be written. `width`/`height` come from the
/// network DIVINA manifest fetched just before the file (PLAN §6 step 3), not
/// from probing the image after the fact.
public struct LocalPageWrite: Sendable {
    public let data: Data
    public let width: Int?
    public let height: Int?
    public let mediaType: String

    public init(data: Data, width: Int?, height: Int?, mediaType: String) {
        self.data = data
        self.width = width
        self.height = height
        self.mediaType = mediaType
    }
}

public struct LocalBookStore: Sendable {
    private let baseDirectory: URL
    /// FileManager isn't Sendable in this SDK, but `.default` and a per-instance
    /// instance are both documented safe for concurrent use from multiple threads.
    private nonisolated(unsafe) let fileManager: FileManager

    /// `baseDirectory` is injectable so tests point at a temp directory
    /// instead of the real Application Support container.
    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            self.baseDirectory = (support ?? fileManager.temporaryDirectory)
                .appendingPathComponent("books", isDirectory: true)
        }
    }

    public func directory(forBook bookID: String) -> URL {
        baseDirectory.appendingPathComponent(bookID, isDirectory: true)
    }

    public func manifest(forBook bookID: String) -> LocalBookManifest? {
        guard let data = try? Data(contentsOf: manifestURL(forBook: bookID)) else { return nil }
        return try? JSONDecoder().decode(LocalBookManifest.self, from: data)
    }

    public func isDownloaded(_ bookID: String) -> Bool {
        manifest(forBook: bookID) != nil
    }

    public func pageURL(forBook bookID: String, index: Int) -> URL? {
        guard let manifest = manifest(forBook: bookID), manifest.pages.indices.contains(index) else { return nil }
        let name = Self.fileName(forPage: index, mediaType: manifest.pages[index].mediaType)
        return pagesDirectory(forBook: bookID).appendingPathComponent(name, isDirectory: false)
    }

    /// Writes every page plus the manifest describing them. Whole-book, not
    /// incremental: any leftover directory from a previous attempt is cleared
    /// first so a retried download can never mix pages from two attempts.
    public func write(pages: [LocalPageWrite], bookID: String) throws {
        try? deleteBook(bookID)
        let pagesDir = pagesDirectory(forBook: bookID)
        try fileManager.createDirectory(at: pagesDir, withIntermediateDirectories: true)

        var refs: [LocalPageRef] = []
        refs.reserveCapacity(pages.count)
        for (index, page) in pages.enumerated() {
            let name = Self.fileName(forPage: index, mediaType: page.mediaType)
            try page.data.write(to: pagesDir.appendingPathComponent(name, isDirectory: false))
            refs.append(LocalPageRef(width: page.width, height: page.height, mediaType: page.mediaType))
        }

        let manifestData = try JSONEncoder().encode(LocalBookManifest(bookID: bookID, pages: refs))
        try manifestData.write(to: manifestURL(forBook: bookID))

        // Re-downloadable, so it shouldn't cost the user's iCloud backup quota.
        try? excludeFromBackup(directory(forBook: bookID))
    }

    public func deleteBook(_ bookID: String) throws {
        let dir = directory(forBook: bookID)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }

    public func diskUsage(forBook bookID: String) -> Int64 {
        Self.recursiveSize(of: directory(forBook: bookID), fileManager: fileManager)
    }

    public func totalDiskUsage(for bookIDs: some Sequence<String>) -> Int64 {
        bookIDs.reduce(Int64(0)) { $0 + diskUsage(forBook: $1) }
    }

    // MARK: - Paths

    private func pagesDirectory(forBook bookID: String) -> URL {
        directory(forBook: bookID).appendingPathComponent("pages", isDirectory: true)
    }

    private func manifestURL(forBook bookID: String) -> URL {
        directory(forBook: bookID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func recursiveSize(of url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    private static func fileName(forPage index: Int, mediaType: String) -> String {
        let padded = String(format: "%05d", index + 1)
        return "\(padded).\(fileExtension(forMediaType: mediaType))"
    }

    private static func fileExtension(forMediaType mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/bmp": "bmp"
        case "image/tiff": "tiff"
        default: "img"
        }
    }
}
