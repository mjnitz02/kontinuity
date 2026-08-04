//
//  GlassesSettings.swift
//  Kontinuity
//
//  The tunable knobs for Mode B (READER-DESIGN §3): dim overlay level,
//  auto-scroll speed, the band-overlap fraction BandLayout uses, and the
//  per-series continuous/per-page override (PLAN §12).
//  `UserDefaults`-backed, mirroring `DownloadSettings` — tuned once in bed,
//  kept every night, rather than reset back to defaults on every entry.
//

import Foundation
import KontinuityCore

struct GlassesSettings: Sendable {
    static let defaultDimLevel: Double = 0
    static let defaultAutoScrollSpeed: Double = 1
    static let defaultBandOverlap: Double = 0.08

    private static let dimKey = "glasses.dimLevel"
    private static let autoScrollSpeedKey = "glasses.autoScrollSpeed"
    private static let bandOverlapKey = "glasses.bandOverlap"
    private static let flowOverridesKey = "glasses.flowOverrides"

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

    /// `nil` means "no one has corrected the auto-detection for this series"
    /// — `BandLayout.isLongStrip` decides. Keyed by **series**, not book: a
    /// web comic is a property of the whole series, and re-toggling it every
    /// chapter would be worse than not offering the toggle at all.
    func flowOverride(forSeries seriesID: String) -> BandFlow? {
        guard let isContinuous = defaults.dictionary(forKey: Self.flowOverridesKey)?[seriesID] as? Bool else {
            return nil
        }
        return isContinuous ? .continuous : .perPage
    }

    /// Stored as a `Bool` rather than the enum's name so the defaults domain
    /// holds a plain plist value, the same reasoning `Book.downloadStateRaw`
    /// arrived at for SwiftData (PLAN phase 5, bug 2).
    func setFlowOverride(_ flow: BandFlow?, forSeries seriesID: String) {
        var overrides = defaults.dictionary(forKey: Self.flowOverridesKey) ?? [:]
        overrides[seriesID] = flow.map { $0 == .continuous }
        defaults.set(overrides, forKey: Self.flowOverridesKey)
    }
}
