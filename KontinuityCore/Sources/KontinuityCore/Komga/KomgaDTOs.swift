//
//  KomgaDTOs.swift
//  KontinuityCore
//
//  Wire types for the phase-1 surface. Shapes taken from Komga 1.25.0's
//  UserDto.kt / ApiKeyDto.kt, decoding only the fields we actually use.
//

import Foundation

/// `GET /api/v2/users/me`
public struct KomgaUser: Decodable, Sendable, Hashable {
    public let id: String
    public let email: String
    public let roles: Set<String>
    public let sharedAllLibraries: Bool
    public let sharedLibrariesIds: Set<String>

    public init(
        id: String,
        email: String,
        roles: Set<String>,
        sharedAllLibraries: Bool = true,
        sharedLibrariesIds: Set<String> = []
    ) {
        self.id = id
        self.email = email
        self.roles = roles
        self.sharedAllLibraries = sharedAllLibraries
        self.sharedLibrariesIds = sharedLibrariesIds
    }

    public var isAdmin: Bool {
        roles.contains("ADMIN")
    }

    /// Gates `GET /opds/v2/books/{id}/file`. Without it the download engine has
    /// to fall back to per-page fetches.
    public var canDownloadFiles: Bool {
        roles.contains("FILE_DOWNLOAD")
    }

    /// Gates per-page streaming — without it there is no reader at all.
    public var canStreamPages: Bool {
        roles.contains("PAGE_STREAMING")
    }
}

/// `POST /api/v2/users/me/api-keys` — the only response that carries the secret.
/// Listing keys afterwards returns them redacted, so this value must be stored
/// at creation time or it's gone.
public struct KomgaAPIKey: Decodable, Sendable, Hashable {
    public let id: String
    public let userId: String
    public let key: String
    public let comment: String
    public let createdDate: Date

    public init(id: String, userId: String, key: String, comment: String, createdDate: Date) {
        self.id = id
        self.userId = userId
        self.key = key
        self.comment = comment
        self.createdDate = createdDate
    }
}

/// Request body for creating a key. Komga requires a non-blank comment and
/// rejects duplicates with 400, so the comment doubles as the device label.
struct KomgaAPIKeyRequest: Encodable {
    let comment: String
}
