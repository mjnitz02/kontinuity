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
//  `BandLayout` also covers the long-strip/web comic case (PLAN §12) via
//  `BandFlow.continuous`, which bands *across* page boundaries — Mode A's own
//  continuous scroll surface is separate work and doesn't live here.
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

/// The part of one page that a band shows. Under `.perPage` a band always has
/// exactly one of these; under `.continuous` a band straddling a slice
/// boundary has two (or more, for pages shorter than the band itself).
public struct BandSegment: Sendable, Hashable {
    public let pageIndex: Int
    public let rect: BandRect

    public init(pageIndex: Int, rect: BandRect) {
        self.pageIndex = pageIndex
        self.rect = rect
    }
}

/// One full-bleed, readable-scale viewport — the unit Mode B's reader walks
/// through with a single integer index, the same way Mode A walks
/// `[PageSpread]` (READER-DESIGN §3-4).
public struct Band: Sendable, Hashable {
    /// In render order, top to bottom. Never empty.
    public let segments: [BandSegment]

    public init(segments: [BandSegment]) {
        self.segments = segments
    }

    /// The single-segment case, which is every band under `.perPage` — kept as
    /// a memberwise-shaped initializer so the common construction (and the
    /// tests written against it) doesn't have to spell out a one-element array.
    public init(pageIndex: Int, rect: BandRect) {
        self.init(segments: [BandSegment(pageIndex: pageIndex, rect: rect)])
    }

    /// **The first page this band touches**, which is the definition that keeps
    /// progression honest across a slice boundary: the last band carrying page
    /// *P* is then the one that also carries the top of *P+1*, i.e. the band in
    /// which *P*'s final pixel row is genuinely on screen. Calling the
    /// *dominant* or *last* page the band's page would mark *P* read while a
    /// sliver of it had never been displayed, which is the exact
    /// over-reporting READER-DESIGN §5 exists to prevent.
    public var pageIndex: Int {
        segments[0].pageIndex
    }

    /// The crop within `pageIndex` — what a single-segment band renders, and
    /// the first stacked slice of a multi-segment one.
    public var rect: BandRect {
        segments[0].rect
    }

    public var pageIndices: [Int] {
        segments.map(\.pageIndex)
    }

    /// Membership by *any* segment, not just `pageIndex`. A page shorter than
    /// the band height can be swallowed whole by a single band under
    /// `.continuous` and so never be any band's first page — matching on
    /// `pageIndex` alone would leave it with no band index at all.
    public func touches(page: Int) -> Bool {
        segments.contains { $0.pageIndex == page }
    }
}

/// Whether bands stop at page boundaries or run through them (PLAN §12).
public enum BandFlow: Sendable, Hashable {
    /// Every band lies within one page. Right for paged manga, where a page
    /// boundary is a deliberate artistic break.
    case perPage
    /// Consecutive pages are treated as one continuous strip. Right for a
    /// web comic sliced into fixed-height chunks, where a page boundary lands
    /// mid-panel and per-page banding can never show that panel whole.
    case continuous
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
        progression: ReadingProgression = .ltr,
        flow: BandFlow = .perPage
    ) -> [Band] {
        let order = progression == .rtl ? Array(pages.indices.reversed()) : Array(pages.indices)
        switch flow {
        case .perPage:
            return order.flatMap { index in
                bandRects(for: pages[index], screenWidth: screenWidth, screenHeight: screenHeight, overlap: overlap)
                    .map { Band(pageIndex: index, rect: $0) }
            }
        case .continuous:
            return continuousBands(
                for: pages,
                order: order,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                overlap: overlap
            )
        }
    }

    /// Median page aspect (width/height) below this reads as a long strip
    /// rather than a page. Measured against the dev library (PLAN §12): every
    /// paged manga page sits at 0.651 or above, while the two web comics'
    /// medians are 0.510 (gutter-sliced) and 0.180 (fixed 5000px slices). The
    /// gap is wide enough to key off, but this is still a heuristic over
    /// scraped content, so it's a *default* the reader can override, not a
    /// verdict.
    public static let longStripAspectThreshold = 0.6

    /// The default `BandFlow` for a book, from manifest geometry alone —
    /// Komga's `readingDirection` is `""` (unset) on the web comics in the dev
    /// library exactly as it is on the manga, so READER-DESIGN §4's "`ttb`
    /// progression" trigger doesn't exist in practice and geometry is the only
    /// signal actually present.
    public static func isLongStrip(_ pages: [PageGeometry]) -> Bool {
        let aspects = pages
            .filter { $0.isKnown && !PageLayout.isDoubleSpread($0) }
            .map { $0.width / $0.height }
            .sorted()
        guard !aspects.isEmpty else { return false }
        let middle = aspects.count / 2
        let median = aspects.count.isMultiple(of: 2)
            ? (aspects[middle - 1] + aspects[middle]) / 2
            : aspects[middle]
        return median < longStripAspectThreshold
    }

    /// The one place `override ?? isLongStrip(...)` is spelled out — Mode B's
    /// `enter()` and Mode A's `ReaderModel` both need exactly this decision
    /// (PLAN §12: "Mode A should read the same override, not invent a second
    /// one"), and a heuristic default plus a per-series correction is worth
    /// keeping as one pure, tested function rather than two copies that could
    /// drift.
    public static func resolvedFlow(for pages: [PageGeometry], override: BandFlow?) -> BandFlow {
        override ?? (isLongStrip(pages) ? .continuous : .perPage)
    }

    /// A double-spread page or one with unknown dimensions never gets
    /// banded — same "stands alone" rule `PageLayout.spreads` uses, and the
    /// same fallback that keeps unknown/zero dimensions from dividing by
    /// zero (READER-DESIGN §4: "degrade to `.fitPage`").
    private static let wholePageRect = BandRect(x: 0, y: 0, width: 1, height: 1)

    /// Below this, a segment is the arithmetic residue of a band landing
    /// exactly on a page boundary rather than a sliver anyone could see.
    private static let boundaryEpsilon = 1e-9

    private static func bandRects(
        for page: PageGeometry,
        screenWidth: Double,
        screenHeight: Double,
        overlap: Double
    ) -> [BandRect] {
        let wholePage = [wholePageRect]
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

    // MARK: - Continuous flow

    /// Splits `order` into runs of consecutive placeable pages and bands each
    /// run as one virtual strip.
    ///
    /// Only *unknown* dimensions break a run — deliberately **not**
    /// `.perPage`'s "a double-page spread stands alone" rule, which is wrong
    /// here in a way real content hits immediately: a slicer's tail chunk is
    /// routinely wider than it is tall (900x801 in the dev library's
    /// fixed-slice web comic, aspect 1.12), and `isDoubleSpread` would call
    /// that a two-page spread and cut the strip at exactly the boundary
    /// continuity is for. A strip has no spreads to detect; if a paged book
    /// lands here it's a misdetection the reader's own toggle corrects.
    private static func continuousBands(
        for pages: [PageGeometry],
        order: [Int],
        screenWidth: Double,
        screenHeight: Double,
        overlap: Double
    ) -> [Band] {
        // Width-fit means the screen's own aspect *is* the visible height once
        // every page is normalised to width 1.
        let visibleHeight = screenHeight / screenWidth
        var result: [Band] = []
        var run: [Int] = []

        for index in order {
            guard pages[index].isKnown else {
                result += stripBands(for: run, pages: pages, visibleHeight: visibleHeight, overlap: overlap)
                run = []
                result.append(Band(pageIndex: index, rect: wholePageRect))
                continue
            }
            run.append(index)
        }
        result += stripBands(for: run, pages: pages, visibleHeight: visibleHeight, overlap: overlap)
        return result
    }

    /// One run, banded with the same even-distribution formula `bandRects`
    /// uses — only the coordinate space differs: the strip's total normalised
    /// height in place of a single page's.
    private static func stripBands(
        for indices: [Int],
        pages: [PageGeometry],
        visibleHeight: Double,
        overlap: Double
    ) -> [Band] {
        guard !indices.isEmpty else { return [] }
        // Every page scaled to width 1, so a run whose pages differ in source
        // width still shares one coordinate space — the same normalisation the
        // renderer applies when it width-fits each page to the container.
        let heights = indices.map { pages[$0].height / pages[$0].width }
        var offsets: [Double] = []
        var total = 0.0
        for height in heights {
            offsets.append(total)
            total += height
        }

        // The run-scale counterpart of "the page already fits": show all of it.
        guard visibleHeight < total else {
            return [Band(segments: indices.map { BandSegment(pageIndex: $0, rect: wholePageRect) })]
        }

        let bandCount = Int(((total - visibleHeight) / (visibleHeight * (1 - overlap))).rounded(.up)) + 1
        let step = (total - visibleHeight) / Double(bandCount - 1)
        return (0 ..< bandCount).map { bandIndex in
            let top = Double(bandIndex) * step
            let segments = segments(
                from: top,
                to: top + visibleHeight,
                indices: indices,
                heights: heights,
                offsets: offsets
            )
            return Band(segments: segments)
        }
    }

    /// The pages overlapping `top ..< bottom` in strip space, each cropped
    /// back into its own fractional page-space.
    private static func segments(
        from top: Double,
        to bottom: Double,
        indices: [Int],
        heights: [Double],
        offsets: [Double]
    ) -> [BandSegment] {
        var result: [BandSegment] = []
        for position in indices.indices {
            let pageTop = offsets[position]
            let pageBottom = pageTop + heights[position]
            guard pageBottom > top, pageTop < bottom else { continue }
            let visibleTop = max(top, pageTop)
            let height = (min(bottom, pageBottom) - visibleTop) / heights[position]
            guard height > boundaryEpsilon else { continue }
            let rect = BandRect(x: 0, y: (visibleTop - pageTop) / heights[position], width: 1, height: height)
            result.append(BandSegment(pageIndex: indices[position], rect: rect))
        }
        // `Band` promises a non-empty `segments`; a band that overlaps nothing
        // could only come from arithmetic that already went wrong, so degrade
        // rather than trap in `segments[0]`.
        return result.isEmpty ? [BandSegment(pageIndex: indices[0], rect: wholePageRect)] : result
    }
}

/// Mode A's continuous scroll surface (PLAN §12, phase 9B) — a vertical
/// `ScrollView` of width-fit pages replacing the paging `TabView` when
/// `BandLayout.resolvedFlow` says `.continuous`. Pure math only: mapping the
/// manifest's per-page geometry to cumulative on-screen offsets and back.
/// Reserving each page's height from the manifest *before* its image loads
/// is what keeps the scroll position from jumping under the reader as images
/// land, so this never touches a decoded/rendered frame to get an answer.
public enum ContinuousScrollLayout {
    /// A page's height once width-fit to `width`. A page Komga hasn't
    /// analysed degrades to a square placeholder — the same "stands alone,
    /// nothing to detect" treatment `PageLayout`/`BandLayout` give an unknown
    /// page elsewhere, rather than guessing its aspect from neighbours.
    public static func pageHeight(_ page: PageGeometry, width: Double) -> Double {
        guard page.isKnown, width > 0 else { return width }
        return width * page.height / page.width
    }

    /// The top offset of every page, in scroll order — `offsets.count ==
    /// heights.count`, and `offsets[0] == 0`.
    public static func offsets(for heights: [Double]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(heights.count)
        var total = 0.0
        for height in heights {
            result.append(total)
            total += height
        }
        return result
    }

    /// The page currently being read: the first whose bottom edge has *not*
    /// yet scrolled past the top of the viewport. Equivalently, this is the
    /// page you determine "has passed" by testing each one's bottom against
    /// the scroll offset in turn — the same "count as read only once truly
    /// passed" rule READER-DESIGN §5 already applies to Mode B's bands,
    /// applied here to a scroll offset instead of a band index. Never reports
    /// a page as current until its predecessor has genuinely scrolled by, so
    /// this doesn't over-report the moment the reader opens.
    public static func currentPageIndex(offsets: [Double], heights: [Double], scrollOffset: Double) -> Int {
        guard !offsets.isEmpty else { return 0 }
        for index in offsets.indices where offsets[index] + heights[index] > scrollOffset {
            return index
        }
        return offsets.count - 1
    }
}
