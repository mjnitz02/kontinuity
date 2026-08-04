//
//  PageLayoutTests.swift
//  KontinuityTests
//
//  The layout engine is pure and UIKit-free specifically so its trickiest cases
//  — spread re-phasing, unknown dimensions — are provable without a simulator
//  (READER-DESIGN §4).
//

import Testing
@testable import KontinuityCore

@Suite("PageLayout")
struct PageLayoutTests {
    /// A typical portrait manga page — aspect ≈ 0.66, matching KOMGA-API §2's
    /// measurement against a real 67-page CBZ.
    private static let portrait = PageGeometry(width: 800, height: 1200)
    /// A pre-made double-page spread: aspect > 1.
    private static let spread = PageGeometry(width: 2400, height: 1200)
    private static let unknown = PageGeometry(width: 0, height: 0)

    @Test("fitPage always yields one page per unit")
    func fitPageIsAlwaysSingle() {
        let pages = Array(repeating: Self.portrait, count: 5)
        let spreads = PageLayout.spreads(for: pages, mode: .fitPage)
        #expect(spreads == (0 ..< 5).map { PageSpread([$0]) })
    }

    @Test("spread pairs consecutive portrait pages")
    func spreadPairsPortraitPages() {
        let pages = Array(repeating: Self.portrait, count: 4)
        let spreads = PageLayout.spreads(for: pages, mode: .spread)
        #expect(spreads == [PageSpread([0, 1]), PageSpread([2, 3])])
    }

    @Test("a double-spread page stands alone and re-phases subsequent pairing")
    func doubleSpreadRePhasesPairing() {
        // page 0 alone (odd count so far), page 1 is the spread and stands
        // alone regardless, pages 2/3 pair again afterward.
        let pages = [Self.portrait, Self.spread, Self.portrait, Self.portrait]
        let spreads = PageLayout.spreads(for: pages, mode: .spread)
        #expect(spreads == [PageSpread([0]), PageSpread([1]), PageSpread([2, 3])])
    }

    @Test("an unknown-dimension page never participates in a pair")
    func unknownDimensionsNeverPair() {
        let pages = [Self.portrait, Self.unknown, Self.portrait, Self.portrait]
        let spreads = PageLayout.spreads(for: pages, mode: .spread)
        #expect(spreads == [PageSpread([0]), PageSpread([1]), PageSpread([2, 3])])
    }

    @Test("rtl reverses the within-pair order only")
    func rtlReversesWithinPairOrder() {
        let pages = Array(repeating: Self.portrait, count: 4)
        let ltr = PageLayout.spreads(for: pages, mode: .spread, progression: .ltr)
        let rtl = PageLayout.spreads(for: pages, mode: .spread, progression: .rtl)

        #expect(ltr == [PageSpread([0, 1]), PageSpread([2, 3])])
        #expect(rtl == [PageSpread([1, 0]), PageSpread([3, 2])])
        // The overall page sequence — which spread comes first — is untouched.
        #expect(rtl.count == ltr.count)
    }

    @Test("isDoubleSpread")
    func doubleSpreadDetection() {
        #expect(!PageLayout.isDoubleSpread(Self.portrait))
        #expect(PageLayout.isDoubleSpread(Self.spread))
        #expect(!PageLayout.isDoubleSpread(Self.unknown))
    }
}
