//
//  ContinuousScrollLayoutTests.swift
//  KontinuityTests
//
//  Mode A's continuous scroll math (PLAN §12, phase 9B) — pure, so the
//  offset↔page mapping is provable without a simulator, same reasoning as
//  PageLayoutTests/BandLayoutTests.
//

import Testing
@testable import KontinuityCore

@Suite("ContinuousScrollLayout")
struct ContinuousScrollLayoutTests {
    /// A typical portrait manga page — aspect ≈ 0.66.
    private static let portrait = PageGeometry(width: 800, height: 1200)
    private static let unknown = PageGeometry(width: 0, height: 0)

    @Test("pageHeight scales height to the target width, preserving aspect")
    func pageHeightScalesToWidth() {
        #expect(ContinuousScrollLayout.pageHeight(Self.portrait, width: 400) == 600)
        #expect(ContinuousScrollLayout.pageHeight(Self.portrait, width: 800) == 1200)
    }

    @Test("an unanalysed page degrades to a square placeholder rather than guessing an aspect")
    func unknownPageDegradesToSquare() {
        #expect(ContinuousScrollLayout.pageHeight(Self.unknown, width: 400) == 400)
    }

    @Test("a zero width never divides by zero")
    func zeroWidthIsSafe() {
        #expect(ContinuousScrollLayout.pageHeight(Self.portrait, width: 0) == 0)
    }

    @Test("offsets are cumulative, starting at zero")
    func offsetsAreCumulative() {
        let offsets = ContinuousScrollLayout.offsets(for: [100, 200, 50])
        #expect(offsets == [0, 100, 300])
    }

    @Test("offsets is empty for no pages")
    func offsetsEmptyForNoPages() {
        #expect(ContinuousScrollLayout.offsets(for: []).isEmpty)
    }

    @Test("currentPageIndex is 0 until the first page's bottom has passed the viewport top")
    func currentPageIndexStaysAtZeroUntilPassed() {
        let heights = [100.0, 200.0, 50.0]
        let offsets = ContinuousScrollLayout.offsets(for: heights)
        #expect(ContinuousScrollLayout.currentPageIndex(offsets: offsets, heights: heights, scrollOffset: 0) == 0)
        #expect(ContinuousScrollLayout.currentPageIndex(offsets: offsets, heights: heights, scrollOffset: 99) == 0)
    }

    @Test("currentPageIndex advances the instant a page's bottom edge passes the viewport top")
    func currentPageIndexAdvancesOnBoundary() {
        let heights = [100.0, 200.0, 50.0]
        let offsets = ContinuousScrollLayout.offsets(for: heights)
        #expect(ContinuousScrollLayout.currentPageIndex(offsets: offsets, heights: heights, scrollOffset: 100) == 1)
        #expect(ContinuousScrollLayout.currentPageIndex(offsets: offsets, heights: heights, scrollOffset: 250) == 1)
        #expect(ContinuousScrollLayout.currentPageIndex(offsets: offsets, heights: heights, scrollOffset: 300) == 2)
    }

    @Test("currentPageIndex never overruns past the last page")
    func currentPageIndexClampsToLastPage() {
        let heights = [100.0, 200.0]
        let offsets = ContinuousScrollLayout.offsets(for: heights)
        #expect(ContinuousScrollLayout.currentPageIndex(offsets: offsets, heights: heights, scrollOffset: 10000) == 1)
    }

    @Test("currentPageIndex is 0 for no pages")
    func currentPageIndexEmptyIsZero() {
        #expect(ContinuousScrollLayout.currentPageIndex(offsets: [], heights: [], scrollOffset: 0) == 0)
    }
}
