//
//  DownloadState.swift
//  KontinuityCore
//
//  A `Book` row's download lifecycle (PLAN §6). Separate from `isPending`,
//  which is phase 4's sync outbox flag — a book can be mid-download with no
//  read progress at all, and fully synced with no download in progress.
//

import Foundation

public enum DownloadState: String, Codable, Sendable, Hashable {
    case notDownloaded
    case queued
    case downloading
    case decompressing
    case downloaded
    case failed
}
