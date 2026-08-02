//
//  Server.swift
//  KontinuityCore
//
//  The single persisted server record (multi-server is an explicit non-goal —
//  PLAN §1). This is also where the SwiftData store starts; phases 2+ add
//  Series/Book/PageRef/DownloadJob alongside it.
//

import Foundation
import SwiftData

@Model
public final class Server {
    /// Normalised base URL. Stored as a string because SwiftData handles URL
    /// round-tripping inconsistently across migrations; ``address`` re-parses it.
    public var baseURLString: String

    /// Stable per-install identifier sent as `device.id` on every progression
    /// write. Minted once and never regenerated — Komga uses it to attribute
    /// read progress, so a new value each launch would make the server's
    /// device history useless (KOMGA-API §4).
    public var deviceID: UUID

    /// Sent as `device.name`. User-visible on Komga's read-progress rows.
    public var deviceName: String

    /// Keychain account under which the API key is stored. The key itself is
    /// never in the SwiftData store.
    public var apiKeyRef: String

    /// Komga's own id for the key, present only when *we* minted it. Lets
    /// disconnecting revoke the key server-side instead of orphaning it. Nil
    /// when the user pasted a key they created in Komga's web UI — revoking
    /// that one is their call, not ours.
    public var apiKeyID: String?

    public var userEmail: String?
    public var addedDate: Date
    public var lastConnectedDate: Date?

    public init(
        baseURLString: String,
        deviceID: UUID = UUID(),
        deviceName: String,
        apiKeyRef: String = UUID().uuidString,
        apiKeyID: String? = nil,
        userEmail: String? = nil,
        addedDate: Date = .now,
        lastConnectedDate: Date? = nil
    ) {
        self.baseURLString = baseURLString
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.apiKeyRef = apiKeyRef
        self.apiKeyID = apiKeyID
        self.userEmail = userEmail
        self.addedDate = addedDate
        self.lastConnectedDate = lastConnectedDate
    }

    public var address: ServerAddress? {
        URL(string: baseURLString).map(ServerAddress.init(baseURL:))
    }

    /// Rebuilds the authenticated client for this server, or nil if the Keychain
    /// no longer holds the key (restored backup, manual removal).
    public func client(secrets: SecretStoring, session: URLSession = .shared) throws -> KomgaClient? {
        guard let address, let key = try secrets.secret(for: apiKeyRef) else { return nil }
        return KomgaClient(address: address, credential: .apiKey(key), session: session)
    }
}
