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
        .library(name: "KontinuityCore", targets: ["KontinuityCore"])
    ],
    targets: [
        .target(
            name: "KontinuityCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
