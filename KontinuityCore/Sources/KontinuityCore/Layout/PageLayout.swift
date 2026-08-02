//
//  PageLayout.swift
//  KontinuityCore
//
//  Pure page-layout math — no UIKit, fully unit-testable (READER-DESIGN §4).
//  `PageLayout` covers Mode A (iPad panel reading): `.fitPage` and `.spread`,
//  grouping whole pages into indices. `BandLayout` below is Mode B (glasses
//  reading, phase 6): it needs sub-page rects, not whole-page groups, so it's
//  a separate namespace rather than a third `LayoutMode` case shoehorned into
//  `spreads(for:mode:progression:)`'s `[PageSpread]` return shape.
//  `.continuous`/webtoon scrolling (READER-DESIGN §4's case table) is out of
//  scope — the library is paged CBZ manga, not webtoon strips, and
//  `ReadingProgression` has no `.ttb` case to drive it.
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

/// A rect in **fractional page-space** — 0...1 across the page's own width
/// and height, not raw pixels. Rendering only ever needs this multiplied
/// against the size of the already-decoded page image, so there's no need
/// to thread the page's pixel dimensions back out of this module.
public struct BandRect: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One full-bleed, readable-scale viewport within a single page — the unit
/// Mode B's reader walks through with a single integer index, the same way
/// Mode A walks `[PageSpread]` (READER-DESIGN §3-4).
public struct Band: Sendable, Hashable {
    public let pageIndex: Int
    public let rect: BandRect

    public init(pageIndex: Int, rect: BandRect) {
        self.pageIndex = pageIndex
        self.rect = rect
    }
}

/// Mode B's layout math (READER-DESIGN §3-4): fit page *width*, then walk
/// down the page in overlapping bands instead of shrinking the whole page to
/// fit a 16:9 external display. Pure — no UIKit, no screen queried directly;
/// the caller supplies the target size.
public enum BandLayout {
    /// Flattened across every page, in traversal order — `.rtl` reverses
    /// which page comes first, never the top-to-bottom order of bands
    /// within a page (same asymmetric rule `PageLayout.spreads` applies to
    /// pair order under `.rtl`).
    public static func bands(
        for pages: [PageGeometry],
        screenWidth: Double,
        screenHeight: Double,
        overlap: Double = 0.08,
        progression: ReadingProgression = .ltr
    ) -> [Band] {
        let order = progression == .rtl ? Array(pages.indices.reversed()) : Array(pages.indices)
        return order.flatMap { index in
            bandRects(for: pages[index], screenWidth: screenWidth, screenHeight: screenHeight, overlap: overlap)
                .map { Band(pageIndex: index, rect: $0) }
        }
    }

    /// A double-spread page or one with unknown dimensions never gets
    /// banded — same "stands alone" rule `PageLayout.spreads` uses, and the
    /// same fallback that keeps unknown/zero dimensions from dividing by
    /// zero (READER-DESIGN §4: "degrade to `.fitPage`").
    private static func bandRects(
        for page: PageGeometry,
        screenWidth: Double,
        screenHeight: Double,
        overlap: Double
    ) -> [BandRect] {
        let wholePage = [BandRect(x: 0, y: 0, width: 1, height: 1)]
        guard page.isKnown, !PageLayout.isDoubleSpread(page) else { return wholePage }

        let scale = screenWidth / page.width
        let visibleHeight = screenHeight / scale
        // The page already fits — one band, whether it's shorter than the
        // band height or lands exactly on it.
        guard visibleHeight < page.height else { return wholePage }

        let heightFraction = visibleHeight / page.height
        // Evenly distributed rather than a fixed step, so the last band
        // never ends up a stunted near-repeat of the one before it — every
        // step is the same size and the overlap is at least the requested
        // fraction everywhere.
        let bandCount = Int(((page.height - visibleHeight) / (visibleHeight * (1 - overlap))).rounded(.up)) + 1
        let step = (page.height - visibleHeight) / Double(bandCount - 1)
        return (0 ..< bandCount).map { bandIndex in
            BandRect(x: 0, y: Double(bandIndex) * step / page.height, width: 1, height: heightFraction)
        }
    }
}
