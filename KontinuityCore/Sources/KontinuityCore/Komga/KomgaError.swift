//
//  KomgaError.swift
//  KontinuityCore
//
//  One error type for the whole Komga boundary. The status codes that carry
//  protocol meaning get their own cases — notably 409, which the sync engine
//  treats as "server is ahead", not as a failure (see .claude/KOMGA-API.md §4).
//

import Foundation

public enum KomgaError: Error, Equatable, Sendable {
    /// The typed address couldn't be turned into a usable base URL.
    case invalidServerAddress(reason: String)
    /// 401 — bad credentials, or an API key that's been revoked server-side.
    case unauthorized
    /// 403 — authenticated but the account lacks the role. `FILE_DOWNLOAD` is
    /// the one that matters; the download engine degrades rather than dying.
    case forbidden
    case notFound
    /// 409 — Komga's monotonic clock guard on progression writes. Never retry.
    case conflict
    case badRequest(message: String?)
    case unexpectedStatus(code: Int, body: String?)
    case transport(code: URLError.Code, description: String)
    case decoding(description: String)
}

extension KomgaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidServerAddress(reason):
            reason
        case .unauthorized:
            "Komga rejected those credentials."
        case .forbidden:
            "That account doesn't have permission for this."
        case .notFound:
            "The server responded, but that endpoint is missing. Is this a Komga server?"
        case .conflict:
            "The server already has newer progress for this book."
        case let .badRequest(message):
            message ?? "The server rejected the request."
        case let .unexpectedStatus(code, _):
            "The server returned an unexpected response (HTTP \(code))."
        case let .transport(_, description):
            description
        case .decoding:
            "The server's response wasn't in the expected format."
        }
    }

    /// Extra guidance for the connect screen, where the fix is usually a setting.
    public var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            "Check the email and password, or generate a fresh API key in Komga."
        case .notFound:
            "Check the address — it should point at the root of Komga, not a sub-page."
        case .transport:
            "Check the address and that the server is reachable from this network."
        default:
            nil
        }
    }

    /// Maps a transport failure, preserving the code so callers can distinguish
    /// "offline" (which the sync outbox tolerates) from a hard failure.
    static func from(_ error: some Error) -> KomgaError {
        if let komga = error as? KomgaError {
            return komga
        }
        if let urlError = error as? URLError {
            return .transport(code: urlError.code, description: urlError.localizedDescription)
        }
        if let decoding = error as? DecodingError {
            return .decoding(description: String(describing: decoding))
        }
        return .transport(code: .unknown, description: error.localizedDescription)
    }

    /// True when the failure is "the network isn't there", which callers queue
    /// through rather than surface as an error.
    public var isOffline: Bool {
        guard case let .transport(code, _) = self else { return false }
        return [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .timedOut,
            .cannotFindHost,
            .dataNotAllowed
        ].contains(code)
    }
}
