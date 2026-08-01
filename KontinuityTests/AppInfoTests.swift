//
//  AppInfoTests.swift
//  KontinuityTests
//
//  Phase 0: proves the app target, the KontinuityCore package and the test
//  bundle are wired together and that `make test-unit` is a real gate.
//

import Testing
@testable import KontinuityCore

@Suite("AppInfo")
struct AppInfoTests {
    @Test("user agent carries the marketing version")
    func userAgentIncludesVersion() {
        #expect(AppInfo.userAgent == "Kontinuity/\(AppInfo.marketingVersion)")
    }

    @Test("identity constants are populated")
    func identityIsNotEmpty() {
        #expect(!AppInfo.name.isEmpty)
        #expect(!AppInfo.minimumKomgaVersion.isEmpty)
    }
}
