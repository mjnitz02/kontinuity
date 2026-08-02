//
//  BrowseUITests.swift
//  KontinuityUITests
//
//  The phase-2 browse path, driven end to end against the canned library the app
//  serves itself in `UITestMode.connected`. These cover what unit tests
//  structurally can't: that the sidebar selection reaches the grid, that a
//  NavigationLink pushes the right screen, and that read state is actually drawn
//  rather than merely computed correctly.
//

import KontinuityCore
import XCTest

final class BrowseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = UITestApp.launch(.connected)
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Grid

    @MainActor
    func testSeriesGridShowsTheLibrary() {
        app.find(AID.seriesGrid).assertAppears("The series grid")

        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Air Gear's cell")
        app.find(AID.seriesCell(UITestFixture.finishedSeriesID)).assertAppears("Akira's cell")
        // Series from the second library appear under "All Series" too.
        app.find(AID.seriesCell(UITestFixture.comicsSeriesID)).assertAppears("Saga's cell")
    }

    @MainActor
    func testUnreadCountIsShownOnlyWhereThereAreUnreadBooks() {
        let inProgress = app.find(AID.seriesCell(UITestFixture.inProgressSeriesID))
            .assertAppears("Air Gear's cell")
        let finished = app.find(AID.seriesCell(UITestFixture.finishedSeriesID))
            .assertAppears("Akira's cell")

        // A cell is one combined accessibility element, so its label is what a
        // VoiceOver user hears — asserting on it checks the badge and the
        // spoken description at once.
        XCTAssertTrue(
            inProgress.label.contains("2 unread"),
            "A series with unread books should say how many. Got: \(inProgress.label)"
        )
        // The interesting half: a fully read series must not claim unread books,
        // which is what a naive `booksCount > 0` check gets wrong.
        XCTAssertFalse(
            finished.label.contains("unread"),
            "A fully read series should not mention unread books. Got: \(finished.label)"
        )
        XCTAssertTrue(
            finished.label.contains("Read"),
            "A fully read series should say so. Got: \(finished.label)"
        )
    }

    @MainActor
    func testSearchFiltersTheGrid() {
        app.find(AID.seriesCell(UITestFixture.finishedSeriesID)).assertAppears("Akira's cell")

        let field = app.searchFields.firstMatch.assertAppears("The search field")
        field.tap()
        field.typeText("Akira")

        // Search is debounced, so the assertion has to be one that waits.
        XCTAssertTrue(
            app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).waitForNonExistence(timeout: 5),
            "Searching for Akira should filter Air Gear out."
        )
        XCTAssertTrue(
            app.find(AID.seriesCell(UITestFixture.finishedSeriesID)).exists,
            "Searching for Akira should keep Akira."
        )
    }

    @MainActor
    func testEmptySearchShowsTheNoMatchesState() {
        let field = app.searchFields.firstMatch.assertAppears("The search field")
        field.tap()
        field.typeText("nothing matches this")

        app.find(AID.browseEmpty).assertAppears("The no-matches state")
    }

    // MARK: - Sidebar

    @MainActor
    func testLibraryFilterNarrowsTheGrid() {
        // Two fixture libraries, so the sidebar section is shown at all.
        let comics = app.find(AID.sidebarLibrary(UITestFixture.comicsLibraryID))
            .assertAppears("The Comics library row")
        comics.tap()

        app.find(AID.seriesCell(UITestFixture.comicsSeriesID)).assertAppears("Saga's cell")
        XCTAssertTrue(
            app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).waitForNonExistence(timeout: 5),
            "A manga series should not show under the Comics library."
        )
    }

    @MainActor
    func testKeepReadingShowsOnlyBooksInProgress() {
        app.find(AID.sidebarKeepReading).assertAppears("Keep Reading").tap()

        app.find(AID.bookRow(UITestFixture.inProgressBookID)).assertAppears("The in-progress book")
        XCTAssertFalse(
            app.find(AID.bookRow(UITestFixture.unreadBookID)).exists,
            "An unread book has no progress and does not belong on Keep Reading."
        )
        XCTAssertFalse(
            app.find(AID.bookRow(UITestFixture.readBookID)).exists,
            "A finished book does not belong on Keep Reading."
        )
    }

    @MainActor
    func testOnDeckShowsTheNextUnreadBookOfAStartedSeries() {
        app.find(AID.sidebarOnDeck).assertAppears("On Deck").tap()

        // Air Gear has a book in progress, so Komga's rule excludes it; Akira is
        // fully read so it has no next book. The shelf is legitimately empty,
        // and saying so beats an endless spinner.
        app.find(AID.browseEmpty).assertAppears("The empty On Deck state")
    }

    @MainActor
    func testSwitchingSidebarRootsClearsAPushedScreen() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Air Gear's cell").tap()
        app.find(AID.seriesDetailTitle).assertAppears("The series detail screen")

        app.find(AID.sidebarKeepReading).tap()

        XCTAssertTrue(
            app.find(AID.seriesDetailTitle).waitForNonExistence(timeout: 5),
            "Switching sidebar roots should not leave the previous root's detail screen pushed."
        )
    }

    // MARK: - Detail

    @MainActor
    func testSeriesDetailListsBooksWithTheirReadState() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Air Gear's cell").tap()

        app.find(AID.seriesDetailTitle).assertAppears("The series title")
        app.find(AID.seriesBookList).assertAppears("The book list")

        // Read state on each row, not just that the rows exist — this is the
        // part the whole app exists to get right.
        let expected = [
            UITestFixture.readBookID: "Read",
            UITestFixture.unreadBookID: "Unread",
            // The position, not merely that it's been started.
            UITestFixture.inProgressBookID: "Page 42 of 190"
        ]
        for (id, state) in expected {
            let row = app.find(AID.bookRow(id)).assertAppears("The row for \(id)")
            XCTAssertTrue(
                row.label.hasSuffix(state),
                "Expected \(id) to read as “\(state)”. Got: \(row.label)"
            )
        }
    }

    @MainActor
    func testBookDetailOpensFromASeries() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Air Gear's cell").tap()
        app.find(AID.bookRow(UITestFixture.unreadBookID)).assertAppears("The unread book row").tap()

        app.find(AID.bookDetailTitle).assertAppears("The book detail screen")
        // Reading arrives in phase 3; until then the control is present but off,
        // which is the honest state rather than a button that does nothing.
        XCTAssertFalse(app.find(AID.bookDetailRead).isEnabled)
    }

    @MainActor
    func testAnUnanalysedBookIsNotOfferedAsReadable() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Air Gear's cell").tap()
        app.find(AID.bookRow(UITestFixture.unanalysedBookID)).assertAppears("The unanalysed book row").tap()

        app.find(AID.bookDetailTitle).assertAppears("The book detail screen")
        // Komga reports pagesCount 0 until it has analysed a file. Offering that
        // as readable would open an empty reader.
        XCTAssertTrue(
            app.staticTexts["Komga hasn't analysed this book yet."].exists,
            "An unanalysed book should explain itself."
        )
    }
}
