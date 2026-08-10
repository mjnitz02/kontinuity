//
//  CBZArchive.swift
//  KontinuityCore
//
//  A CBZ is a plain ZIP of page images. Rather than take a third-party
//  dependency for something this small, we parse the ZIP central directory
//  ourselves and decompress DEFLATE entries with Apple's own `Compression`
//  framework (`COMPRESSION_ZLIB`, which — despite the name — implements raw
//  DEFLATE, exactly what the ZIP format stores). No encryption, no ZIP64: CBZs
//  in the wild don't use either, and Komga's own scanner wouldn't produce one.
//
//  The archive carries no page-order metadata of its own — only filenames.
//  Komga's DIVINA manifest is the source of truth for order (the download
//  it first), so this only needs to extract pages in the same order Komga's
//  own scanner would see them: a natural, numeric-aware sort of image-suffixed
//  entries, with junk (ComicInfo.xml, __MACOSX/, dotfiles, directory entries)
//  filtered out. `LiveKomgaTests` checks this assumption against a real
//  archive by comparing extracted count to the manifest's page count.
//

import Compression
import Foundation

public enum CBZArchiveError: Error, Equatable, Sendable {
    case notAZipArchive
    case unsupportedCompression(method: Int)
    case corruptEntry(name: String)
    case truncatedData
}

public enum CBZArchive {
    /// Decompressed page images, in natural filename order. Non-image entries
    /// (metadata files, junk directories) are dropped rather than surfaced as
    /// pages.
    public static func extractImagePages(from data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        let entries = try centralDirectoryEntries(bytes)
        let pages = entries
            .filter { isImagePage($0.name) }
            .sorted { naturalOrder($0.name, $1.name) }
        return try pages.map { try extract($0, bytes: bytes) }
    }

    // MARK: - Central directory

    private struct RawEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50

    private static func centralDirectoryEntries(_ bytes: [UInt8]) throws -> [RawEntry] {
        let eocdOffset = try findEOCD(bytes)
        let totalEntries = Int(readUInt16(bytes, at: eocdOffset + 10))
        var cdOffset = Int(readUInt32(bytes, at: eocdOffset + 16))

        var entries: [RawEntry] = []
        entries.reserveCapacity(totalEntries)
        for _ in 0 ..< totalEntries {
            guard cdOffset + 46 <= bytes.count, readUInt32(bytes, at: cdOffset) == centralDirectorySignature else {
                throw CBZArchiveError.notAZipArchive
            }
            let method = readUInt16(bytes, at: cdOffset + 10)
            let compressedSize = Int(readUInt32(bytes, at: cdOffset + 20))
            let uncompressedSize = Int(readUInt32(bytes, at: cdOffset + 24))
            let nameLength = Int(readUInt16(bytes, at: cdOffset + 28))
            let extraLength = Int(readUInt16(bytes, at: cdOffset + 30))
            let commentLength = Int(readUInt16(bytes, at: cdOffset + 32))
            let localHeaderOffset = Int(readUInt32(bytes, at: cdOffset + 42))

            let nameStart = cdOffset + 46
            guard nameStart + nameLength <= bytes.count else { throw CBZArchiveError.notAZipArchive }
            let name = String(bytes: bytes[nameStart ..< nameStart + nameLength], encoding: .utf8) ?? ""

            entries.append(RawEntry(
                name: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            cdOffset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Scans backward for the End Of Central Directory record. A ZIP comment
    /// (up to 65535 bytes) can follow it, so this isn't just "the last 22
    /// bytes" — the comment-length field is checked against the actual file
    /// length to reject a false-positive signature match inside file data.
    private static func findEOCD(_ bytes: [UInt8]) throws -> Int {
        let minSize = 22
        guard bytes.count >= minSize else { throw CBZArchiveError.notAZipArchive }
        let searchFloor = max(0, bytes.count - minSize - 65535)
        var offset = bytes.count - minSize
        while offset >= searchFloor {
            if readUInt32(bytes, at: offset) == eocdSignature {
                let commentLength = Int(readUInt16(bytes, at: offset + 20))
                if offset + minSize + commentLength == bytes.count {
                    return offset
                }
            }
            offset -= 1
        }
        throw CBZArchiveError.notAZipArchive
    }

    // MARK: - Per-entry extraction

    /// The central directory's sizes are authoritative, but the local header
    /// preceding the actual bytes can carry a different name/extra length
    /// than the central directory copy — so the data offset is computed from
    /// the local header, not assumed.
    private static func extract(_ entry: RawEntry, bytes: [UInt8]) throws -> Data {
        guard entry.localHeaderOffset + 30 <= bytes.count,
              readUInt32(bytes, at: entry.localHeaderOffset) == localFileHeaderSignature
        else {
            throw CBZArchiveError.corruptEntry(name: entry.name)
        }
        let nameLength = Int(readUInt16(bytes, at: entry.localHeaderOffset + 26))
        let extraLength = Int(readUInt16(bytes, at: entry.localHeaderOffset + 28))
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard dataStart + entry.compressedSize <= bytes.count else {
            throw CBZArchiveError.truncatedData
        }
        let compressed = Array(bytes[dataStart ..< dataStart + entry.compressedSize])

        switch entry.compressionMethod {
        case 0:
            return Data(compressed)
        case 8:
            return try inflate(compressed, uncompressedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw CBZArchiveError.unsupportedCompression(method: Int(entry.compressionMethod))
        }
    }

    private static func inflate(_ compressed: [UInt8], uncompressedSize: Int, name: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        guard !compressed.isEmpty else { throw CBZArchiveError.corruptEntry(name: name) }

        var destination = [UInt8](repeating: 0, count: uncompressedSize)
        let decodedCount = destination.withUnsafeMutableBufferPointer { destBuffer in
            compressed.withUnsafeBufferPointer { srcBuffer -> Int in
                guard let destBase = destBuffer.baseAddress, let srcBase = srcBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase, uncompressedSize,
                    srcBase, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == uncompressedSize else {
            throw CBZArchiveError.corruptEntry(name: name)
        }
        return Data(destination)
    }

    // MARK: - Byte reads

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - Page filtering / ordering

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif"]

    private static func isImagePage(_ name: String) -> Bool {
        guard !name.hasSuffix("/"), !name.hasPrefix("__MACOSX/") else { return false }
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        guard !lastComponent.hasPrefix(".") else { return false }
        return imageExtensions.contains((lastComponent as NSString).pathExtension.lowercased())
    }

    /// Numeric-aware comparison so `page2.jpg` sorts before `page10.jpg` —
    /// matching Komga's own natural sort of archive entries, not lexicographic
    /// order.
    static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        var lIndex = lhs.startIndex
        var rIndex = rhs.startIndex
        while lIndex < lhs.endIndex, rIndex < rhs.endIndex {
            let lChar = lhs[lIndex]
            let rChar = rhs[rIndex]
            if lChar.isNumber, rChar.isNumber {
                let lRun = lhs[lIndex...].prefix { $0.isNumber }
                let rRun = rhs[rIndex...].prefix { $0.isNumber }
                let lValue = Int(lRun) ?? 0
                let rValue = Int(rRun) ?? 0
                if lValue != rValue {
                    return lValue < rValue
                }
                if lRun.count != rRun.count {
                    return lRun.count < rRun.count
                }
                lIndex = lhs.index(lIndex, offsetBy: lRun.count)
                rIndex = rhs.index(rIndex, offsetBy: rRun.count)
            } else if lChar != rChar {
                return lChar < rChar
            } else {
                lIndex = lhs.index(after: lIndex)
                rIndex = rhs.index(after: rIndex)
            }
        }
        if lIndex < lhs.endIndex {
            return false
        }
        if rIndex < rhs.endIndex {
            return true
        }
        return false
    }
}
