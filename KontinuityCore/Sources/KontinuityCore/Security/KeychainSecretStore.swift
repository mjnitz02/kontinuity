//
//  KeychainSecretStore.swift
//  KontinuityCore
//
//  Generic-password Keychain storage for the Komga API key.
//

import Foundation
import Security

public struct KeychainSecretStore: SecretStoring {
    private let service: String

    public init(service: String = "org.mattnitzken.Kontinuity.apiKey") {
        self.service = service
    }

    public func store(_ secret: String, for account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw SecretStoreError.malformedData }

        // The key is only ever needed while the app is running in the foreground
        // or finishing a background download, so require the device to have been
        // unlocked once. ThisDeviceOnly keeps it out of iCloud Keychain backups —
        // it's revocable server-side, so syncing it across devices is a liability
        // rather than a convenience.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let insert = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.unexpectedStatus(addStatus) }
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func secret(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.malformedData
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func removeSecret(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}
