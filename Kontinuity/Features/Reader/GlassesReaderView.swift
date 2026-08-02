//
//  GlassesReaderView.swift
//  Kontinuity
//
//  Mode B (READER-DESIGN §3): the surface that owns ALL keyboard/touch
//  handling for glasses mode, in both configurations —
//
//  - `showsContent: true`, the no-external-display iPad fallback: visible,
//    landscape, touch always enabled ("there's no blanket and nowhere else
//    to look").
//  - `showsContent: false`, a real external display connected: true black,
//    chrome-free, gated by `glasses.touchArmed`.
//
//  Both route through this one view because the external `UIWindowScene` can
//  never be key (PLAN phase 6's one architectural finding) — the Magic
//  Keyboard's events always land on the iPad's own window, which this is.
//  Content only ever renders here when `showsContent` is true; when it's
//  false, this iPad-side surface is a pure input source and the actual pixels
//  are drawn by `GlassesSceneDelegate`'s external `UIHostingController`,
//  observing the same `GlassesCoordinator`.
//

import KontinuityCore
import SwiftUI

struct GlassesReaderView: View {
    let glasses: GlassesCoordinator
    let showsContent: Bool
    let onExit: () -> Void
    let onNextBook: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showsContent, let band = currentBand, let loader = glasses.loader {
                BandPageView(band: band, pageSources: glasses.pageSources, loader: loader)
                    .ignoresSafeArea()
                    .accessibilityIdentifier(AID.glassesSurface)
                // The dim overlay's spec (READER-DESIGN §3) is written for
                // the true-external-display case, where the iPad panel is
                // already solid black; in the fallback path the iPad panel
                // *is* the reading surface, so it gets the same overlay a
                // dark-room reader would actually want.
                Color.black.opacity(glasses.dimLevel).ignoresSafeArea().allowsHitTesting(false)
                tapZones
            }

            if glasses.isStatusLineVisible {
                statusLine
            }

            if showsContent {
                exitButton
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(action: handleKeyPress)
    }

    private var currentBand: Band? {
        glasses.bands.indices.contains(glasses.currentBandIndex) ? glasses.bands[glasses.currentBandIndex] : nil
    }

    /// Touch is only ever gated by `touchArmed` when the iPad panel is the
    /// blacked-out companion to a real external display — the fallback path
    /// has no blanket and nowhere else to look, so it's always live there.
    private var canTouch: Bool {
        showsContent ? true : glasses.touchArmed
    }

    private var tapZones: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                tapZone(width: proxy.size.width / 3, action: glasses.retreatBand)
                Color.clear.frame(width: proxy.size.width / 3)
                tapZone(width: proxy.size.width / 3, action: glasses.advanceBand)
            }
        }
        .allowsHitTesting(canTouch)
    }

    private func tapZone(width: CGFloat, action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var statusLine: some View {
        VStack {
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 24)
                .accessibilityIdentifier(AID.glassesStatusLabel)
        }
        .transition(.opacity)
    }

    private var statusText: String {
        guard !glasses.bands.isEmpty else { return "" }
        var parts = ["\(glasses.currentBandIndex + 1) / \(glasses.bands.count)"]
        if glasses.isAutoScrolling {
            parts.append("auto")
        }
        if glasses.touchArmed {
            parts.append("touch")
        }
        return parts.joined(separator: " · ")
    }

    private var exitButton: some View {
        VStack {
            HStack {
                Spacer()
                Button("Exit", action: onExit)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding()
                    .accessibilityIdentifier(AID.glassesExit)
            }
            Spacer()
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space:
            if press.modifiers.contains(.shift) {
                glasses.retreatBand()
            } else {
                glasses.advanceBand()
            }
            return .handled
        case .rightArrow, .downArrow:
            glasses.advanceBand()
            return .handled
        case .leftArrow, .upArrow:
            glasses.retreatBand()
            return .handled
        case .pageDown:
            glasses.nextPage()
            return .handled
        case .pageUp:
            glasses.previousPage()
            return .handled
        case .escape:
            onExit()
            return .handled
        default:
            return handleCharacterKeyPress(press)
        }
    }

    /// N/P are the only bindings this doesn't fully implement: `N` reuses
    /// `ReaderModel`'s existing next-volume lookup, but there's no
    /// "previous volume" fetch anywhere in the app yet (Mode A never needed
    /// one either) — `P` is accepted and silently ignored rather than faking
    /// it, a known gap rather than a hidden bug.
    private func handleCharacterKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.characters.lowercased() {
        case "[": glasses.adjustDim(by: -0.1)
        case "]": glasses.adjustDim(by: 0.1)
        case "a": glasses.toggleAutoScroll()
        case "-": glasses.adjustAutoScrollSpeed(by: -0.25)
        case "=": glasses.adjustAutoScrollSpeed(by: 0.25)
        case "t": glasses.toggleTouch()
        case "n": onNextBook()
        default: return .ignored
        }
        return .handled
    }
}
