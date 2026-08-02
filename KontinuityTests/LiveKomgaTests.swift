//
//  LiveKomgaTests.swift
//  KontinuityTests
//
//  Opt-in tests against a real Komga instance (see `make komga-up`). They skip
//  themselves unless the environment is configured, so `make test-unit` — the CI
//  gate — stays hermetic and Docker-free. Run them with `make test-integration`.
//
//  These exist because stubs can only assert what we already believe about the
//  wire format. Hand-written JSON in the stubbed suite is a restatement of our
//  assumptions; these tests decode what Komga actually sends.
//

import Foundation
import Testing
@testable import KontinuityCore

/// Injected by `make test-integration` through `TEST_RUNNER_*` build settings,
/// which Xcode strips the prefix from before handing to the test process.
enum LiveKomga {
    static var url: String? {
        value("KOMGA_URL")
    }

    static var apiKey: String? {
        value("KOMGA_API_KEY")
    }

    static var email: String? {
        value("KOMGA_EMAIL")
    }

    static var password: String? {
        value("KOMGA_PASSWORD")
    }

    static var isConfigured: Bool {
        url != nil && apiKey != nil
    }

    static var canBootstrap: Bool {
        isConfigured && email != nil && password != nil
    }

    static func address() throws -> ServerAddress {
        try ServerAddress(normalizing: url ?? "")
    }

    private static func value(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return raw
    }
}

@Suite("Live Komga", .enabled(if: LiveKomga.isConfigured))
struct LiveKomgaTests {
    private func client(_ credential: KomgaCredential) throws -> KomgaClient {
        try KomgaClient(address: LiveKomga.address(), credential: credential)
    }

    @Test("reaches the unauthenticated health endpoint")
    func health() async throws {
        // Also proves Info.plist's NSAllowsLocalNetworking is doing its job:
        // without it, plain HTTP to localhost would be blocked by ATS.
        try await client(.apiKey("")).checkReachable()
    }

    @Test("decodes the real current-user payload")
    func currentUser() async throws {
        let key = try #require(LiveKomga.apiKey)
        let user = try await client(.apiKey(key)).currentUser()

        #expect(!user.id.isEmpty)
        if let email = LiveKomga.email {
            #expect(user.email == email)
        }
        // Roles the reader and downloader depend on. Komga's real payload also
        // carries KOBO_SYNC / KOREADER_SYNC, which must not trip up decoding.
        #expect(user.canStreamPages)
    }

    @Test("rejects a bogus API key")
    func bogusKey() async throws {
        await #expect(throws: KomgaError.unauthorized) {
            try await client(.apiKey("definitely-not-a-real-key")).currentUser()
        }
    }

    @Test("bootstraps and revokes a real API key", .enabled(if: LiveKomga.canBootstrap))
    func bootstrapRoundTrip() async throws {
        let email = try #require(LiveKomga.email)
        let password = try #require(LiveKomga.password)
        // Unique per run so a leaked key from an interrupted run can't collide.
        let deviceName = "IntegrationTest-\(UUID().uuidString.prefix(8))"

        let connection = try await ServerConnector().connect(
            to: #require(LiveKomga.url),
            using: .credentials(email: email, password: password),
            deviceName: deviceName
        )

        #expect(!connection.apiKey.isEmpty)
        #expect(connection.user.email == email)

        let keyID = try #require(connection.apiKeyID, "we minted it, so the id must come back")

        // Clean up before asserting anything else, so a later failure can't
        // leave a key behind on the server.
        try await client(.apiKey(connection.apiKey)).deleteAPIKey(id: keyID)

        // The minted key worked for the verification call inside connect(), and
        // is now revoked.
        await #expect(throws: KomgaError.unauthorized) {
            try await client(.apiKey(connection.apiKey)).currentUser()
        }
    }

    @Test(
        "decodes Komga's nanosecond timestamps as the right instant",
        .enabled(if: LiveKomga.canBootstrap)
    )
    func decodesRealTimestamps() async throws {
        let email = try #require(LiveKomga.email)
        let password = try #require(LiveKomga.password)
        let bootstrap = try client(.basic(email: email, password: password))

        let before = Date()
        let key = try await bootstrap.createAPIKey(comment: "Kontinuity date probe \(UUID().uuidString.prefix(8))")
        let after = Date()
        try await client(.apiKey(key.key)).deleteAPIKey(id: key.id)

        // Komga sends nine fractional digits (2026-08-02T10:42:11.858195884Z).
        // Foundation handles that today; this pins it against a future Komga
        // changing format, which would otherwise surface as a decoding failure
        // deep inside a sync flush rather than here.
        #expect(key.createdDate >= before.addingTimeInterval(-120))
        #expect(key.createdDate <= after.addingTimeInterval(120))
    }
}
