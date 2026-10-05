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

    /// Polls `identifier`'s label until `predicate` accepts it, and returns
    /// the last label actually seen so a failure can say what was there.
    ///
    /// Required for anything that hides itself on a timer. The glasses status
    /// line is on screen for two seconds after an input
    /// (`GlassesCoordinator.registerKeyPress`), and asserting it exists and
    /// *then* reading `.label` spends that budget on two separate round-trips
    /// into the app — on a loaded CI runner the line had already gone by the
    /// second one, which surfaces as a missing-snapshot failure rather than as
    /// a timeout. One atomic resolve-and-read per poll removes that race.
    @discardableResult
    func waitForLabel(
        _ identifier: String,
        timeout: TimeInterval = 10,
        where predicate: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen: String?
        repeat {
            if let label = find(identifier).labelIfPresent {
                lastSeen = label
                if predicate(label) {
                    return label
                }
            }
            usleep(100_000)
        } while Date() < deadline
        return lastSeen
    }
}

extension XCUIElement {
    /// `label`, or `nil` when the query matches nothing right now.
    ///
    /// Reading `.label` directly fails the whole test when the element no
    /// longer resolves ("Failed to get matching snapshot"). `snapshot()`
    /// throws instead, which is what makes it safe to look at an element the
    /// app is allowed to take away again.
    var labelIfPresent: String? {
        try? snapshot().label
    }

    /// `waitForExistence` with a message, because a bare `false` in a UI test
    /// failure tells you nothing about which element went missing.
    ///
    /// The default ceiling is generous because it only costs time on the
    /// failure path: `waitForExistence` polls and returns the instant the
    /// element shows up, so a passing test is no slower for it. A tighter 10s
    /// bound was enough locally but marginal on CI, where the same suite has
    /// run in 320s and in 559s — the first wait after a cold launch was the
    /// one that lost that race.
    @discardableResult
    func assertAppears(_ label: String, timeout: TimeInterval = 30) -> XCUIElement {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(label) never appeared.")
        return self
    }
}
