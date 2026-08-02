//
//  ZipFixtureBuilder.swift
//  KontinuityTests
//
//  A minimal ZIP writer — just enough of the format to produce archives
//  `CBZArchive` should be able to read, with stored or deflated entries.
//  Shared by `CBZArchiveTests` (format edge cases) and
//  `DownloadCoordinatorTests` (a whole-file download's happy path needs a
//  real archive behind the stubbed transport).
//

import Compression
import Foundation

enum ZipFixtureBuilder {
    struct Entry {
        let name: String
        let data: Data
        var storedData: Data?
        var method: UInt16 = 0

        var uncompressedSize: Int {
            data.count
        }

        var compressedBytes: Data {
            storedData ?? data
        }
    }

    static func make(entries: [Entry]) -> Data {
        var body = Data()
        var central = Data()
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(body.count)
            let nameBytes = Data(entry.name.utf8)
            let compressed = entry.compressedBytes

            body.appendUInt32(0x0403_4B50)
            body.appendUInt16(20) // version needed
            body.appendUInt16(0) // flags
            body.appendUInt16(entry.method)
            body.appendUInt16(0) // mod time
            body.appendUInt16(0) // mod date
            body.appendUInt32(0) // crc32 — unchecked by the reader
            body.appendUInt32(UInt32(compressed.count))
            body.appendUInt32(UInt32(entry.uncompressedSize))
            body.appendUInt16(UInt16(nameBytes.count))
            body.appendUInt16(0) // extra length
            body.append(nameBytes)
            body.append(compressed)
        }

        for (index, entry) in entries.enumerated() {
            let nameBytes = Data(entry.name.utf8)
            let compressed = entry.compressedBytes

            central.appendUInt32(0x0201_4B50)
            central.appendUInt16(20) // version made by
            central.appendUInt16(20) // version needed
            central.appendUInt16(0) // flags
            central.appendUInt16(entry.method)
            central.appendUInt16(0) // mod time
            central.appendUInt16(0) // mod date
            central.appendUInt32(0) // crc32
            central.appendUInt32(UInt32(compressed.count))
            central.appendUInt32(UInt32(entry.uncompressedSize))
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0) // extra length
            central.appendUInt16(0) // comment length
            central.appendUInt16(0) // disk number start
            central.appendUInt16(0) // internal attrs
            central.appendUInt32(0) // external attrs
            central.appendUInt32(UInt32(offsets[index]))
            central.append(nameBytes)
        }

        var archive = body
        let centralDirOffset = archive.count
        archive.append(central)
        archive.appendUInt32(0x0605_4B50)
        archive.appendUInt16(0) // disk number
        archive.appendUInt16(0) // disk with CD
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt32(UInt32(central.count))
        archive.appendUInt32(UInt32(centralDirOffset))
        archive.appendUInt16(0) // comment length
        return archive
    }

    /// Raw DEFLATE (no zlib/gzip wrapper) — the same shape `CBZArchive`
    /// decodes via `COMPRESSION_ZLIB`.
    static func deflate(_ data: Data) -> Data? {
        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: max(64, source.count * 2))
        let encodedCount = destination.withUnsafeMutableBufferPointer { destBuffer in
            source.withUnsafeBufferPointer { srcBuffer -> Int in
                guard let destBase = destBuffer.baseAddress, let srcBase = srcBuffer.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destBase, destBuffer.count,
                    srcBase, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard encodedCount > 0 else { return nil }
        return Data(destination.prefix(encodedCount))
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
