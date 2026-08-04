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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if showsContent, let band = currentBand, let loader = glasses.loader {
                    BandPageView(
                        band: band,
                        pageSources: glasses.pageSources,
                        pageGeometries: glasses.pageGeometries,
                        loader: loader
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
                    .onTapGesture { withAnimation { chromeVisible.toggle() } }
                tapZone(width: proxy.size.width / 4, action: advanceOrNextBook)
            }
            .contentShape(Rectangle())
            .gesture(swipeGesture)
        }
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
        // Under a blanket the status line is the only feedback `C` gets — the
        // chrome button isn't on screen and the band content itself shifts
        // only subtly when the flow changes.
        if glasses.flow == .continuous {
            parts.append("strip")
        }
        if glasses.isAutoScrolling {
            parts.append("auto")
        }
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
                Button {
                    glasses.toggleAutoScroll()
                } label: {
                    Image(systemName: glasses.isAutoScrolling ? "pause.fill" : "play.fill")
                }
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
                if isAtLastBand {
                    Button("Next volume", action: onNextBook)
                        .accessibilityIdentifier(AID.glassesNextBook)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
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
        case .dimDecrease, .dimIncrease, .toggleAutoScroll,
             .autoScrollSlower, .autoScrollFaster, .toggleFlow:
            handleControl(key)
        }
    }

    private func handleControl(_ key: GlassesKey) {
        switch key {
        case .dimDecrease: glasses.adjustDim(by: -0.1)
        case .dimIncrease: glasses.adjustDim(by: 0.1)
        case .toggleAutoScroll: glasses.toggleAutoScroll()
        case .autoScrollSlower: glasses.adjustAutoScrollSpeed(by: -0.25)
        case .autoScrollFaster: glasses.adjustAutoScrollSpeed(by: 0.25)
        case .toggleFlow: glasses.toggleFlow()
        case .advanceBand, .retreatBand, .nextPage, .previousPage, .exit, .nextBook:
            break
        }
    }
}
