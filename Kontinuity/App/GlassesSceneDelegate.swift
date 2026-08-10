//
//  GlassesSceneDelegate.swift
//  Kontinuity
//
//  Mode B's external display. SwiftUI's
//  `WindowGroup` has no concept of the external-display scene role, so this
//  is a plain UIKit `UIWindowSceneDelegate`, routed here by `AppDelegate`'s
//  `application(_:configurationForConnecting:options:)` whenever a scene
//  connects with `.windowExternalDisplayNonInteractive`.
//
//  That role means exactly what it says: this window can never become key,
//  never receives touch or keyboard input. It only ever displays whatever
//  `GlassesExternalView` renders by observing `AppDelegate.glassesCoordinator`
//  — the static handoff is the only way in, since a manually-constructed
//  scene delegate has no path into `KomgaSession`'s SwiftUI environment tree.
//

import SwiftUI
import UIKit

final class GlassesSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        if let glasses = AppDelegate.glassesCoordinator {
            window.rootViewController = UIHostingController(rootView: GlassesExternalView(glasses: glasses))
            glasses.externalSceneDidConnect()
        } else {
            window.rootViewController = UIHostingController(rootView: Color.black.ignoresSafeArea())
        }
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_: UIScene) {
        window = nil
        AppDelegate.glassesCoordinator?.externalSceneDidDisconnect()
    }
}
