//
//  SecretStoreTests.swift
//  KontinuityTests
//
//  Covers both implementations of `SecretStoring`. The Keychain-backed one is
//  testable because the bundle is injected into the app host, so SecItem calls
//  run with the app's entitlements rather than a bare test process's.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("SecretStoring")
struct SecretStoreTests {
    @Test("stores and reads back a secret")
    func roundTrip() throws {
        let store = InMemorySecretStore()
        try store.store("abc123", for: "account-1")
        #expect(try store.secret(for: "account-1") == "abc123")
    }

    @Test("returns nil for an unknown account rather than throwing")
    func missingIsNil() throws {
        let store = InMemorySecretStore()
        #expect(try store.secret(for: "nope") == nil)
    }

    @Test("overwrites an existing secret")
    func overwrite() throws {
        let store = InMemorySecretStore()
        try store.store("old", for: "account-1")
        try store.store("new", for: "account-1")
        #expect(try store.secret(for: "account-1") == "new")
    }

    @Test("removes a secret, and removing again is not an error")
    func remove() throws {
        let store = InMemorySecretStore()
        try store.store("abc123", for: "account-1")
        try store.removeSecret(for: "account-1")
        #expect(try store.secret(for: "account-1") == nil)
        try store.removeSecret(for: "account-1")
    }

    @Test("keeps accounts separate")
    func accountsAreIsolated() throws {
        let store = InMemorySecretStore()
        try store.store("one", for: "a")
        try store.store("two", for: "b")
        #expect(try store.secret(for: "a") == "one")
        #expect(try store.secret(for: "b") == "two")
    }
}

/// The real Keychain, exercised in the app host process (the test bundle is
/// injected into it, so `SecItemAdd` runs with the app's entitlements). Each
/// test uses its own service name so a failure can't leave state behind.
@Suite("KeychainSecretStore")
struct KeychainSecretStoreTests {
    private func makeStore() -> KeychainSecretStore {
        KeychainSecretStore(service: "org.mattnitzken.Kontinuity.tests.\(UUID().uuidString)")
    }

    @Test("stores, reads back, overwrites and removes an API key")
    func roundTrip() throws {
        let store = makeStore()
        let account = UUID().uuidString

        #expect(try store.secret(for: account) == nil)

        try store.store("minted-key", for: account)
        #expect(try store.secret(for: account) == "minted-key")

        // The update branch: a reconnect replaces the key rather than failing
        // with errSecDuplicateItem.
        try store.store("rotated-key", for: account)
        #expect(try store.secret(for: account) == "rotated-key")

        try store.removeSecret(for: account)
        #expect(try store.secret(for: account) == nil)
        // Removing twice is a no-op, so disconnect stays idempotent.
        try store.removeSecret(for: account)
    }

    @Test("keeps separate accounts isolated")
    func accountsAreIsolated() throws {
        let store = makeStore()
        let first = UUID().uuidString
        let second = UUID().uuidString

        try store.store("one", for: first)
        try store.store("two", for: second)
        #expect(try store.secret(for: first) == "one")
        #expect(try store.secret(for: second) == "two")

        try store.removeSecret(for: first)
        try store.removeSecret(for: second)
    }
}

@Suite("Server model")
struct ServerModelTests {
    @Test("rebuilds a client from the stored URL and Keychain reference")
    func buildsClient() throws {
        let store = InMemorySecretStore()
        let server = Server(baseURLString: "http://nas.local:25600", deviceName: "iPad")
        try store.store("stored-key", for: server.apiKeyRef)

        let client = try #require(try server.client(secrets: store))
        #expect(client.address.baseURL.absoluteString == "http://nas.local:25600")
    }

    @Test("yields no client when the Keychain entry is gone")
    func missingKeyYieldsNoClient() throws {
        let server = Server(baseURLString: "http://nas.local:25600", deviceName: "iPad")
        #expect(try server.client(secrets: InMemorySecretStore()) == nil)
    }

    @Test("mints a distinct device id and key reference per server")
    func identifiersAreUnique() {
        let first = Server(baseURLString: "http://a.local", deviceName: "iPad")
        let second = Server(baseURLString: "http://b.local", deviceName: "iPad")
        #expect(first.deviceID != second.deviceID)
        #expect(first.apiKeyRef != second.apiKeyRef)
    }
}
