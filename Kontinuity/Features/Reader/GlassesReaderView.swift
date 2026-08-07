//
//  GlassesReaderView.swift
//  Kontinuity
//
//  Mode B (READER-DESIGN §3): the surface that owns ALL keyboard/touch
//  handling for glasses mode, in both configurations —
//
//  - `showsContent: true`, the no-external-display iPad fallback: visible,
//    landscape, touch live.
//  - `showsContent: false`, a real external display connected: true black,
//    chrome-free — this view renders nothing, so there's no touch surface
//    to speak of either.
//
//  Both route through this one view because the external `UIWindowScene` can
//  never be key (PLAN phase 6's one architectural finding) — the Magic
//  Keyboard's events always land on the iPad's own window, which this is.
//  The keys themselves arrive through `GlassesKeyCommandCatcher` rather than
//  SwiftUI's `onKeyPress`; see that file for why.
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

    /// Toggled by the centre-half tap, mirroring Mode A's `chromeVisible`
    /// (READER-DESIGN §1's "one control model") — visible on entry, same as
    /// `ReaderView`'s own default.
    @State private var chromeVisible = true

    /// Measured rather than guessed so the status line can clear the chrome
    /// toolbar — see `statusLine`, where not clearing it was the whole reason
    /// the speed indicator never appeared to work.
    @State private var chromeToolbarHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if showsContent, let band = currentBand, let loader = glasses.loader {
                    BandPageView(
                        band: band,
                        pageSources: glasses.pageSources,
                        pageGeometries: glasses.pageGeometries,
                        loader: loader,
                        widthFit: glasses.widthFit
                    )
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

                GlassesKeyCommandCatcher(onKey: handle)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

                if glasses.isStatusLineVisible {
                    statusLine
                }

                // Auto mode's controls belong on the reading surface, so they
                // show precisely when the chrome doesn't — the chrome covers
                // the page, and a control you can only reach by covering the
                // page is the arrangement this replaces.
                if showsContent, glasses.isAutoModeEnabled, !chromeVisible {
                    AutoScrollPill(glasses: glasses)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(24)
                        .transition(.opacity)
                }

                if showsContent, chromeVisible {
                    chrome
                }
            }
            // `BandPageView` above renders under `.ignoresSafeArea()`, so the
            // size fed to `BandLayout` must be measured the same way — a
            // safe-area-respecting size here would under-report what's
            // actually on screen (PLAN 6B §C), most visibly on an iPhone in
            // landscape where the Dynamic Island eats real width.
            .onAppear { glasses.updateGeometry(width: proxy.size.width, height: proxy.size.height) }
            .onChange(of: proxy.size) { _, newSize in
                glasses.updateGeometry(width: newSize.width, height: newSize.height)
            }
        }
        .ignoresSafeArea()
    }

    private var currentBand: Band? {
        glasses.bands.indices.contains(glasses.currentBandIndex) ? glasses.bands[glasses.currentBandIndex] : nil
    }

    /// Quarters, not thirds (READER-DESIGN §1 supersedes §2): edge quarters
    /// page, the centre half toggles chrome. The horizontal swipe (PLAN 6B
    /// §D) is attached to this same container. This view only ever mounts
    /// when `showsContent` is true, so touch is always live here — there is
    /// no case where the panel shows content but touch should be refused.
    private var tapZones: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                tapZone(width: proxy.size.width / 4, action: glasses.retreatBand)
                Color.clear
                    .frame(width: proxy.size.width / 2)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleChrome() }
                tapZone(width: proxy.size.width / 4, action: advanceOrNextBook)
            }
            .contentShape(Rectangle())
            .gesture(swipeGesture)
        }
    }

    /// Opening the chrome pauses the advance, the same as any other touch:
    /// the toolbar is opaque, so bands stepping on underneath it are bands
    /// nobody read. `interrupt()` only pauses — auto mode stays on, and the
    /// pill comes back paused when the chrome closes, one tap from resuming.
    private func toggleChrome() {
        glasses.interrupt()
        withAnimation { chromeVisible.toggle() }
    }

    private func tapZone(width: CGFloat, action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// A minimum displacement so a tap isn't eaten, and `|dx| > |dy|` so a
    /// vertical drag isn't mistaken for a page turn (READER-DESIGN §1).
    /// `advanceBand()`/`retreatBand()` already call `interrupt()`, so routing
    /// through them — rather than mutating `currentBandIndex` directly —
    /// pauses auto-scroll on a swipe the same way a keypress does, for free.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) else { return }
                if dx < 0 {
                    advanceOrNextBook()
                } else {
                    glasses.retreatBand()
                }
            }
    }

    /// Mode B's edge-of-book (READER-DESIGN §1's "one control model" applied
    /// to the forward gesture): `advanceBand()` alone just no-ops past the
    /// last band, same as it always has for the keyboard's `→`/`Space`, which
    /// is why "N"/the chrome button were the only way to reach the next
    /// volume by touch. No two-tap toast here the way Mode A's overswipe
    /// needs one — a `TabView` bounce is ambiguous about intent the way a
    /// quarter-tap or a thresholded swipe isn't, the same reasoning that
    /// keeps the continuous surface's footer button a single action (PLAN
    /// §12, phase 9 known limits).
    private func advanceOrNextBook() {
        if isAtLastBand {
            onNextBook()
        } else {
            glasses.advanceBand()
        }
    }

    /// The bug this padding fixes: `statusLine` and `chrome` are siblings in
    /// the same `ZStack`, both bottom-anchored, and `chrome` draws second — so
    /// its material toolbar painted straight over this text. Every control
    /// whose effect isn't legible from the artwork alone (width fit, and the
    /// speed buttons that used to live there) reported into a label the
    /// toolbar was covering, which is why adjusting them looked like it did
    /// nothing at all. Sitting the line above the measured toolbar costs the
    /// reader nothing when the chrome is closed and is the difference between
    /// feedback and no feedback when it's open.
    private var statusLine: some View {
        VStack {
            Spacer()
            Text(glasses.statusIndicatorText ?? statusText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, chromeVisible ? chromeToolbarHeight + 12 : 24)
                .accessibilityIdentifier(AID.glassesStatusLabel)
        }
        .transition(.opacity)
    }

    private var statusText: String {
        guard !glasses.bands.isEmpty else { return "" }
        var parts = ["\(glasses.currentBandIndex + 1) / \(glasses.bands.count)"]
        // Under a blanket the status line is the only feedback `C` gets — the
        // chrome button isn't on screen and the band content itself shifts
        // only subtly when the flow changes.
        if glasses.flow == .continuous {
            parts.append("strip")
        }
        // No "auto" token any more: `AutoScrollPill` is on screen for as long
        // as the mode is, and says both whether it's running and how fast,
        // which is strictly more than this ever did and doesn't fade out.
        return parts.joined(separator: " · ")
    }

    /// The fallback path's chrome (PLAN 6B §C's "Chrome" work item,
    /// READER-DESIGN §3's iPhone section): "next volume, dim, and auto-scroll
    /// have no gesture. Those go in chrome, reached by the centre-half tap,
    /// alongside the page indicator" — a phone in landscape has no keyboard
    /// to reach them with otherwise. `Exit` sits in
    /// the top-right, inside the right paging quarter, so it's kept a
    /// sibling above the tap layer rather than shadowed by it.
    private var chrome: some View {
        VStack {
            HStack {
                if !glasses.bands.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityIdentifier(AID.glassesPageLabel)
                }
                Spacer()
                Button("Exit", action: onExit)
                    .accessibilityIdentifier(AID.glassesExit)
            }
            .padding()

            Spacer()

            HStack(spacing: 16) {
                Button { glasses.adjustDim(by: -0.1) } label: { Image(systemName: "sun.max") }
                    .accessibilityIdentifier(AID.glassesDimDecrease)
                Button { glasses.adjustDim(by: 0.1) } label: { Image(systemName: "moon") }
                    .accessibilityIdentifier(AID.glassesDimIncrease)
                // One button, not three. Play/pause and the two speed steps
                // moved to `AutoScrollPill`, where they're reachable without
                // covering the page; all that's left here is entering and
                // leaving the mode, which is a thing you do once per sitting.
                Button {
                    glasses.toggleAutoMode()
                } label: {
                    Image(systemName: glasses.isAutoModeEnabled ? "a.circle.fill" : "a.circle")
                }
                .accessibilityLabel(glasses.isAutoModeEnabled ? "Disable auto mode" : "Enable auto mode")
                .accessibilityIdentifier(AID.glassesAutoScrollToggle)
                // `BandLayout.isLongStrip` guesses this from page aspect and
                // is right on everything measured so far, but it's still a
                // guess over scraped content — this is how it gets corrected,
                // and the correction sticks for the whole series (PLAN §12).
                Button {
                    glasses.toggleFlow()
                } label: {
                    Image(systemName: glasses.flow == .continuous ? "arrow.up.and.down" : "square.stack")
                }
                .accessibilityIdentifier(AID.glassesFlowToggle)
                // Narrower page, taller band, more overlap — the trade that
                // makes a phone in landscape readable, and the one thing here
                // whose right value is a matter of eyesight rather than
                // geometry, so it's a dial rather than a constant.
                Button { glasses.adjustWidthFit(by: -0.05) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityIdentifier(AID.glassesWidthFitDecrease)
                Button { glasses.adjustWidthFit(by: 0.05) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityIdentifier(AID.glassesWidthFitIncrease)
                if isAtLastBand {
                    Button("Next volume", action: onNextBook)
                        .accessibilityIdentifier(AID.glassesNextBook)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeToolbarHeight = $0 }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private var isAtLastBand: Bool {
        !glasses.bands.isEmpty && glasses.currentBandIndex == glasses.bands.count - 1
    }

    /// Intent to action. Which hardware keys produce which intent lives in
    /// `GlassesKeyCommands`, so this stays a plain table of what Mode B does.
    /// Split along `GlassesCoordinator`'s own Navigation/Controls seam —
    /// moving the reader versus changing how it renders.
    private func handle(_ key: GlassesKey) {
        switch key {
        case .advanceBand: glasses.advanceBand()
        case .retreatBand: glasses.retreatBand()
        case .nextPage: glasses.nextPage()
        case .previousPage: glasses.previousPage()
        case .exit: onExit()
        case .nextBook: onNextBook()
        case .dimDecrease, .dimIncrease, .toggleAutoScroll, .exitAutoMode,
             .autoScrollSlower, .autoScrollFaster, .toggleFlow,
             .widthFitDecrease, .widthFitIncrease:
            handleControl(key)
        }
    }

    private func handleControl(_ key: GlassesKey) {
        switch key {
        case .dimDecrease: glasses.adjustDim(by: -0.1)
        case .dimIncrease: glasses.adjustDim(by: 0.1)
        // `A` is play/pause, and enters auto mode if it isn't on — the
        // keyboard's equivalent of the pill's centre button. `⇧A` is the way
        // back out, since the keyboard reader's pill is an indicator that
        // otherwise never leaves.
        case .toggleAutoScroll: glasses.toggleAutoScrollPlayback()
        case .exitAutoMode: glasses.setAutoMode(false)
        case .autoScrollSlower: glasses.adjustAutoScrollStep(by: -1)
        case .autoScrollFaster: glasses.adjustAutoScrollStep(by: 1)
        case .toggleFlow: glasses.toggleFlow()
        case .widthFitDecrease: glasses.adjustWidthFit(by: -0.05)
        case .widthFitIncrease: glasses.adjustWidthFit(by: 0.05)
        case .advanceBand, .retreatBand, .nextPage, .previousPage, .exit, .nextBook:
            break
        }
    }
}
