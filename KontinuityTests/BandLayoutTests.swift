//
//  BandLayoutTests.swift
//  KontinuityTests
//
//  Mode B's band math (READER-DESIGN §4) — pure, so its trickiest cases
//  (even distribution, the fits-already boundary, degrading unknown
//  dimensions) are provable without a simulator, same reasoning as
//  PageLayoutTests.
//

import Testing
@testable import KontinuityCore

@Suite("BandLayout")
struct BandLayoutTests {
    /// A typical portrait manga page — aspect ≈ 0.66, matching KOMGA-API §2's
    /// measurement against a real 67-page CBZ.
    private static let portrait = PageGeometry(width: 800, height: 1200)
    /// A pre-made double-page spread: aspect > 1.
    private static let spread = PageGeometry(width: 2400, height: 1200)
    private static let unknown = PageGeometry(width: 0, height: 0)

    @Test("a page exactly the band height yields one band, not two")
    func exactFitYieldsOneBand() {
        // width-fit scale = 100/800 = 0.125, visibleHeight = 1200/0.125 = ...
        // choose a page whose height, once width-fit, exactly equals the
        // screen height: screenWidth 800, screenHeight 1200 -> visibleHeight
        // = 1200 = page.height exactly.
        let bands = BandLayout.bands(for: [Self.portrait], screenWidth: 800, screenHeight: 1200)
        #expect(bands == [Band(pageIndex: 0, rect: BandRect(x: 0, y: 0, width: 1, height: 1))])
    }

    @Test("a page shorter than the band height yields one whole-page band")
    func shorterThanBandHeightYieldsOneBand() {
        let bands = BandLayout.bands(for: [Self.portrait], screenWidth: 800, screenHeight: 2000)
        #expect(bands == [Band(pageIndex: 0, rect: BandRect(x: 0, y: 0, width: 1, height: 1))])
    }

    @Test("H = 3x visibleH distributes bands evenly with no overrun past the page")
    func evenDistributionNoOverrun() {
        // width-fit scale = screenWidth/800 = 1, so visibleHeight = screenHeight
        // directly. screenHeight 400 = a third of the 1200-tall page.
        let bands = BandLayout.bands(for: [Self.portrait], screenWidth: 800, screenHeight: 400, overlap: 0.08)
        #expect(bands.allSatisfy { $0.pageIndex == 0 })
        let ys = bands.map(\.rect.y)
        #expect(bands.count == 4)
        // Every step between consecutive bands is uniform.
        let steps = zip(ys, ys.dropFirst()).map { $1 - $0 }
        for step in steps.dropFirst() {
            #expect(abs(step - steps[0]) < 0.0001)
        }
        // The overlap between consecutive bands is at least the requested 8%.
        let heightFraction = bands[0].rect.height
        for step in steps {
            let overlapFraction = (heightFraction - step) / heightFraction
            #expect(overlapFraction >= 0.08 - 0.0001)
        }
        // The last band ends exactly at the bottom of the page, no gap or overrun.
        let last = bands[bands.count - 1]
        #expect(abs(last.rect.y + last.rect.height - 1) < 0.0001)
    }

    @Test("a double-spread page yields a single whole-page band")
    func doubleSpreadYieldsOneBand() {
        let bands = BandLayout.bands(for: [Self.spread], screenWidth: 800, screenHeight: 50)
        #expect(bands == [Band(pageIndex: 0, rect: BandRect(x: 0, y: 0, width: 1, height: 1))])
    }

    @Test("unknown dimensions degrade to a single whole-page band, not a division by zero")
    func unknownDimensionsDegradeToOneBand() {
        let bands = BandLayout.bands(for: [Self.unknown], screenWidth: 800, screenHeight: 50)
        #expect(bands == [Band(pageIndex: 0, rect: BandRect(x: 0, y: 0, width: 1, height: 1))])
    }

    @Test("rtl reverses page traversal order but never the within-page band order")
    func rtlReversesPageOrderOnly() {
        let pages = [Self.portrait, Self.portrait]
        let ltr = BandLayout.bands(for: pages, screenWidth: 800, screenHeight: 50, progression: .ltr)
        let rtl = BandLayout.bands(for: pages, screenWidth: 800, screenHeight: 50, progression: .rtl)

        let ltrPageOrder = ltr.map(\.pageIndex)
        let rtlPageOrder = rtl.map(\.pageIndex)
        #expect(ltrPageOrder.first == 0)
        #expect(rtlPageOrder.first == 1)

        // Within each page, the band y-order (top to bottom) is unchanged.
        let ltrPage0Ys = ltr.filter { $0.pageIndex == 0 }.map(\.rect.y)
        let rtlPage0Ys = rtl.filter { $0.pageIndex == 0 }.map(\.rect.y)
        #expect(ltrPage0Ys == rtlPage0Ys)
        #expect(ltrPage0Ys == ltrPage0Ys.sorted())
    }
}

/// `BandFlow.continuous` — PLAN §12. The case that matters is a web comic
/// sliced on a ruler rather than at panel gutters, where a page boundary lands
/// mid-panel and per-page banding can never show that panel whole.
@Suite("BandLayout continuous flow")
struct BandLayoutContinuousTests {
    /// Three times as tall as it is wide, so a square screen bands it into
    /// several and two of them concatenated span a boundary.
    private static let slice = PageGeometry(width: 100, height: 300)
    /// A slicer's leftover tail — short enough that one band swallows it whole
    /// (so it is never any band's *first* page) and, like the real thing,
    /// **wider than it is tall**, which `PageLayout.isDoubleSpread` would call
    /// a two-page spread.
    private static let remainder = PageGeometry(width: 100, height: 50)
    private static let portrait = PageGeometry(width: 800, height: 1200)
    private static let spread = PageGeometry(width: 2400, height: 1200)
    private static let unknown = PageGeometry(width: 0, height: 0)

    @Test("a band straddling a slice boundary carries a segment from each page")
    func boundaryBandCarriesBothPages() {
        let bands = BandLayout.bands(
            for: [Self.slice, Self.slice],
            screenWidth: 100,
            screenHeight: 100,
            flow: .continuous
        )
        // Strip is 6 screen-heights tall (2 pages x 3), so with 8% overlap:
        // ceil(5 / 0.92) + 1 = 7 bands, step 5/6.
        #expect(bands.count == 7)

        let straddling = bands.filter { $0.segments.count > 1 }
        #expect(straddling.count == 1)
        guard let band = straddling.first else { return }

        #expect(band.pageIndices == [0, 1])
        // The band's own page is the *first* it touches, which is what keeps
        // progression honest: this band is where page 0's last pixel row is
        // finally on screen.
        #expect(band.pageIndex == 0)
        // The upper page is left at its very bottom and the lower entered at
        // its very top — no gap and no repeat across the cut.
        #expect(abs(band.segments[0].rect.y + band.segments[0].rect.height - 1) < 0.0001)
        #expect(abs(band.segments[1].rect.y) < 0.0001)
    }

    @Test("the first and last bands sit flush against the ends of the whole strip")
    func stripEndsAreFlush() {
        let bands = BandLayout.bands(
            for: [Self.slice, Self.slice],
            screenWidth: 100,
            screenHeight: 100,
            flow: .continuous
        )
        let first = bands[0]
        #expect(first.pageIndex == 0)
        #expect(abs(first.rect.y) < 0.0001)

        let last = bands[bands.count - 1]
        let tail = last.segments[last.segments.count - 1]
        #expect(tail.pageIndex == 1)
        #expect(abs(tail.rect.y + tail.rect.height - 1) < 0.0001)
    }

    @Test("a page short enough to be swallowed whole is still reachable through touches(page:)")
    func swallowedPageIsStillAddressable() {
        let bands = BandLayout.bands(
            for: [Self.slice, Self.remainder, Self.slice],
            screenWidth: 100,
            screenHeight: 100,
            flow: .continuous
        )
        // The short page is never any band's first page...
        #expect(!bands.contains { $0.pageIndex == 1 })
        // ...but exactly one band does show it, in full.
        let showing = bands.filter { $0.touches(page: 1) }
        #expect(showing.count == 1)
        let segment = showing.first?.segments.first { $0.pageIndex == 1 }
        #expect(abs((segment?.rect.height ?? 0) - 1) < 0.0001)
    }

    @Test("an unanalysed page breaks the strip and stands alone")
    func unanalysedPageBreaksTheRun() {
        let bands = BandLayout.bands(
            for: [Self.slice, Self.unknown, Self.slice],
            screenWidth: 100,
            screenHeight: 100,
            flow: .continuous
        )
        // There's no height to place it at, so it can't join a strip: one
        // whole-page band, never banded with a neighbour.
        let whole = BandRect(x: 0, y: 0, width: 1, height: 1)
        #expect(bands.filter { $0.touches(page: 1) } == [Band(pageIndex: 1, rect: whole)])
        // And the two slices, separated by it, are never banded together.
        #expect(!bands.contains { $0.pageIndices.contains(0) && $0.pageIndices.contains(2) })
    }

    @Test("a tail slice wider than it is tall stays in the strip rather than being read as a spread")
    func wideTailSliceDoesNotBreakTheRun() {
        // `PageLayout.isDoubleSpread` is true for `remainder` — under
        // `.perPage` that's the right call, and under `.continuous` it would
        // cut the strip at exactly the boundary continuity exists for. The
        // dev library's fixed-slice web comic ends chunks on 900x801 pages,
        // aspect 1.12, so this is the common case and not a corner.
        let bands = BandLayout.bands(
            for: [Self.slice, Self.remainder],
            screenWidth: 100,
            screenHeight: 100,
            flow: .continuous
        )
        #expect(bands.contains { $0.pageIndices == [0, 1] })
    }

    @Test("a strip shorter than the screen becomes one band showing all of it")
    func shortStripIsASingleBand() {
        let bands = BandLayout.bands(
            for: [Self.remainder, Self.remainder],
            screenWidth: 100,
            screenHeight: 100,
            flow: .continuous
        )
        #expect(bands.count == 1)
        #expect(bands[0].pageIndices == [0, 1])
    }

    @Test("isLongStrip separates paged manga from web comics by median page aspect")
    func longStripDetection() {
        // Measured against the dev library (PLAN §12): every paged manga page
        // sits at 0.651 or above; the two web comics' medians are 0.510 and
        // 0.180.
        #expect(!BandLayout.isLongStrip([Self.portrait, Self.portrait, Self.portrait]))
        #expect(BandLayout.isLongStrip([Self.slice, Self.slice, Self.slice]))
        #expect(BandLayout.isLongStrip([PageGeometry(width: 940, height: 1844)]))
        #expect(!BandLayout.isLongStrip([PageGeometry(width: 1536, height: 2200)]))
        // Nothing to measure is not a web comic.
        #expect(!BandLayout.isLongStrip([]))
        #expect(!BandLayout.isLongStrip([Self.unknown]))
        // A cover or a spread doesn't get a vote — it would drag the median
        // toward "paged" on a book that is entirely strips otherwise.
        #expect(BandLayout.isLongStrip([Self.spread, Self.slice, Self.slice]))
    }

    @Test("resolvedFlow defaults to isLongStrip's guess and an override always wins")
    func resolvedFlowDefaultsAndOverrides() {
        let manga = [Self.portrait, Self.portrait, Self.portrait]
        let webComic = [Self.slice, Self.slice, Self.slice]

        #expect(BandLayout.resolvedFlow(for: manga, override: nil) == .perPage)
        #expect(BandLayout.resolvedFlow(for: webComic, override: nil) == .continuous)
        #expect(BandLayout.resolvedFlow(for: manga, override: .continuous) == .continuous)
        #expect(BandLayout.resolvedFlow(for: webComic, override: .perPage) == .perPage)
    }
}
