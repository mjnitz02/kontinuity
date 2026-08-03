//
//  ReaderIPhoneUITests.swift
//  KontinuityUITests
//
//  PLAN 6B §B/§E: on an iPhone, landscape is Mode B — entered and left
//  automatically on rotation rather than from a chrome button — decided on
//  `verticalSizeClass == .compact` (READER-DESIGN §3's iPhone section). Runs
//  against whatever simulator the scheme is pointed at; `make test-ui-iphone`
//  is what actually points it at one (Makefile, `IPHONE_SIMULATOR_NAME`) —
//  the iPad lane stays the default and the CI gate.
//

import KontinuityCore
import XCTest

final class ReaderIPhoneUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = UITestApp.launch(.connected)
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    @MainActor
    func testPortraitIsModeAWithPagingAndSync() {
        openReader()

        let pageLabel = app.find(AID.readerPageLabel).assertAppears("Mode A's page indicator")
        XCTAssertEqual(pageLabel.label, "1 / 6", "Portrait should be Mode A, one page at a time.")

        app.swipeLeft()
        XCTAssertEqual(app.find(AID.readerPageLabel).label, "2 / 6", "Swiping should page forward in Mode A.")
    }

    /// Acceptance item 2: rotating mid-book shows the same page as its first
    /// band, not page 1 — gap 2 (PLAN 6B §C) reopened as the iPhone's
    /// *primary* way into Mode B rather than a chrome button. Asserts against
    /// the persistent chrome page label (`glassesPageLabel`), not the fading
    /// `glassesStatusLabel` — that one only appears after a keypress/band
    /// move, not on bare entry.
    ///
    /// The label is a whole-book flattened band index, not a per-page one
    /// (`GlassesReaderView.statusText`), so page 2's first band is band 5 —
    /// the fixture book's 800×1200 pages band 4-per-page at this simulator's
    /// landscape aspect (PLAN 6B's own band-count table). Band 1 would mean
    /// the rotation wrongly threw the reader back to the start of the book.
    @MainActor
    func testRotatingToLandscapeEntersModeBAtTheCurrentPage() {
        openReader()
        app.find(AID.readerPageLabel).assertAppears("Mode A's page indicator")
        app.swipeLeft() // page 2

        XCUIDevice.shared.orientation = .landscapeLeft

        let status = app.find(AID.glassesPageLabel).assertAppears("The chrome page label after rotating")
        XCTAssertFalse(
            status.label.hasPrefix("1 / "),
            "Should enter at page 2's first band, not band 0 of the book — got \(status.label)"
        )
    }

    /// Acceptance items 2 and 4: the round trip is position-preserving in
    /// both directions — the case most likely to look right and be wrong.
    @MainActor
    func testRotatingBackToPortraitResumesModeAOnTheSamePage() {
        openReader()
        app.find(AID.readerPageLabel).assertAppears("Mode A's page indicator")
        app.swipeLeft() // page 2
        app.swipeLeft() // page 3

        XCUIDevice.shared.orientation = .landscapeLeft
        app.find(AID.glassesPageLabel).assertAppears("The chrome page label after rotating")

        XCUIDevice.shared.orientation = .portrait

        let pageLabel = app.find(AID.readerPageLabel).assertAppears("Mode A's page indicator after rotating back")
        XCTAssertEqual(pageLabel.label, "3 / 6", "Rotating back to portrait should resume on the same page.")
    }

    /// There is no second mode to fall back to in landscape on an iPhone, so
    /// Exit's meaning is unchanged: it leaves the reader, not just Mode B
    /// (READER-DESIGN §3's iPhone section).
    @MainActor
    func testExitFromLandscapeLeavesTheReaderEntirely() {
        openReader()
        app.find(AID.readerPageLabel).assertAppears("Mode A's page indicator")

        XCUIDevice.shared.orientation = .landscapeLeft
        app.find(AID.glassesExit).assertAppears("The Exit control").tap()

        app.find(AID.bookDetailTitle).assertAppears("Exit should leave the reader, not fall back to Mode A")
    }

    @MainActor
    private func openReader() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Windrunner's cell").tap()
        // The compact iPhone viewport fits fewer rows before the fold than
        // the iPad does, so the target row's `LazyVStack` cell may not exist
        // yet — swipe until it does rather than assuming it's already on screen.
        let bookRow = app.find(AID.bookRow(UITestFixture.unreadBookID))
        for _ in 0 ..< 5 where !bookRow.exists {
            app.swipeUp()
        }
        bookRow.assertAppears("The readable book row").tap()
        app.find(AID.bookDetailRead).assertAppears("The Read button").tap()
    }
}
