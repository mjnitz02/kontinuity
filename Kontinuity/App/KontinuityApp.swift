//
//  KontinuityApp.swift
//  Kontinuity
//

import KontinuityCore
import SwiftData
import SwiftUI

@main
struct KontinuityApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Server.self)
        } catch {
            // Nothing sensible to fall back to: without a store the app can't
            // remember a server, and silently running in-memory would look like
            // data loss on every launch.
            fatalError("Could not open the Kontinuity data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
