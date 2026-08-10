//
//  DownloadSettings.swift
//  Kontinuity
//
//  The two user-facing retention knobs: a storage cap (default 8 GB, a guess)
//  and whether a finished, synced book auto-deletes its files.
//  `UserDefaults`-backed.
//

import Foundation

struct DownloadSettings: Sendable {
    static let defaultCapBytes: Int64 = 8 * 1024 * 1024 * 1024

    private static let capKey = "download.storageCapBytes"
    private static let autoRemoveKey = "download.autoRemoveOnFinish"

    /// UserDefaults isn't Sendable in this SDK but is documented thread-safe.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var storageCapBytes: Int64 {
        get {
            let stored = defaults.object(forKey: Self.capKey) as? Int64
            return stored ?? Self.defaultCapBytes
        }
        nonmutating set { defaults.set(newValue, forKey: Self.capKey) }
    }

    var autoRemoveOnFinish: Bool {
        get { defaults.object(forKey: Self.autoRemoveKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoRemoveKey) }
    }
}
