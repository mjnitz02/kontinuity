//
//  KomgaServing.swift
//  KontinuityCore
//
//  The single boundary between the app and the server. PLAN §2 splits transports
//  (OPDS v2 for reading and sync, /api for read-status queries) deliberately —
//  this protocol is where that split stays contained instead of smearing across
//  the feature code. It grows one phase at a time; today it's phase 1's surface.
//

import Foundation

public protocol KomgaServing: Sendable {
    /// Unauthenticated reachability probe against `/actuator/health`, which
    /// Komga's `SecurityConfiguration` leaves open to all. Lets the connect
    /// screen tell "wrong address" apart from "wrong credentials".
    func checkReachable() async throws

    /// `GET /api/v2/users/me` — the authenticated identity check.
    func currentUser() async throws -> KomgaUser

    /// `POST /api/v2/users/me/api-keys`. The response is the only time the key
    /// itself is returned; afterwards Komga redacts it.
    func createAPIKey(comment: String) async throws -> KomgaAPIKey

    /// `DELETE /api/v2/users/me/api-keys/{id}` — used to revoke on disconnect so
    /// signing out doesn't leave an orphaned key on the server forever.
    func deleteAPIKey(id: String) async throws
}
