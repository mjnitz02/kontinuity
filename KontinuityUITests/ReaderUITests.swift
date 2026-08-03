//
//  ReaderUITests.swift
//  KontinuityUITests
//
//  The phase-3 reader path against the stub's fixture pages (StubKomgaService).
//  Coordinate-tapping the page's tap zones would need to disambiguate between
//  the current and adjacent pages the TabView(.page) style keeps instantiated
//  for the swipe transition — all sharing the same accessibility identifier —
//  so this drives paging with the native swipe gesture instead, which is
//  unambiguous and is the primary way a user actually turns pages anyway.
//

import KontinuityCore
import UIKit
import XCTest

final class ReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = UITestApp.launch(.connected)
    }

    override func tearDown() {
        // Orientation is simulator-wide state, not per-test — reset it so a
        // failure here can't leave subsequent tests running landscape.
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    @MainActor
    func testOpeningAReadableBookShowsTheReaderAndSwipingAdvancesThePage() {
        openReader()

        let pageLabel = app.find(AID.readerPageLabel).assertAppears("The reader's page indicator")
        // The fixture book has 6 pages (StubKomgaService); the reader opens on
        // page 1 since it's unread.
        XCTAssertEqual(pageLabel.label, "1 / 6", "Should open on the first page.")

        app.swipeLeft()

        XCTAssertEqual(
            app.find(AID.readerPageLabel).label, "2 / 6",
            "Swiping should advance to the next page."
        )

        app.find(AID.readerDone).assertAppears("The Done button").tap()

        app.find(AID.bookDetailTitle).assertAppears("Dismissing the reader returns to book detail")
    }

    /// Spread pairing is iPad-only behaviour as of PLAN 6B: an iPhone's
    /// landscape is compact height, which is Mode B, not Mode A's `.spread`
    /// (READER-DESIGN §3's iPhone section) — `ReaderIPhoneUITests` covers
    /// that lane instead. Skipped rather than left to fail if this ever runs
    /// against a phone destination.
    @MainActor
    func testLandscapePairsPagesIntoTwoUpSpreads() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Landscape spread pairing is iPad-only (PLAN 6B) — see ReaderIPhoneUITests for the iPhone lane."
        )
        openReader()
        app.find(AID.readerPageLabel).assertAppears("The reader's page indicator")

        XCUIDevice.shared.orientation = .landscapeLeft

        // 6 fixture pages, paired two-up in landscape (PageLayout §2) — 3
        // spreads instead of 6.
        let pageLabel = app.find(AID.readerPageLabel).assertAppears("The page indicator after rotating")
        XCTAssertEqual(pageLabel.label, "1 / 3", "Landscape should pair pages into two-up spreads.")
    }

    /// PLAN 6B §D/§E: quarters, not thirds — `dx: 0.3` is inside the old
    /// thirds' paging zone but inside quarters' centre half, so it's the
    /// coordinate that actually distinguishes the two rather than merely
    /// being consistent with either. Taps `app` directly rather than the
    /// `reader.page` identifier — the paging `TabView` keeps adjacent pages
    /// instantiated under that same identifier for the swipe transition
    /// (this file's header comment), which coordinate-tapping would land on
    /// ambiguously.
    ///
    /// Reads `readerPageLabel` through `waitForPageLabel` rather than
    /// immediately after `.tap()` — `ZoomableImageView`'s single tap is
    /// gated behind `require(toFail: doubleTap)` (phase 3), so recognizing it
    /// as a genuine single tap rather than the first half of a double tap
    /// takes UIKit's own double-tap window, not just this event loop turn.
    @MainActor
    func testTapZonesPageAndToggleChromeUnderQuarters() {
        openReader()
        app.find(AID.readerPageLabel).assertAppears("The reader's page indicator")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(
            waitForPageLabel("2 / 6"),
            "Tapping the right quarter should advance, got \(app.find(AID.readerPageLabel).label)"
        )

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(
            waitForPageLabel("1 / 6"),
            "Tapping the left quarter should retreat, got \(app.find(AID.readerPageLabel).label)"
        )

        app.find(AID.readerDone).assertAppears("Chrome visible by default")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(
            app.find(AID.readerDone).waitForNonExistence(timeout: 2),
            "dx: 0.3 is inside quarters' centre half — it should toggle chrome, not page."
        )
    }

    @MainActor
    func testPinchAndDoubleTapDoNotCrashTheReader() {
        openReader()
        let page = app.find(AID.readerPage).assertAppears("The reader's zoomable page surface")

        page.pinch(withScale: 2, velocity: 1)
        page.doubleTap()
        page.doubleTap()

        // Still in the reader on the same page — a crash, or a gesture stuck
        // mid-zoom eating later input, would fail one of these lookups.
        XCTAssertEqual(app.find(AID.readerPageLabel).label, "1 / 6")
    }

    /// Polls rather than reading `.label` once — see the doc comment on
    /// `testTapZonesPageAndToggleChromeUnderQuarters`.
    @MainActor
    private func waitForPageLabel(_ expected: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.find(AID.readerPageLabel).label == expected {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    @MainActor
    private func openReader() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Windrunner's cell").tap()
        app.find(AID.bookRow(UITestFixture.unreadBookID)).assertAppears("The readable book row").tap()
        app.find(AID.bookDetailRead).assertAppears("The Read button").tap()
    }
}
