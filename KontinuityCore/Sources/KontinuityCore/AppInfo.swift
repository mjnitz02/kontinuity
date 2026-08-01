//
//  AppInfo.swift
//  KontinuityCore
//
//  Identity constants shared by the app and, later, the download engine's
//  User-Agent and the progression API's device record.
//

import Foundation

public enum AppInfo {
    public static let name = "Kontinuity"

    /// Sent as the `device.name` on progression writes so Komga's read-progress
    /// rows say something recognisable rather than "unknown device".
    public static let userAgent = "Kontinuity/\(marketingVersion)"

    public static let marketingVersion = "0.1.0"

    /// Minimum Komga server version this client is built against. The OPDS v2
    /// DIVINA manifest and the Progression API both predate this, but 1.25 is
    /// what the behaviour in `.claude/KOMGA-API.md` was read from.
    public static let minimumKomgaVersion = "1.25.0"
}
