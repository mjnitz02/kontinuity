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
