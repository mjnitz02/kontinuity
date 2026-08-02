//
//  ServerAddress.swift
//  KontinuityCore
//
//  Normalising whatever the user typed into a base URL we can safely append
//  paths to. Pure and synchronous on purpose — this is the part of "connect"
//  most likely to be wrong, and it's testable without a server.
//

import Foundation

/// A validated Komga base URL: scheme + host (+ port, + reverse-proxy subpath),
/// with no trailing slash and no API suffix.
public struct ServerAddress: Sendable, Hashable {
    public let baseURL: URL

    /// Wraps an already-trusted URL. Prefer ``init(normalizing:)`` for user input.
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Builds an address from free-form user input.
    ///
    /// Accepts `10.0.0.5:25600`, `http://nas.local:25600/`, `komga.example.com`,
    /// and deep links like `https://example.com/komga/api/v1` — all normalise to
    /// the base a request path can be appended to.
    public init(normalizing raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KomgaError.invalidServerAddress(reason: "Enter your Komga server address.")
        }

        // No scheme typed? Infer one from the host: a LAN box is almost always
        // plain HTTP (and Info.plist's NSAllowsLocalNetworking permits exactly
        // that), while anything routable should be HTTPS.
        let hasScheme = trimmed.contains("://")
        let probe = hasScheme ? trimmed : "http://" + trimmed

        guard var components = URLComponents(string: probe) else {
            throw KomgaError.invalidServerAddress(reason: "That doesn't look like a valid address.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw KomgaError.invalidServerAddress(reason: "That address is missing a host name.")
        }

        if hasScheme {
            let scheme = (components.scheme ?? "").lowercased()
            guard scheme == "http" || scheme == "https" else {
                throw KomgaError.invalidServerAddress(reason: "Use an http:// or https:// address.")
            }
            components.scheme = scheme
        } else {
            components.scheme = Self.isLocalNetworkHost(host) ? "http" : "https"
        }

        // Credentials in the URL would end up in logs; the API key is the auth path.
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = Self.strippingAPISuffixes(from: components.path)

        guard let url = components.url else {
            throw KomgaError.invalidServerAddress(reason: "That doesn't look like a valid address.")
        }
        baseURL = url
    }

    /// Absolute URL for an API path, preserving any reverse-proxy subpath.
    ///
    /// Built through `URLComponents` rather than `URL.appending(path:)` so the
    /// subpath concatenation is explicit — appending relative paths to a URL
    /// whose path is empty behaves differently than to one ending in a segment.
    public func url(path: String, query: [URLQueryItem] = []) -> URL {
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        components.path += suffix
        // Empty rather than `[]` matters: setting `queryItems = []` emits a bare
        // trailing "?", which some reverse proxies pass through to Komga verbatim.
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? baseURL
    }

    /// What we show back to the user once a server is saved.
    public var displayName: String {
        baseURL.absoluteString
    }

    // MARK: - Normalisation helpers

    /// Suffixes a user might paste from a browser or an OPDS client. Ordered
    /// longest-first so `/komga/api/v1` collapses to `/komga`, not `/komga/v1`.
    private static let apiSuffixes = ["/api/v1", "/api/v2", "/api", "/opds/v2", "/opds/v1.2", "/opds"]

    private static func strippingAPISuffixes(from path: String) -> String {
        var path = path
        while path.hasSuffix("/") {
            path.removeLast()
        }

        var didStrip = true
        while didStrip {
            didStrip = false
            for suffix in apiSuffixes where path.lowercased().hasSuffix(suffix) {
                path.removeLast(suffix.count)
                while path.hasSuffix("/") {
                    path.removeLast()
                }
                didStrip = true
                break
            }
        }
        return path
    }

    /// Hosts that are reachable only on the local network, and therefore expected
    /// to be served over plain HTTP.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" {
            return true
        }
        for suffix in [".local", ".lan", ".home", ".internal", ".localdomain"] where host.hasSuffix(suffix) {
            return true
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard octets.count == 4, let first = octets[0], let second = octets[1],
              octets[2] != nil, octets[3] != nil
        else {
            return false
        }

        switch first {
        case 10, 127: return true
        case 172: return (16 ... 31).contains(second)
        case 192: return second == 168
        case 169: return second == 254
        default: return false
        }
    }
}
