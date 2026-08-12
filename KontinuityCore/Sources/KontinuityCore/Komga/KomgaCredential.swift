//
//  KomgaCredential.swift
//  KontinuityCore
//
//  Two auth modes, both header-based. Komga
//  installs the X-API-Key filter globally, so the same key authenticates
//  /api/v1, /api/v2 and /opds/v2 alike. Basic exists only to bootstrap a key.
//

import Foundation

public enum KomgaCredential: Sendable, Hashable {
    /// Used once, on the connect screen, to mint an API key. Never persisted.
    case basic(email: String, password: String)
    /// What every subsequent request uses. This is what lands in the Keychain.
    case apiKey(String)

    /// Header name/value to attach to a request.
    var header: (field: String, value: String)? {
        switch self {
        case let .basic(email, password):
            let joined = "\(email):\(password)"
            guard let encoded = joined.data(using: .utf8)?.base64EncodedString() else { return nil }
            return ("Authorization", "Basic \(encoded)")
        case let .apiKey(key):
            return ("X-API-Key", key)
        }
    }
}
