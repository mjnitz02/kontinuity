//
//  UITestApp.swift
//  KontinuityUITests
//
//  Every UI test launches the app in a deterministic mode rather than against
//  whatever server and Keychain state the simulator happens to hold. The app
//  reads `UITestMode` out of `UserDefaults` — arguments of the form `-key value`
//  land in the volatile domain automatically — and swaps in an in-memory store
//  plus a canned `KomgaServing`. See Kontinuity/Shared/UITestSupport.swift.
//

import KontinuityCore
import XCTest

enum UITestApp {
    /// Launches and waits for the app to actually be running, so a failing
    /// assertion points at the UI rather than at a race with launch.
    static func launch(_ mode: UITestMode) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(UITestMode.defaultsKey)", mode.rawValue]
        app.launch()
        XCTAssertEqual(app.state, .runningForeground, "The app did not reach the foreground.")
        return app
    }
}

extension XCUIApplication {
    /// Looks up an element by identifier without asserting its type.
    ///
    /// SwiftUI decides for itself whether a given view surfaces as a button, a
    /// cell, or an "other" element, and that mapping shifts between OS releases
    /// and between a sidebar and a grid. Matching on identifier alone keeps the
    /// tests describing *what* they're driving instead of how SwiftUI happened
    /// to render it this year.
    func find(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

extension XCUIElement {
    /// `waitForExistence` with a message, because a bare `false` in a UI test
    /// failure tells you nothing about which element went missing.
    @discardableResult
    func assertAppears(_ label: String, timeout: TimeInterval = 10) -> XCUIElement {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(label) never appeared.")
        return self
    }
}
