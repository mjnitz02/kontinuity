//
//  KomgaReaderDTOs.swift
//  KontinuityCore
//
//  Wire types for the reader surface — OPDS v2 is the spine for reading.
//  Shapes taken from `WebPubGenerator.toManifestDivina` and checked against a
//  real manifest.
//
//  We deliberately don't decode `metadata.readingProgression` at all —
//  The reader pins LTR regardless, so there is nothing to do
//  with it yet, and it would just be another optional to get wrong.
//

import Foundation

public struct KomgaDivinaManifest: Decodable, Sendable {
    public let metadata: Metadata
    public let readingOrder: [KomgaPageLink]

    public struct Metadata: Decodable, Sendable {
        public let title: String
        public let numberOfPages: Int?

        public init(title: String, numberOfPages: Int? = nil) {
            self.title = title
            self.numberOfPages = numberOfPages
        }
    }

    public init(metadata: Metadata, readingOrder: [KomgaPageLink]) {
        self.metadata = metadata
        self.readingOrder = readingOrder
    }
}

/// One entry in `readingOrder`. `width`/`height` come from Komga's own analysis
/// and are what let the layout engine work before any image is fetched — but
/// they're absent until Komga has analysed the book, so both must be optional
/// rather than assumed present (the "zero/missing dimensions"
/// case exists because of exactly this).
public struct KomgaPageLink: Decodable, Sendable, Hashable {
    public let href: String
    public let type: String
    public let width: Int?
    public let height: Int?
    /// A converted variant Komga offers when the source format isn't one iOS is
    /// guaranteed to decode. Empty, not merely absent, when there
    /// is none — Komga only adds the key for non-recommended formats.
    public let alternate: [KomgaAlternateLink]

    public init(
        href: String,
        type: String,
        width: Int? = nil,
        height: Int? = nil,
        alternate: [KomgaAlternateLink] = []
    ) {
        self.href = href
        self.type = type
        self.width = width
        self.height = height
        self.alternate = alternate
    }

    private enum CodingKeys: String, CodingKey {
        case href, type, width, height, alternate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decode(String.self, forKey: .href)
        type = try container.decode(String.self, forKey: .type)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        alternate = try container.decodeIfPresent([KomgaAlternateLink].self, forKey: .alternate) ?? []
    }
}

public struct KomgaAlternateLink: Decodable, Sendable, Hashable {
    public let href: String
    public let type: String

    public init(href: String, type: String) {
        self.href = href
        self.type = type
    }
}
