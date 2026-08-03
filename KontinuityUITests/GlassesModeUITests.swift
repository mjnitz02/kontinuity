//
//  GlassesModeUITests.swift
//  KontinuityUITests
//
//  Mode B (READER-DESIGN §3, PLAN phase 6), scoped deliberately to the
//  no-external-display iPad fallback path — XCUITest drives one app window
//  and can't attach to a second `UIWindowScene`'s external display, so the
//  real `UIWindowSceneSessionRoleExternalDisplayNonInteractive` connection
//  path stays a manual/simulator-Hardware-menu check, not a CI gate.
//
//  This is also the first hardware-keyboard XCUITest coverage in the repo
//  (`app.typeKey`) — nothing here confirms the pattern works before this file.
//
//  Touch in the fallback path is always live ("no blanket, nowhere else to
//  look" — READER-DESIGN §3), unlike the real external-display case where
//  `touchArmed` actually gates it, so this suite verifies touch works and
//  that `T` toggles the `touchArmed` flag (visible in the status label),
//  rather than a "touch does nothing until T" assertion that only applies
//  off the fallback path.
//

import KontinuityCore
import XCTest

final class GlassesModeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = UITestApp.launch(.connected)
    }

    override func tearDown() {
        // Orientation is simulator-wide state, not per-test.
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    @MainActor
    func testEnteringGlassesModeFromChromeShowsBandLayoutInLandscape() {
        enterGlassesMode()
        app.find(AID.glassesSurface).assertAppears("The band layout surface")
    }

    @MainActor
    func testArrowKeysAdvanceAndRetreatTheBandIndex() {
        enterGlassesMode()

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let afterAdvance = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(
            afterAdvance.label.hasPrefix("2 / "),
            "Right arrow should advance to band 2, got \(afterAdvance.label)"
        )

        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        let afterRetreat = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(
            afterRetreat.label.hasPrefix("1 / "),
            "Left arrow should retreat back to band 1, got \(afterRetreat.label)"
        )
    }

    @MainActor
    func testEscExitsGlassesModeAndTheReader() {
        enterGlassesMode()

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        app.find(AID.bookDetailTitle).assertAppears("Esc should exit glasses mode and the reader together")
    }

    @MainActor
    func testTappingTheRightQuarterAdvancesTheBandInFallbackMode() {
        enterGlassesMode()
        let surface = app.find(AID.glassesSurface).assertAppears("The band layout surface")

        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        let label = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(label.label.hasPrefix("2 / "), "Tapping the right quarter should advance, got \(label.label)")
    }

    /// `dx: 0.3` is inside the old thirds' right-of-centre paging zone but
    /// inside quarters' centre half — a passing tap at `dx: 0.85` alone isn't
    /// evidence the split actually changed, since that point is inside the
    /// right zone either way (PLAN 6B §E).
    @MainActor
    func testTappingNearCentreTogglesChromeRatherThanPagingUnderQuarters() {
        enterGlassesMode()
        let surface = app.find(AID.glassesSurface).assertAppears("The band layout surface")
        app.find(AID.glassesExit).assertAppears("Chrome visible on entry")

        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()

        XCTAssertFalse(
            app.find(AID.glassesExit).exists,
            "dx: 0.3 is inside quarters' centre half — it should toggle chrome, not page"
        )
    }

    @MainActor
    func testSwipeAdvancesAndRetreatsTheBandInFallbackMode() {
        enterGlassesMode()
        app.find(AID.glassesSurface).assertAppears("The band layout surface")

        app.swipeLeft()
        let afterSwipeLeft = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(
            afterSwipeLeft.label.hasPrefix("2 / "),
            "Swiping left should advance, got \(afterSwipeLeft.label)"
        )

        app.swipeRight()
        let afterSwipeRight = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(
            afterSwipeRight.label.hasPrefix("1 / "),
            "Swiping right should retreat, got \(afterSwipeRight.label)"
        )
    }

    @MainActor
    func testTKeyTogglesTheTouchArmedFlag() {
        enterGlassesMode()

        app.typeKey("t", modifierFlags: [])
        var label = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(label.label.contains("touch"), "T should arm touch, got \(label.label)")

        app.typeKey("t", modifierFlags: [])
        label = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertFalse(label.label.contains("touch"), "A second T should disarm touch, got \(label.label)")
    }

    @MainActor
    private func enterGlassesMode() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Windrunner's cell").tap()
        app.find(AID.bookRow(UITestFixture.unreadBookID)).assertAppears("The readable book row").tap()
        app.find(AID.bookDetailRead).assertAppears("The Read button").tap()
        app.find(AID.readerPageLabel).assertAppears("The reader's page indicator")

        XCUIDevice.shared.orientation = .landscapeLeft

        app.find(AID.readerGlassesModeButton).assertAppears("The glasses mode button").tap()
    }
}
