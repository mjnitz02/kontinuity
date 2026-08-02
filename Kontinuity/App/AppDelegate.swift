//
//  AppDelegate.swift
//  Kontinuity
//
//  A pure-SwiftUI `App` has no delegate by default, but a background
//  `URLSession` transfer that finishes while the app is suspended needs one:
//  the system relaunches the app and calls this to hand over a completion
//  handler, which `DownloadCoordinator`'s session delegate must call once its
//  background session has delivered every pending event (PLAN §6).
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?

    func application(
        _: UIApplication,
        handleEventsForBackgroundURLSession _: String,
        completionHandler: @escaping () -> Void
    ) {
        Self.backgroundCompletionHandler = completionHandler
    }
}
