//
//  ServerConnectorTests.swift
//  KontinuityTests
//
//  The phase-1 flow end to end, over a stubbed transport.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("ServerConnector")
struct ServerConnectorTests {
    private static let health = Stub.json(#"{"status":"UP"}"#)
    private static let userJSON = KomgaClientTests.userJSON

    private static func keyJSON(id: String = "k1", key: String = "minted-key") -> Stub {
        .json("""
        { "id": "\(id)", "userId": "u1", "key": "\(key)", "comment": "Kontinuity — iPad",
          "createdDate": "2026-08-02T10:15:30Z", "lastModifiedDate": "2026-08-02T10:15:30Z" }
        """)
    }

    private func connect(
        _ stubs: [Stub],
        to address: String = "nas.local:25600",
        using method: ServerConnector.Method
    ) async throws -> (ServerConnector.Connection, StubTransport) {
        let transport = StubTransport(stubs)
        let connection = try await ServerConnector(session: transport.session).connect(
            to: address,
            using: method,
            deviceName: "iPad"
        )
        return (connection, transport)
    }

    @Test("bootstraps a key from credentials, then verifies it")
    func bootstrapFromCredentials() async throws {
        let (connection, transport) = try await connect(
            [Self.health, Self.keyJSON(), .json(Self.userJSON)],
            using: .credentials(email: "matt@example.com", password: "hunter2")
        )

        #expect(connection.apiKey == "minted-key")
        #expect(connection.apiKeyID == "k1")
        #expect(connection.user.email == "matt@example.com")
        #expect(connection.address.baseURL.absoluteString == "http://nas.local:25600")

        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].path == "/actuator/health")
        #expect(requests[1].path == "/api/v2/users/me/api-keys")
        // The final verification must use the minted key, not the password.
        #expect(requests[2].header("X-API-Key") == "minted-key")
        #expect(requests[2].header("Authorization") == nil)
    }

    @Test("a pasted key skips minting and carries no key id")
    func pastedKey() async throws {
        let (connection, transport) = try await connect(
            [Self.health, .json(Self.userJSON)],
            using: .existingAPIKey("  pasted-key  ")
        )

        #expect(connection.apiKey == "pasted-key")
        // Nil means "we didn't create it", so disconnect won't revoke a key the
        // user may be using elsewhere.
        #expect(connection.apiKeyID == nil)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].header("X-API-Key") == "pasted-key")
    }

    @Test("retries key creation with a dated label when the name is taken")
    func retriesOnDuplicateName() async throws {
        let (connection, transport) = try await connect(
            [
                Self.health,
                .json(#"{"message":"name already exists"}"#, status: 400),
                Self.keyJSON(id: "k2", key: "second-key"),
                .json(Self.userJSON)
            ],
            using: .credentials(email: "matt@example.com", password: "hunter2")
        )

        #expect(connection.apiKey == "second-key")
        #expect(transport.requests.count == 4)

        let comment = try #require(transport.requests[2].jsonBody)["comment"]
        #expect(comment?.hasPrefix("Kontinuity — iPad (") == true)
    }

    @Test("an unreachable server fails before any credential is sent")
    func unreachableServerFailsEarly() async throws {
        let transport = StubTransport([.failure(.cannotConnectToHost)])
        let connector = ServerConnector(session: transport.session)

        await #expect(throws: KomgaError.self) {
            try await connector.connect(
                to: "nas.local:25600",
                using: .credentials(email: "matt@example.com", password: "hunter2"),
                deviceName: "iPad"
            )
        }
        // Only the health probe went out — the password never left the device.
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].path == "/actuator/health")
    }

    @Test("bad credentials surface as unauthorized")
    func badCredentials() async throws {
        let transport = StubTransport([Self.health, .status(401)])
        let connector = ServerConnector(session: transport.session)

        await #expect(throws: KomgaError.unauthorized) {
            try await connector.connect(
                to: "nas.local:25600",
                using: .credentials(email: "matt@example.com", password: "wrong"),
                deviceName: "iPad"
            )
        }
    }

    @Test("a revoked pasted key surfaces as unauthorized")
    func revokedPastedKey() async throws {
        let transport = StubTransport([Self.health, .status(401)])
        let connector = ServerConnector(session: transport.session)

        await #expect(throws: KomgaError.unauthorized) {
            try await connector.connect(
                to: "nas.local:25600",
                using: .existingAPIKey("revoked"),
                deviceName: "iPad"
            )
        }
    }

    @Test("an invalid address fails without touching the network")
    func invalidAddress() async throws {
        let transport = StubTransport([])
        let connector = ServerConnector(session: transport.session)

        await #expect(throws: KomgaError.self) {
            try await connector.connect(to: "", using: .existingAPIKey("k"), deviceName: "iPad")
        }
        #expect(transport.requests.isEmpty)
    }
}
