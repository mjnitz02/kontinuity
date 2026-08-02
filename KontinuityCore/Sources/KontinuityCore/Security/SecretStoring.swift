//
//  SecretStoring.swift
//  KontinuityCore
//
//  The API key is the one genuinely sensitive value the app holds, so it never
//  goes near SwiftData or UserDefaults. The protocol exists so the connect flow
//  is testable without the Keychain, which needs entitlements a unit-test bundle
//  doesn't have.
//

import Foundation

public protocol SecretStoring: Sendable {
    func store(_ secret: String, for account: String) throws
    func secret(for account: String) throws -> String?
    func removeSecret(for account: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case malformedData
}

extension SecretStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            "Keychain error \(status)."
        case .malformedData:
            "The stored credential could not be read."
        }
    }
}

/// In-memory implementation for tests and SwiftUI previews.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var secrets: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func store(_ secret: String, for account: String) throws {
        lock.withLock { secrets[account] = secret }
    }

    public func secret(for account: String) throws -> String? {
        lock.withLock { secrets[account] }
    }

    public func removeSecret(for account: String) throws {
        lock.withLock { _ = secrets.removeValue(forKey: account) }
    }
}
