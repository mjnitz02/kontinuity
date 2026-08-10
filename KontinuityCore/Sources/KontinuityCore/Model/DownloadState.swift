//
//  DownloadState.swift
//  KontinuityCore
//
//  A `Book` row's download lifecycle. Separate from `isPending`, the sync
//  outbox flag — a book can be mid-download with no read progress at all, and
//  fully synced with no download in progress.
//

import Foundation

public enum DownloadState: String, Codable, Sendable, Hashable {
    case notDownloaded
    case queued
    case downloading
    case decompressing
    case downloaded
    case failed

    /// Work is under way and will finish on its own — the three states the UI
    /// draws as a progress row and offers a Cancel for.
    public var isActive: Bool {
        switch self {
        case .queued, .downloading, .decompressing: true
        case .notDownloaded, .downloaded, .failed: false
        }
    }
}
