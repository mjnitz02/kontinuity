//
//  AppDelegate.swift
//  Kontinuity
//
//  A pure-SwiftUI `App` has no delegate by default, but two things need one:
//
//  - A background `URLSession` transfer that finishes while the app is
//    suspended: the system relaunches the app and calls this to hand over a
//    completion handler, which `DownloadCoordinator`'s session delegate must
//    call once its background session has delivered every pending event
//    (PLAN §6).
//  - Mode B's external display scene (PLAN phase 6, READER-DESIGN §3):
//    `application(_:configurationForConnecting:options:)` is how UIKit asks
//    which `UISceneConfiguration`/delegate class to use for a connecting
//    scene, and a manually-built `GlassesSceneDelegate` has no path into
//    SwiftUI's environment tree — `glassesCoordinator` is the static handoff
//    it reads from, the same shape `backgroundCompletionHandler` already
//    uses for the download session.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?
    static var glassesCoordinator: GlassesCoordinator?

    func application(
        _: UIApplication,
        handleEventsForBackgroundURLSession _: String,
        completionHandler: @escaping () -> Void
    ) {
        Self.backgroundCompletionHandler = completionHandler
    }

    /// The default (interactive) role passes the incoming session's own
    /// configuration through unmodified, so SwiftUI's own `WindowGroup`
    /// handling for the main scene is untouched — this delegate only takes
    /// over the external-display role, which SwiftUI has no concept of.
    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        guard connectingSceneSession.role == .windowExternalDisplayNonInteractive else {
            return UISceneConfiguration(
                name: connectingSceneSession.configuration.name,
                sessionRole: connectingSceneSession.role
            )
        }
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = GlassesSceneDelegate.self
        return configuration
    }
}
