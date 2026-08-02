//
//  GlassesSettings.swift
//  Kontinuity
//
//  The tunable knobs for Mode B (READER-DESIGN §3): dim overlay level,
//  auto-scroll speed, and the band-overlap fraction BandLayout uses.
//  `UserDefaults`-backed, mirroring `DownloadSettings` — tuned once in bed,
//  kept every night, rather than reset back to defaults on every entry.
//

import Foundation

struct GlassesSettings: Sendable {
    static let defaultDimLevel: Double = 0
    static let defaultAutoScrollSpeed: Double = 1
    static let defaultBandOverlap: Double = 0.08

    private static let dimKey = "glasses.dimLevel"
    private static let autoScrollSpeedKey = "glasses.autoScrollSpeed"
    private static let bandOverlapKey = "glasses.bandOverlap"

    /// UserDefaults isn't Sendable in this SDK but is documented thread-safe.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var dimLevel: Double {
        get { defaults.object(forKey: Self.dimKey) as? Double ?? Self.defaultDimLevel }
        nonmutating set { defaults.set(newValue, forKey: Self.dimKey) }
    }

    var autoScrollSpeed: Double {
        get { defaults.object(forKey: Self.autoScrollSpeedKey) as? Double ?? Self.defaultAutoScrollSpeed }
        nonmutating set { defaults.set(newValue, forKey: Self.autoScrollSpeedKey) }
    }

    var bandOverlap: Double {
        get { defaults.object(forKey: Self.bandOverlapKey) as? Double ?? Self.defaultBandOverlap }
        nonmutating set { defaults.set(newValue, forKey: Self.bandOverlapKey) }
    }
}
