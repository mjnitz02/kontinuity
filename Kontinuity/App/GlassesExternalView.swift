//
//  GlassesExternalView.swift
//  Kontinuity
//
//  The actual pixels shown on a real external display, connected via
//  `UIWindowSceneSessionRoleExternalDisplayNonInteractive` and built by
//  `GlassesSceneDelegate`. A pure observer — no gesture recognizers, no key
//  handling, nothing interactive, because that scene can never be key (PLAN
//  phase 6's one architectural finding). It renders the same `Band` the
//  iPad's own `GlassesReaderView` is stepping through, reading everything —
//  band index, `pageSources`, `loader`, dim level — off the single shared
//  `GlassesCoordinator` handed over via `AppDelegate`'s static handoff.
//
//  The dim overlay applies only here, never on the iPad panel, which stays
//  true black regardless (READER-DESIGN §3).
//

import KontinuityCore
import SwiftUI

struct GlassesExternalView: View {
    let glasses: GlassesCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let band = currentBand, let loader = glasses.loader {
                BandPageView(
                    band: band,
                    pageSources: glasses.pageSources,
                    pageGeometries: glasses.pageGeometries,
                    loader: loader,
                    widthFit: glasses.widthFit
                )
                .ignoresSafeArea()
            }
            Color.black.opacity(glasses.dimLevel).ignoresSafeArea()

            // Above the dim overlay deliberately: it's a status readout, and
            // dimming it along with the artwork would defeat the point at
            // exactly the dim levels a dark room wants. Non-interactive here
            // — this scene can never be key, so the reader drives it from the
            // keyboard and only *reads* this.
            if glasses.isAutoModeEnabled {
                AutoScrollPill(glasses: glasses, isInteractive: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(24)
            }
        }
    }

    private var currentBand: Band? {
        glasses.bands.indices.contains(glasses.currentBandIndex) ? glasses.bands[glasses.currentBandIndex] : nil
    }
}
