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
//  look" — READER-DESIGN §3); this suite verifies it works via tap and
//  swipe.
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

    /// Space is the binding most used in practice (one thumb, eyes closed),
    /// and it shares the arrow keys' delivery path — both are keys iPadOS
    /// claims for itself unless `wantsPriorityOverSystemBehavior` says
    /// otherwise, which is why paging by keyboard looked half-broken on
    /// device while `T`, `A` and Esc all worked.
    @MainActor
    func testSpaceAdvancesAndShiftSpaceRetreatsTheBandIndex() {
        enterGlassesMode()

        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        let afterAdvance = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(
            afterAdvance.label.hasPrefix("2 / "),
            "Space should advance to band 2, got \(afterAdvance.label)"
        )

        app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: .shift)
        let afterRetreat = app.find(AID.glassesStatusLabel).assertAppears("The band status line")
        XCTAssertTrue(
            afterRetreat.label.hasPrefix("1 / "),
            "Shift-space should retreat back to band 1, got \(afterRetreat.label)"
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

    /// The bug this guards against: `advanceBand()` alone silently no-ops on
    /// the last band, so a forward tap/swipe used to just do nothing once the
    /// reader ran out of bands — the only way on by touch was the explicit
    /// "Next volume" chrome button. Windrunner Vol. 4 (`unanalysedBookID`)
    /// follows Vol. 3 in the fixture series with zero pages, so its arrival
    /// is asserted the same way `ReaderUITests` does for Mode A: the status
    /// line has nothing left to show a page count for.
    @MainActor
    func testTappingPastTheLastBandAdvancesToTheNextBook() {
        enterGlassesMode()

        // The status line only appears once a keypress/tap registers with
        // `GlassesCoordinator` (`registerKeyPress`) — unlike chrome's
        // `glassesPageLabel`, it isn't visible on entry. This first tap
        // primes it, same as every other test in this file taps/types before
        // ever reading the label.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        app.find(AID.glassesStatusLabel).assertAppears("The band status line")

        var reachedLastBand = false
        for _ in 0 ..< 50 {
            let label = app.find(AID.glassesStatusLabel).label
            let parts = label.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, parts[0] == parts[1] {
                reachedLastBand = true
                break
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        }
        XCTAssertTrue(reachedLastBand, "Should be able to reach the last band by tapping the right quarter")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        XCTAssertTrue(
            app.find(AID.glassesStatusLabel).waitForNonExistence(timeout: 3),
            "A forward tap on the last band should advance to the next book, whose fixture has zero pages"
        )
    }

    /// Auto mode's two-level state, end to end. What this pins is the bit the
    /// old single-flag design got wrong: a page turn pauses the advance but
    /// must *not* drop the reader out of the mode, because leaving the mode
    /// means the only way back is the chrome — which covers the page you were
    /// reading. The pill staying on screen through a page turn is the fix.
    @MainActor
    func testAutoModePillSurvivesAPageTurnAndPausesOnIt() {
        enterGlassesMode()

        // Chrome is visible on entry, so the toggle is reachable immediately.
        app.find(AID.glassesAutoScrollToggle).assertAppears("The auto mode toggle").tap()

        // The pill shows only once the chrome is out of the way — the centre
        // half toggles it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let pill = app.find(AID.glassesAutoScrollPill).assertAppears("The auto mode pill")
        XCTAssertTrue(pill.value is String, "The pill carries its speed as an accessibility value")

        // A forward page turn: pauses, but the pill stays put.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(
            app.find(AID.glassesAutoScrollPill).exists,
            "A page turn should pause auto mode, not leave it"
        )

        // And resuming is one tap on the pill, with no trip through the menu.
        app.find(AID.glassesAutoScrollPlayPause).assertAppears("The pill's play/pause button").tap()
        XCTAssertTrue(app.find(AID.glassesAutoScrollPill).exists, "The pill stays through a resume")

        // The speed steps clamp at the ends of the ladder rather than wrapping,
        // and the pill reports the step only as a tint — so its accessibility
        // value is the one assertable record of which step is current.
        app.find(AID.glassesSpeedIncrease).tap()
        app.find(AID.glassesSpeedIncrease).tap()
        app.find(AID.glassesSpeedIncrease).tap()
        XCTAssertEqual(
            app.find(AID.glassesAutoScrollPill).value as? String,
            "1 second per band, playing",
            "Three increases from the default should land on — and stay at — the fastest step"
        )
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
