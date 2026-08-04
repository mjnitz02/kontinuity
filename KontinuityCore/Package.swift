// swift-tools-version: 6.0
import PackageDescription

/// KontinuityCore holds everything that doesn't need UIKit/SwiftUI: the Komga
/// client, the persistence models, the sync engine, and the page-layout math.
/// Keeping it a separate package means the hard parts stay unit-testable without
/// booting a simulator or talking to a live server.
let package = Package(
    name: "KontinuityCore",
    platforms: [.iOS("26.0")],
    products: [
        // Static. This makes the ObjC runtime log "class ... is implemented in
        // both" during `make test-unit`, because the library lands in the app
        // binary *and* in the xctest bundle injected into it. Harmless here —
        // no model object crosses that boundary — and the alternative is worse:
        // `type: .dynamic` makes the app link @rpath/KontinuityCore.framework
        // without Xcode embedding it in the .app, so `make deploy` / `make ipa`
        // produce a build that dyld kills on launch. Verified, not assumed.
        .library(name: "KontinuityCore", targets: ["KontinuityCore"])
    ],
    targets: [
        .target(
            name: "KontinuityCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
