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

    @MainActor
    func testLandscapePairsPagesIntoTwoUpSpreads() {
        openReader()
        app.find(AID.readerPageLabel).assertAppears("The reader's page indicator")

        XCUIDevice.shared.orientation = .landscapeLeft

        // 6 fixture pages, paired two-up in landscape (PageLayout §2) — 3
        // spreads instead of 6.
        let pageLabel = app.find(AID.readerPageLabel).assertAppears("The page indicator after rotating")
        XCTAssertEqual(pageLabel.label, "1 / 3", "Landscape should pair pages into two-up spreads.")
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

    @MainActor
    private func openReader() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Windrunner's cell").tap()
        app.find(AID.bookRow(UITestFixture.unreadBookID)).assertAppears("The readable book row").tap()
        app.find(AID.bookDetailRead).assertAppears("The Read button").tap()
    }
}
