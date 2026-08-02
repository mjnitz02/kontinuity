//
//  PageLayout.swift
//  KontinuityCore
//
//  Pure page-layout math — no UIKit, fully unit-testable (READER-DESIGN §4).
//  Scoped to Mode A (iPad panel reading) only: `.fitPage` and `.spread`.
//  `.bands`/`.continuous` (Mode B, glasses reading) arrive with phase 6 rather
//  than being stubbed out now.
//

import Foundation

/// A page's dimensions in the DIVINA manifest, before any image is fetched.
public struct PageGeometry: Sendable, Hashable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// False when Komga hasn't analysed this page yet — a manifest entry with
    /// no `width`/`height` (KOMGA-API §2). Such a page can't be paired into a
    /// spread since its aspect ratio is unknown.
    public var isKnown: Bool {
        width > 0 && height > 0
    }
}

/// Pinned to `.ltr` at every call site today (READER-DESIGN §1); the parameter
/// exists so flipping it later is a real switch, not a rewrite.
public enum ReadingProgression: Sendable {
    case ltr
    case rtl
}

public enum LayoutMode: Sendable {
    /// One page per unit, always — the portrait default.
    case fitPage
    /// Two consecutive portrait pages per unit in landscape, except a page
    /// that's itself a double-page spread, which stands alone.
    case spread
}

/// One or two page indices shown together as a single visual/turnable unit.
public struct PageSpread: Sendable, Hashable {
    public let pageIndices: [Int]

    public init(_ pageIndices: [Int]) {
        self.pageIndices = pageIndices
    }
}

public enum PageLayout {
    /// Groups `pages` into the units the reader pages through.
    public static func spreads(
        for pages: [PageGeometry],
        mode: LayoutMode,
        progression: ReadingProgression = .ltr
    ) -> [PageSpread] {
        switch mode {
        case .fitPage:
            pages.indices.map { PageSpread([$0]) }
        case .spread:
            spreadPairs(for: pages, progression: progression)
        }
    }

    /// A page whose aspect ratio marks it as a pre-made double-page spread
    /// rather than a single portrait page (READER-DESIGN §2). Unknown
    /// dimensions are never treated as a spread — there's nothing to detect.
    public static func isDoubleSpread(_ page: PageGeometry) -> Bool {
        page.isKnown && page.width / page.height > 1.0
    }

    private static func spreadPairs(for pages: [PageGeometry], progression: ReadingProgression) -> [PageSpread] {
        var result: [PageSpread] = []
        var index = 0
        while index < pages.count {
            let page = pages[index]
            // A double-spread page or one with unknown dimensions always
            // stands alone — this is what re-phases the pairing of whatever
            // follows it.
            guard page.isKnown, !isDoubleSpread(page) else {
                result.append(PageSpread([index]))
                index += 1
                continue
            }

            let nextIndex = index + 1
            if nextIndex < pages.count, pages[nextIndex].isKnown, !isDoubleSpread(pages[nextIndex]) {
                let pair = progression == .rtl ? [nextIndex, index] : [index, nextIndex]
                result.append(PageSpread(pair))
                index += 2
            } else {
                result.append(PageSpread([index]))
                index += 1
            }
        }
        return result
    }
}
