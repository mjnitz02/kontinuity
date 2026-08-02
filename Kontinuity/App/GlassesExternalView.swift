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
                BandPageView(band: band, pageSources: glasses.pageSources, loader: loader)
                    .ignoresSafeArea()
            }
            Color.black.opacity(glasses.dimLevel).ignoresSafeArea()
        }
    }

    private var currentBand: Band? {
        glasses.bands.indices.contains(glasses.currentBandIndex) ? glasses.bands[glasses.currentBandIndex] : nil
    }
}
