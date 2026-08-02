//
//  KomgaClientTests.swift
//  KontinuityTests
//
//  Status-code semantics and auth headers, pinned against a stubbed transport.
//  The 204 and 409 cases matter well beyond phase 1 — the sync engine is built
//  on top of exactly this behaviour (.claude/KOMGA-API.md §4).
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("KomgaClient")
struct KomgaClientTests {
    static let userJSON = """
    { "id": "u1", "email": "matt@example.com",
      "roles": ["USER", "FILE_DOWNLOAD", "PAGE_STREAMING"],
      "sharedAllLibraries": true, "sharedLibrariesIds": [],
      "labelsAllow": [], "labelsExclude": [] }
    """

    private func makeClient(
        _ stubs: [Stub],
        credential: KomgaCredential = .apiKey("secret-key")
    ) throws -> (KomgaClient, StubTransport) {
        let transport = StubTransport(stubs)
        let client = try KomgaClient(
            address: ServerAddress(normalizing: "http://nas.local:25600"),
            credential: credential,
            session: transport.session
        )
        return (client, transport)
    }

    @Test("sends the API key as X-API-Key and decodes the user")
    func currentUserSendsAPIKey() async throws {
        let (client, transport) = try makeClient([.json(Self.userJSON)])
        let user = try await client.currentUser()

        #expect(user.email == "matt@example.com")
        #expect(user.canDownloadFiles)
        #expect(user.canStreamPages)
        #expect(!user.isAdmin)

        let request = try #require(transport.requests.first)
        #expect(request.header("X-API-Key") == "secret-key")
        #expect(request.header("Authorization") == nil)
        #expect(request.path == "/api/v2/users/me")
    }

    @Test("sends Basic auth when bootstrapping with credentials")
    func basicAuthHeader() async throws {
        let (client, transport) = try makeClient(
            [.json(Self.userJSON)],
            credential: .basic(email: "matt@example.com", password: "hunter2")
        )
        _ = try await client.currentUser()

        let request = try #require(transport.requests.first)
        let expected = Data("matt@example.com:hunter2".utf8).base64EncodedString()
        #expect(request.header("Authorization") == "Basic \(expected)")
        #expect(request.header("X-API-Key") == nil)
    }

    @Test("creates an API key against the v2 users path")
    func createAPIKeyUsesV2Path() async throws {
        let json = """
        { "id": "k1", "userId": "u1", "key": "abc123", "comment": "Kontinuity — iPad",
          "createdDate": "2026-08-02T10:15:30Z", "lastModifiedDate": "2026-08-02T10:15:30Z" }
        """
        let (client, transport) = try makeClient([.json(json)])
        let key = try await client.createAPIKey(comment: "Kontinuity — iPad")

        #expect(key.key == "abc123")
        #expect(key.id == "k1")

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        // Komga 1.25 mounts UserController at api/v2 — the only controller that
        // isn't v1. Getting this wrong yields a silent 404 on the connect screen.
        #expect(request.path == "/api/v2/users/me/api-keys")
    }

    @Test("probes health unauthenticated")
    func healthProbeSendsNoCredential() async throws {
        let (client, transport) = try makeClient([.json(#"{"status":"UP"}"#)])
        try await client.checkReachable()

        let request = try #require(transport.requests.first)
        #expect(request.path == "/actuator/health")
        #expect(request.header("X-API-Key") == nil)
    }

    @Test("maps status codes to typed errors", arguments: [
        (400, KomgaError.badRequest(message: nil)),
        (401, KomgaError.unauthorized),
        (403, KomgaError.forbidden),
        (404, KomgaError.notFound),
        (409, KomgaError.conflict)
    ])
    func mapsStatusCodes(status: Int, expected: KomgaError) async throws {
        let (client, _) = try makeClient([.status(status)])
        await #expect(throws: expected) { try await client.currentUser() }
    }

    @Test("surfaces Komga's error message on 400")
    func extractsErrorMessage() async throws {
        let (client, _) = try makeClient([.json(#"{"message":"API key name already exists"}"#, status: 400)])
        await #expect(throws: KomgaError.badRequest(message: "API key name already exists")) {
            try await client.createAPIKey(comment: "dupe")
        }
    }

    @Test("treats 204 as an absent body rather than an error")
    func noContentIsNotAnError() async throws {
        let (client, transport) = try makeClient([.status(204)])
        // deleteAPIKey returns Void; a 204 must complete normally.
        try await client.deleteAPIKey(id: "k1")
        #expect(transport.requests.first?.method == "DELETE")
        #expect(transport.requests.first?.path == "/api/v2/users/me/api-keys/k1")
    }

    @Test("classifies connection failures as offline")
    func offlineClassification() async throws {
        let (client, _) = try makeClient([.failure(.notConnectedToInternet)])
        do {
            _ = try await client.currentUser()
            Issue.record("expected a transport error")
        } catch let error as KomgaError {
            #expect(error.isOffline)
        }
    }

    @Test("a 500 keeps the status code for diagnosis")
    func unexpectedStatus() async throws {
        let (client, _) = try makeClient([.status(500, body: "upstream boom")])
        await #expect(throws: KomgaError.unexpectedStatus(code: 500, body: "upstream boom")) {
            try await client.currentUser()
        }
    }
}

@Suite("Komga date parsing")
struct KomgaDateTests {
    @Test("parses the formats Komga emits", arguments: [
        "2026-08-02T10:15:30Z",
        "2026-08-02T10:15:30.123Z",
        "2026-08-02T10:15:30+02:00",
        "2026-08-02T10:15:30.123456+02:00",
        "2026-08-02T10:15:30",
        "2026-08-02T10:15:30.123456789"
    ])
    func parsesKnownFormats(raw: String) {
        #expect(KomgaDate.parse(raw) != nil, "failed to parse \(raw)")
    }

    @Test("round-trips a date through the progression format")
    func roundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let parsed = try #require(KomgaDate.parse(KomgaDate.format(now)))
        #expect(abs(parsed.timeIntervalSince(now)) < 0.01)
    }

    @Test("rejects nonsense")
    func rejectsGarbage() {
        #expect(KomgaDate.parse("not a date") == nil)
    }
}
