//
//  LaunchUITests.swift
//  KontinuityUITests
//
//  The cheapest useful UI test: the app launches in both states and lands on the
//  right screen. Catches the class of failure — a SwiftData migration, a missing
//  Info.plist key, a fatalError in `init` — that unit tests structurally cannot.
//

import KontinuityCore
import XCTest

final class LaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesToConnectScreenWithNoServer() {
        let app = UITestApp.launch(.fresh)

        app.navigationBars["Connect to Komga"].assertAppears("The connect screen")
        app.find(AID.connectSubmit).assertAppears("The Connect button")

        attachScreenshot(of: app, named: "Connect")
    }

    @MainActor
    func testLaunchesToBrowseWhenAServerIsSaved() {
        let app = UITestApp.launch(.connected)

        app.find(AID.sidebarKeepReading).assertAppears("The sidebar's Keep Reading row")

        attachScreenshot(of: app, named: "Browse")
    }

    /// Screenshots are kept so a CI failure can be looked at instead of guessed at.
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
