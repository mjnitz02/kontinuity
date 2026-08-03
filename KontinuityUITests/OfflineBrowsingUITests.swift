//
//  OfflineBrowsingUITests.swift
//  KontinuityUITests
//
//  PLAN §11: All Series and a series' own book list degrade to a
//  locally-derived view instead of an error when the server can't be reached,
//  filtered to what's actually downloaded — driven end to end against
//  `UITestMode.offline`/`.offlineWithDownloads`, which make `StubKomgaService`
//  fail every request the same way a dropped connection would. Keep Reading and
//  On Deck both stay hard failures, deliberately — both are server-computed
//  over the whole library, not something a handful of downloaded books can
//  reconstruct.
//

import KontinuityCore
import XCTest

final class OfflineBrowsingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Nothing downloaded

    @MainActor
    func testZeroDownloadsShowsThePlainOfflineState() {
        app = UITestApp.launch(.offline)

        app.find(AID.browseError).assertAppears("The plain unreachable state — nothing downloaded to fall back to")
        XCTAssertFalse(
            app.find(AID.offlineBanner).exists,
            "There's nothing to show, so there's nothing to caveat with a banner."
        )
    }

    @MainActor
    func testOnDeckIsAHardFailureEvenWithNothingDownloaded() {
        app = UITestApp.launch(.offline)

        app.find(AID.sidebarOnDeck).assertAppears("On Deck").tap()

        app.find(AID.browseError).assertAppears("On Deck's error state")
        app.staticTexts["On Deck needs a connection to your server"].assertAppears("The offline-specific copy")
    }

    @MainActor
    func testKeepReadingIsAHardFailureEvenWithNothingDownloaded() {
        app = UITestApp.launch(.offline)

        app.find(AID.sidebarKeepReading).assertAppears("Keep Reading").tap()

        app.find(AID.browseError).assertAppears("Keep Reading's error state")
        app.staticTexts["Keep Reading needs a connection to your server"].assertAppears("The offline-specific copy")
    }

    // MARK: - Some downloaded

    @MainActor
    func testAllSeriesShowsOnlyTheDownloadedSeries() {
        app = UITestApp.launch(.offlineWithDownloads)

        app.find(AID.offlineBanner).assertAppears("The offline banner")
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID))
            .assertAppears("Windrunner — it has downloaded books")

        XCTAssertFalse(
            app.find(AID.seriesCell(UITestFixture.finishedSeriesID)).exists,
            "Neon Requiem has nothing downloaded, so it shouldn't appear offline."
        )
        XCTAssertFalse(
            app.find(AID.seriesCell(UITestFixture.comicsSeriesID)).exists,
            "Halcyon Drift has nothing downloaded, so it shouldn't appear offline."
        )
    }

    @MainActor
    func testSearchAndSortControlsAreHiddenOffline() {
        app = UITestApp.launch(.offlineWithDownloads)

        app.find(AID.offlineBanner).assertAppears("The offline banner")
        XCTAssertFalse(app.buttons["Filter"].exists, "Server-side read-status filtering is meaningless offline.")
        XCTAssertFalse(app.buttons["Sort"].exists, "Server-side sorting is meaningless offline.")
    }

    @MainActor
    func testSeriesDetailShowsOnlyDownloadedBooks() {
        app = UITestApp.launch(.offlineWithDownloads)

        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Windrunner's cell").tap()

        app.find(AID.bookRow(UITestFixture.readBookID)).assertAppears("Vol. 1 — downloaded")
        app.find(AID.bookRow(UITestFixture.inProgressBookID)).assertAppears("Vol. 2 — downloaded")
        XCTAssertFalse(
            app.find(AID.bookRow(UITestFixture.unreadBookID)).exists,
            "Vol. 3 was never downloaded, so it shouldn't appear in the offline book list."
        )
        app.staticTexts["2 downloaded"].assertAppears("The offline header's downloaded count")
    }

    @MainActor
    func testKeepReadingStaysAHardFailureEvenWithDownloads() {
        app = UITestApp.launch(.offlineWithDownloads)

        app.find(AID.sidebarKeepReading).assertAppears("Keep Reading").tap()

        // Keep Reading is computed over the whole library's read state
        // server-side (PLAN §11) — having a couple of books downloaded
        // doesn't change that.
        app.find(AID.browseError).assertAppears("Keep Reading's error state")
        app.staticTexts["Keep Reading needs a connection to your server"].assertAppears("The offline-specific copy")
    }

    @MainActor
    func testOnDeckStaysAHardFailureEvenWithDownloads() {
        app = UITestApp.launch(.offlineWithDownloads)

        app.find(AID.sidebarOnDeck).assertAppears("On Deck").tap()

        // On Deck is computed over the whole library server-side (PLAN §11) —
        // having a couple of books downloaded doesn't change that.
        app.find(AID.browseError).assertAppears("On Deck's error state")
        app.staticTexts["On Deck needs a connection to your server"].assertAppears("The offline-specific copy")
    }
}
