//
//  ReaderSettings.swift
//  Kontinuity
//
//  Mode A's own persisted preferences — the panel counterpart to
//  `GlassesSettings`, and `UserDefaults`-backed the same way.
//

import Foundation

/// `nonisolated` for the same reason as `GlassesSettings`: `init(defaults:)`
/// is used as a default-parameter expression, which is evaluated in a
/// synchronous nonisolated context.
nonisolated struct ReaderSettings: Sendable {
    private static let landscapeSpreadsKey = "reader.landscapeSpreads"

    /// UserDefaults isn't Sendable in this SDK but is documented thread-safe.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a landscape container pairs pages into two-page spreads or
    /// shows one page at a time. Global rather than per-series: it's about how
    /// the reader wants to hold the iPad, not about the book. Defaults to
    /// spreads, the behaviour before this was a choice.
    var landscapeSpreads: Bool {
        get { defaults.object(forKey: Self.landscapeSpreadsKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.landscapeSpreadsKey) }
    }
}
