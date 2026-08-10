//
//  GlassesSettings.swift
//  Kontinuity
//
//  The tunable knobs for Mode B: dim overlay level,
//  auto-scroll speed, the band overlap and width fit BandLayout uses, and the
//  per-series continuous/per-page override.
//  `UserDefaults`-backed, mirroring `DownloadSettings` — tuned once in bed,
//  kept every night, rather than reset back to defaults on every entry.
//

import Foundation
import KontinuityCore

/// `nonisolated` on the type itself — `Sendable` conformance alone doesn't
/// opt a declaration out of the module's default `MainActor` isolation, so
/// `init(defaults:)` needs this to stay callable as a default-parameter
/// expression, which is evaluated in a synchronous nonisolated context.
nonisolated struct GlassesSettings: Sendable {
    static let defaultDimLevel: Double = 0
    static let defaultAutoScrollStep = 1
    static let defaultBandOverlap = BandLayout.defaultOverlap

    private static let dimKey = "glasses.dimLevel"
    /// Deliberately **not** the old `glasses.autoScrollSpeed` key: that one
    /// held a Double multiplier over a 3s base and this holds an index into
    /// `autoScrollIntervals`, so reusing it would read a stored 1.0 as step 1
    /// by coincidence and a stored 0.25 as an out-of-range step.
    private static let autoScrollStepKey = "glasses.autoScrollStep"
    /// Deliberately **not** the old `glasses.bandOverlap` key: that one held a
    /// fraction-of-a-band and this holds page-width units, so reusing it would
    /// silently reinterpret a stored 0.08 as a huge overlap.
    private static let bandOverlapKey = "glasses.bandOverlapWidths"
    private static let widthFitKey = "glasses.bandWidthFit"
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

    /// An index into `GlassesCoordinator.autoScrollIntervals`, not a duration
    /// — four coarse steps rather than a continuous dial, because the pill
    /// signals the current one by colour alone and no one distinguishes
    /// twenty colours through birdbath optics.
    var autoScrollStep: Int {
        get { defaults.object(forKey: Self.autoScrollStepKey) as? Int ?? Self.defaultAutoScrollStep }
        nonmutating set { defaults.set(newValue, forKey: Self.autoScrollStepKey) }
    }

    /// In page-width units — see `BandLayout.defaultOverlap` for why that's
    /// the unit rather than a fraction of the band.
    var bandOverlap: Double {
        get { defaults.object(forKey: Self.bandOverlapKey) as? Double ?? Self.defaultBandOverlap }
        nonmutating set { defaults.set(newValue, forKey: Self.bandOverlapKey) }
    }

    /// `nil` — the default — means "derive it from the viewport's aspect"
    /// (`BandLayout.widthFit(forViewportAspect:)`). A stored value is a
    /// deliberate correction made from the reader's own chrome, and like
    /// `dimLevel` it's the kind of thing tuned once in bed and kept, so it
    /// outranks the automatic value from then on.
    var bandWidthFit: Double? {
        get { defaults.object(forKey: Self.widthFitKey) as? Double }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.widthFitKey)
            } else {
                defaults.removeObject(forKey: Self.widthFitKey)
            }
        }
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
    /// arrived at for SwiftData.
    func setFlowOverride(_ flow: BandFlow?, forSeries seriesID: String) {
        var overrides = defaults.dictionary(forKey: Self.flowOverridesKey) ?? [:]
        overrides[seriesID] = flow.map { $0 == .continuous }
        defaults.set(overrides, forKey: Self.flowOverridesKey)
    }
}
