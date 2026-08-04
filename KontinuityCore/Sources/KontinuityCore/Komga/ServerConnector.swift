//
//  ServerConnector.swift
//  KontinuityCore
//
//  The phase-1 flow, kept out of the view layer so it can be tested against a
//  stubbed transport: normalise the address, prove the server is there, obtain
//  an API key, then prove the key works.
//

import Foundation

public struct ServerConnector: Sendable {
    public enum Method: Sendable, Hashable {
        /// Bootstrap: authenticate with Basic once, mint a key, forget the password.
        case credentials(email: String, password: String)
        /// The user pasted a key made in Komga's web UI.
        case existingAPIKey(String)
    }

    public struct Connection: Sendable {
        public let address: ServerAddress
        public let user: KomgaUser
        public let apiKey: String
        /// Present only when we minted the key, so disconnect can revoke it.
        public let apiKeyID: String?
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(
        to rawAddress: String,
        using method: Method,
        deviceName: String
    ) async throws -> Connection {
        let address = try ServerAddress(normalizing: rawAddress)

        // Probe first. /actuator/health is unauthenticated, so a failure here is
        // unambiguously "wrong address / unreachable" rather than "bad password",
        // which is the distinction that makes this screen debuggable.
        let probe = KomgaClient(address: address, credential: .apiKey(""), session: session)
        try await probe.checkReachable()

        let apiKey: String
        let apiKeyID: String?

        switch method {
        case let .credentials(email, password):
            let bootstrap = KomgaClient(
                address: address,
                credential: .basic(email: email, password: password),
                session: session
            )
            let minted = try await mintKey(using: bootstrap, deviceName: deviceName)
            apiKey = minted.key
            apiKeyID = minted.id

        case let .existingAPIKey(key):
            apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKeyID = nil
        }

        // Verify the key independently of how we got it — a pasted key may be
        // revoked or malformed, and a minted one proves the round trip works.
        let client = KomgaClient(address: address, credential: .apiKey(apiKey), session: session)
        let user = try await client.currentUser()

        return Connection(address: address, user: user, apiKey: apiKey, apiKeyID: apiKeyID)
    }

    /// Komga requires the key comment to be unique per user and answers a repeat
    /// with 400, which would otherwise strand anyone reconnecting the same iPad.
    /// Retry once with a dated label rather than making the user invent a name.
    private func mintKey(using client: KomgaClient, deviceName: String) async throws -> KomgaAPIKey {
        let label = "\(AppInfo.name) — \(deviceName)"
        do {
            return try await client.createAPIKey(comment: label)
        } catch let error as KomgaError {
            guard case .badRequest = error else { throw error }
            let stamp = Self.labelDateFormatter.string(from: .now)
            return try await client.createAPIKey(comment: "\(label) (\(stamp))")
        }
    }

    private nonisolated(unsafe) static let labelDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
