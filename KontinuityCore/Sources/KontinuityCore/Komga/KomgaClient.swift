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

    // MARK: - KomgaServing: browse

    public func libraries() async throws -> [KomgaLibrary] {
        try await get("/api/v1/libraries")
    }

    public func series(matching query: SeriesQuery) async throws -> KomgaPage<KomgaSeries> {
        var items = [
            URLQueryItem(name: "page", value: String(query.page)),
            URLQueryItem(name: "size", value: String(query.size))
        ]
        if let libraryID = query.libraryID {
            items.append(URLQueryItem(name: "library_id", value: libraryID))
        }
        if let oneshot = query.oneshot {
            items.append(URLQueryItem(name: "oneshot", value: String(oneshot)))
        }
        items += query.readStatus.map { URLQueryItem(name: "read_status", value: $0.rawValue) }
        let search = query.searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if search.isEmpty {
            items.append(URLQueryItem(name: "sort", value: query.sort.rawValue))
        } else {
            // Deliberately no `sort`: Komga falls back to relevance ordering
            // when a search term is present and an explicit sort would override
            // it, burying the best match somewhere down the alphabet.
            items.append(URLQueryItem(name: "search", value: search))
        }
        return try await get("/api/v1/series", query: items)
    }

    public func series(id: String) async throws -> KomgaSeries {
        try await get("/api/v1/series/\(id)")
    }

    public func books(inSeries seriesID: String, matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
        var items = [
            URLQueryItem(name: "page", value: String(query.page)),
            URLQueryItem(name: "size", value: String(query.size)),
            URLQueryItem(name: "sort", value: "metadata.numberSort,\(query.ascending ? "asc" : "desc")")
        ]
        items += query.readStatus.map { URLQueryItem(name: "read_status", value: $0.rawValue) }
        return try await get("/api/v1/series/\(seriesID)/books", query: items)
    }

    public func book(id: String) async throws -> KomgaBook {
        try await get("/api/v1/books/\(id)")
    }

    public func keepReading(matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
        var items = [
            URLQueryItem(name: "page", value: String(query.page)),
            URLQueryItem(name: "size", value: String(query.size)),
            URLQueryItem(name: "read_status", value: KomgaReadStatus.inProgress.rawValue),
            URLQueryItem(name: "sort", value: "readProgress.readDate,desc")
        ]
        if let libraryID = query.libraryID {
            items.append(URLQueryItem(name: "library_id", value: libraryID))
        }
        return try await get("/api/v1/books", query: items)
    }

    public func onDeck(matching query: BookQuery) async throws -> KomgaPage<KomgaBook> {
        // No `sort`: the endpoint has its own ordering and rejects one
        // (`@PageableWithoutSortAsQueryParam`).
        var items = [
            URLQueryItem(name: "page", value: String(query.page)),
            URLQueryItem(name: "size", value: String(query.size))
        ]
        if let libraryID = query.libraryID {
            items.append(URLQueryItem(name: "library_id", value: libraryID))
        }
        return try await get("/api/v1/books/ondeck", query: items)
    }

    public func thumbnailData(for target: KomgaThumbnail, allowStaleCache: Bool) async throws -> Data? {
        var request = makeRequest(path: target.path, method: "GET")
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        if allowStaleCache {
            // Instant, no network attempt — either `URLSession.komga`'s
            // `URLCache` already has the bytes from an earlier revalidated
            // fetch, or this throws immediately rather than hanging on a
            // server that isn't there.
            request.cachePolicy = .returnCacheDataDontLoad
        }
        do {
            return try await send(request)
        } catch KomgaError.notFound {
            // A book whose poster hasn't been generated yet. The grid draws a
            // placeholder; an error banner would be noise during a scan.
            return nil
        }
    }

    // MARK: - KomgaServing: reader

    public func divinaManifest(forBook bookID: String) async throws -> KomgaDivinaManifest {
        // A single-publication manifest is `application/opds-publication+json`,
        // not the `application/opds+json` feeds use — Komga 406s the default
        // `Accept: application/json` `get()` otherwise sends. Found by hitting
        // a live server; no fixture would have caught it.
        try await get(
            "/opds/v2/books/\(bookID)/manifest/divina",
            accept: "application/opds-publication+json"
        )
    }

    public func pageImageData(at href: String) async throws -> Data {
        guard let url = URL(string: href, relativeTo: address.baseURL) else {
            throw KomgaError.decoding(description: "Malformed page link: \(href)")
        }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "GET"
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        guard let data = try await send(request) else {
            throw KomgaError.decoding(description: "Komga returned no image data for \(href).")
        }
        return data
    }

    public func putProgression(bookID: String, write: ProgressionWrite, device: KomgaDevice) async throws {
        let body = KomgaProgressionRequest(
            modified: KomgaDate.format(write.readDate),
            device: .init(id: device.id.uuidString, name: device.name),
            locator: .init(href: write.pageHref, type: write.mediaType, locations: .init(position: write.page))
        )
        var request = makeRequest(path: "/api/v1/books/\(bookID)/progression", method: "PUT")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request)
    }

    public func markRead(bookID: String) async throws {
        var request = makeRequest(path: "/api/v1/books/\(bookID)/read-progress", method: "PATCH")
        request.httpBody = try JSONEncoder().encode(KomgaReadProgressRequest(completed: true))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request)
    }

    public func markUnread(bookID: String) async throws {
        let request = makeRequest(path: "/api/v1/books/\(bookID)/read-progress", method: "DELETE")
        _ = try await send(request)
    }

    // MARK: - KomgaServing: download

    public func fileData(forBook bookID: String) async throws -> Data {
        guard let data = try await send(fileDownloadRequest(forBook: bookID)) else {
            throw KomgaError.decoding(description: "Komga returned no file data for book \(bookID).")
        }
        return data
    }

    public func fileDownloadRequest(forBook bookID: String) -> URLRequest {
        // Not `makeRequest`: this is a raw byte stream, not JSON, and the
        // default `Accept: application/json` has already 406'd one endpoint
        // that didn't expect it (the DIVINA manifest, see `divinaManifest`).
        var request = URLRequest(url: address.url(path: "/opds/v2/books/\(bookID)/file"))
        request.httpMethod = "GET"
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        applyAuthentication(to: &request)
        return request
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: address.url(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Factored out of `send` so ``fileDownloadRequest(forBook:)`` can build a
    /// fully authenticated request synchronously, without performing I/O.
    private func applyAuthentication(to request: inout URLRequest) {
        if let header = credential.header {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }
    }

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        accept: String? = nil
    ) async throws -> T {
        var request = makeRequest(path: path, method: "GET", query: query)
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        guard let data = try await send(request) else {
            throw KomgaError.decoding(description: "Expected a response body from \(path).")
        }
        return try decode(T.self, from: data)
    }

    /// Performs the request and maps the status code.
    ///
    /// Returns `nil` for 204 — Komga uses "No Content" to mean *never opened* on
    /// the progression endpoint, which is a value, not an error. Establishing
    /// that here keeps the sync engine from having to special-case it.
    @discardableResult
    private func send(_ request: URLRequest, authenticated: Bool = true) async throws -> Data? {
        var request = request
        if authenticated {
            applyAuthentication(to: &request)
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

/// The progression PUT body. File-private: only `KomgaClient`
/// constructs one, so there's no reason to make the wire shape part of the
/// public surface `KomgaServing` callers see. Flat rather than nested two deep
/// (`Locator.Locations`) — `PositionLocator` sits alongside its siblings
/// instead.
struct KomgaProgressionRequest: Encodable {
    let modified: String
    let device: ProgressionDevice
    let locator: ProgressionLocator
}

struct ProgressionDevice: Encodable {
    let id: String
    let name: String
}

struct ProgressionLocator: Encodable {
    let href: String
    let type: String
    let locations: PositionLocation
}

struct PositionLocation: Encodable {
    let position: Int
}

/// The read-progress PATCH body — `markRead`'s only shape;
/// `markUnread` is a bodyless DELETE.
struct KomgaReadProgressRequest: Encodable {
    let completed: Bool
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

    /// Komga sends nanosecond precision — a real `createdDate` is
    /// `2026-08-02T10:42:11.858195884Z`. Measured against Foundation rather than
    /// assumed: `ISO8601DateFormatter` accepts all nine fractional digits and
    /// honours the offset, so no rescaling is needed. The offset-less branch is
    /// the only shape the ISO formatters genuinely reject.
    static func parse(_ raw: String) -> Date? {
        if let date = withFractionalSeconds.date(from: raw) {
            return date
        }
        if let date = internetDateTime.date(from: raw) {
            return date
        }
        // `LocalDateTime` — no timezone at all. Drop any fractional part, since
        // the fallback format has nowhere to put it.
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
