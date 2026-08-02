//
//  DownloadsUITests.swift
//  KontinuityUITests
//
//  The phase-5 download path, end to end against the stub: "Download unread"
//  actually drives `CBZArchive`/`LocalBookStore` on a real ZIP the stub
//  builds from its fixture pages (StubKomgaService.zipFixture), not a faked
//  shortcut — so this is proving the real decompress-and-verify pipeline
//  runs, not just that a button click flips a label.
//

import KontinuityCore
import XCTest

final class DownloadsUITests: XCTestCase {
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

    @MainActor
    func testDownloadUnreadDownloadsAReadableBookAndItOpensOffline() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Windrunner's cell").tap()
        app.find(AID.seriesDownloadUnread).assertAppears("The Download unread button").tap()

        let unreadRow = app.find(AID.bookRow(UITestFixture.unreadBookID)).assertAppears("The unread book row")
        XCTAssertTrue(
            waitForLabel(unreadRow, toContain: "Downloaded", timeout: 20),
            "The unread, readable book should finish downloading. Got: \(unreadRow.label)"
        )
        // The unanalysed book has no pages to download and must be skipped
        // rather than stuck retrying forever.
        let unanalysedRow = app.find(AID.bookRow(UITestFixture.unanalysedBookID))
        XCTAssertFalse(unanalysedRow.label.contains("Downloaded"))

        unreadRow.tap()
        app.find(AID.bookDetailDownload).assertAppears("The per-book download control, now offering removal")
        app.find(AID.bookDetailRead).assertAppears("The Read button").tap()

        let pageLabel = app.find(AID.readerPageLabel).assertAppears("The reader's page indicator")
        XCTAssertEqual(pageLabel.label, "1 / 6", "A downloaded book should still open and read normally.")
    }

    @MainActor
    func testDownloadedBookAppearsUnderTheDownloadedSidebarRoot() {
        app.find(AID.seriesCell(UITestFixture.inProgressSeriesID)).assertAppears("Windrunner's cell").tap()
        app.find(AID.seriesDownloadUnread).assertAppears("The Download unread button").tap()

        let unreadRow = app.find(AID.bookRow(UITestFixture.unreadBookID)).assertAppears("The unread book row")
        XCTAssertTrue(waitForLabel(unreadRow, toContain: "Downloaded", timeout: 20))

        app.find(AID.sidebarDownloaded).assertAppears("The Downloaded sidebar row").tap()

        app.find(AID.downloadsList).assertAppears("The downloads list")
        app.find(AID.downloadRow(UITestFixture.unreadBookID)).assertAppears("The downloaded book's row here too")
    }

    /// A row's identifier stays put while only its label text changes as the
    /// download progresses, so waiting for existence isn't enough here.
    private func waitForLabel(_ element: XCUIElement, toContain substring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(substring) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
