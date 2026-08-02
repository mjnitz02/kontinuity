//
//  KomgaClient.swift
//  KontinuityCore
//
//  The live `KomgaServing`. Everything network-shaped that later phases need —
//  status-code semantics, 204-as-nil, Komga's date formats — is established
//  here once so the sync and download engines inherit it.
//

import Foundation

public struct KomgaClient: KomgaServing {
    public let address: ServerAddress
    private let credential: KomgaCredential
    private let session: URLSession

    public init(address: ServerAddress, credential: KomgaCredential, session: URLSession = .shared) {
        self.address = address
        self.credential = credential
        self.session = session
    }

    /// A client pointed at the same server with different credentials — used to
    /// swap the bootstrap Basic credential for the minted API key.
    public func authenticated(with credential: KomgaCredential) -> KomgaClient {
        KomgaClient(address: address, credential: credential, session: session)
    }

    // MARK: - KomgaServing

    public func checkReachable() async throws {
        // Deliberately unauthenticated: a 401 here would still prove we reached
        // something, but /actuator/health is permitAll so a healthy Komga answers
        // 200 regardless of credentials.
        var request = URLRequest(url: address.url(path: "/actuator/health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        _ = try await send(request, authenticated: false)
    }

    public func currentUser() async throws -> KomgaUser {
        try await get("/api/v2/users/me")
    }

    public func createAPIKey(comment: String) async throws -> KomgaAPIKey {
        let body = try JSONEncoder().encode(KomgaAPIKeyRequest(comment: comment))
        var request = makeRequest(path: "/api/v2/users/me/api-keys", method: "POST")
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let data = try await send(request) else {
            throw KomgaError.decoding(description: "Komga returned no body when creating an API key.")
        }
        return try decode(KomgaAPIKey.self, from: data)
    }

    public func deleteAPIKey(id: String) async throws {
        let request = makeRequest(path: "/api/v2/users/me/api-keys/\(id)", method: "DELETE")
        _ = try await send(request)
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: address.url(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let data = try await send(makeRequest(path: path, method: "GET")) else {
            throw KomgaError.decoding(description: "Expected a response body from \(path).")
        }
        return try decode(T.self, from: data)
    }

    /// Performs the request and maps the status code.
    ///
    /// Returns `nil` for 204 — Komga uses "No Content" to mean *never opened* on
    /// the progression endpoint, which is a value, not an error (KOMGA-API §4).
    /// Establishing that here keeps phase 4 from having to special-case it.
    @discardableResult
    private func send(_ request: URLRequest, authenticated: Bool = true) async throws -> Data? {
        var request = request
        if authenticated, let header = credential.header {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KomgaError.from(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KomgaError.decoding(description: "Response was not HTTP.")
        }
        return try Self.body(forStatus: http.statusCode, data: data)
    }

    /// Status-code semantics, split out from `send` so the transport and the
    /// protocol mapping stay separately readable.
    private static func body(forStatus status: Int, data: Data) throws -> Data? {
        switch status {
        case 204:
            return nil
        case 200 ... 299:
            return data.isEmpty ? nil : data
        case 400:
            throw KomgaError.badRequest(message: errorMessage(from: data))
        case 401:
            throw KomgaError.unauthorized
        case 403:
            throw KomgaError.forbidden
        case 404:
            throw KomgaError.notFound
        case 409:
            throw KomgaError.conflict
        default:
            throw KomgaError.unexpectedStatus(code: status, body: errorMessage(from: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw KomgaError.from(error)
        }
    }

    /// Komga's error responses are Spring's `{ "message": ..., "error": ... }`
    /// shape, but a reverse proxy in front can return anything — fall back to the
    /// raw body so the user sees something actionable either way.
    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error"] {
                if let value = object[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        guard let raw = String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return nil
        }
        return String(raw.prefix(200))
    }

    // MARK: - Decoding

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = KomgaDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognised date format: \(raw)"
                )
            }
            return date
        }
        return decoder
    }()
}

/// Komga serialises `ZonedDateTime` with an offset and `LocalDateTime` without
/// one, and both appear across the API surface, so parsing tries each in turn.
/// The formatters are shared: Foundation's date formatters are documented as
/// thread-safe for parsing once configured.
enum KomgaDate {
    private nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `LocalDateTime` — no offset. Komga's `toUTCZoned()` shows these are UTC.
    private nonisolated(unsafe) static let offsetless: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = withFractionalSeconds.date(from: raw) {
            return date
        }
        if let date = internetDateTime.date(from: raw) {
            return date
        }
        // Strip fractional seconds an offsetless value may still carry.
        if let dot = raw.firstIndex(of: "."), let date = offsetless.date(from: String(raw[raw.startIndex ..< dot])) {
            return date
        }
        return offsetless.date(from: raw)
    }

    /// Formats for a progression PUT body, which Komga parses as `OffsetDateTime`.
    static func format(_ date: Date) -> String {
        withFractionalSeconds.string(from: date)
    }
}
