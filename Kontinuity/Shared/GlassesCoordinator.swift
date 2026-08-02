//
//  GlassesCoordinator.swift
//  Kontinuity
//
//  Mode B's impure half (READER-DESIGN §3, PLAN phase 6) — mirrors the
//  ProgressionSync/ProgressionSyncEngine and DownloadRetention/
//  DownloadCoordinator split: `BandLayout` in KontinuityCore holds the pure
//  math, this owns the session-scoped state (which band is showing, whether
//  an external display is connected, the keyboard-driven knobs) plus the
//  `UIScreen` connect/disconnect bridge.
//
//  Owned by `KomgaSession` alongside `sync`/`downloads` rather than by
//  `ReaderView`, because the external-display connection can outlive any one
//  reader screen the same way `DownloadCoordinator` outlives one book.
//
//  The one thing this design has to get right: the external glasses window
//  can never be key — `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
//  means no touch, no keyboard focus, nothing interactive lands there. So
//  this is one `@Observable` view model driving two independent render
//  targets. The iPad's own (real, key) window owns all keyboard/touch
//  handling and mutates this instance directly. The external
//  `UIHostingController` (built by `GlassesSceneDelegate`, which has no
//  reach into `KomgaSession`'s environment tree) only ever *observes* it,
//  via `AppDelegate`'s static handoff — the same shape
//  `backgroundCompletionHandler` already uses for the download session.
//

import Foundation
import KontinuityCore
import Observation
import UIKit

@MainActor
@Observable
final class GlassesCoordinator {
    private let settings: GlassesSettings

    private(set) var bands: [Band] = []
    var currentBandIndex = 0
    private(set) var isActive = false

    /// The single source of truth both render targets read from — the
    /// iPad's own `GlassesReaderView` in the fallback case, and
    /// `GlassesExternalView` (built by `GlassesSceneDelegate`, which has no
    /// other path to a `ReaderModel`) when a real external display is
    /// connected. Set once by `enter()`; glasses mode always reuses whatever
    /// the open `ReaderModel` already loaded rather than re-fetching.
    private(set) var pageSources: [PageSource] = []
    private(set) var loader: PageImageLoader?

    /// Whether a real external `UIScreen` is currently connected — bridged
    /// from `UIScreen.didConnectNotification`/`didDisconnectNotification`
    /// below. Independent of `isActive`: the reader decides, once glasses
    /// mode is active, whether to route content to the external scene or
    /// render the READER-DESIGN §3 iPad-fallback path in place.
    private(set) var isExternalDisplayConnected: Bool

    /// Off by default, and re-armed to `false` every `enter()` — "a blanket
    /// resting on a capacitive screen will page through the entire volume"
    /// (READER-DESIGN §3) is what this guards against.
    private(set) var touchArmed = false

    var dimLevel: Double {
        didSet { settings.dimLevel = dimLevel }
    }

    var autoScrollSpeed: Double {
        didSet { settings.autoScrollSpeed = autoScrollSpeed }
    }

    private(set) var isAutoScrolling = false
    private var autoScrollTask: Task<Void, Never>?

    /// "A single dim status line appears only while a key is being pressed"
    /// (READER-DESIGN §3) — a real fade, not just a snapshot check against
    /// `lastKeyPressDate` at render time, which would never hide itself
    /// again once shown without some *other* state change forcing a
    /// re-render.
    private(set) var isStatusLineVisible = false
    private(set) var lastKeyPressDate: Date?
    private var statusLineTask: Task<Void, Never>?

    private let eventStream: AsyncStream<Bool>
    private let eventContinuation: AsyncStream<Bool>.Continuation
    /// Read only in `startScreenObserving()` and `deinit` — `deinit` can't be
    /// actor-isolated, so this can't be `@MainActor`-isolated storage either,
    /// same reasoning as `DownloadSettings.defaults`. `@ObservationIgnored`
    /// because plain `nonisolated` isn't allowed on a mutable property the
    /// `@Observable` macro instruments, and nothing renders off this anyway.
    @ObservationIgnored
    private nonisolated(unsafe) var screenObservers: [NSObjectProtocol] = []

    init(settings: GlassesSettings = GlassesSettings()) {
        self.settings = settings
        dimLevel = settings.dimLevel
        autoScrollSpeed = settings.autoScrollSpeed
        isExternalDisplayConnected = Self.hasExternalScreen()
        (eventStream, eventContinuation) = AsyncStream<Bool>.makeStream()
        startScreenObserving()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in screenObservers {
            center.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Computes `bands` for the already-loaded reader's page geometries
    /// against `screenWidth`/`screenHeight`, and stashes `pageSources`/
    /// `loader` so either render target can draw from this instance alone —
    /// glasses mode reuses whatever `ReaderModel` already fetched rather
    /// than re-fetching the manifest.
    func enter(
        pageSources: [PageSource],
        pageGeometries: [PageGeometry],
        loader: PageImageLoader,
        screenWidth: Double,
        screenHeight: Double
    ) {
        self.pageSources = pageSources
        self.loader = loader
        bands = BandLayout.bands(
            for: pageGeometries,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            overlap: settings.bandOverlap
        )
        currentBandIndex = 0
        touchArmed = false
        isActive = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func exit() {
        isActive = false
        isAutoScrolling = false
        autoScrollTask?.cancel()
        statusLineTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Navigation

    func advanceBand() {
        guard currentBandIndex + 1 < bands.count else { return }
        currentBandIndex += 1
        interrupt()
    }

    func retreatBand() {
        guard currentBandIndex > 0 else { return }
        currentBandIndex -= 1
        interrupt()
    }

    /// "Page Down: next page, skip remaining bands" (READER-DESIGN §3) — the
    /// first band of the next distinct page, wherever the traversal order
    /// (LTR/RTL) put it.
    func nextPage() {
        guard bands.indices.contains(currentBandIndex) else { return }
        let currentPage = bands[currentBandIndex].pageIndex
        guard let target = bands[currentBandIndex...].firstIndex(where: { $0.pageIndex != currentPage }) else {
            return
        }
        currentBandIndex = target
        interrupt()
    }

    /// "Page Up: previous page" — the first band of the page *before* the
    /// one currently showing, not just any earlier band on the current page.
    func previousPage() {
        guard bands.indices.contains(currentBandIndex) else { return }
        let start = startIndex(ofBandAt: currentBandIndex)
        guard start > 0 else { return }
        currentBandIndex = startIndex(ofBandAt: start - 1)
        interrupt()
    }

    private func startIndex(ofBandAt index: Int) -> Int {
        let pageIndex = bands[index].pageIndex
        var start = index
        while start > 0, bands[start - 1].pageIndex == pageIndex {
            start -= 1
        }
        return start
    }

    // MARK: - Controls

    func toggleTouch() {
        touchArmed.toggle()
        interrupt()
    }

    func adjustDim(by delta: Double) {
        dimLevel = min(1, max(0, dimLevel + delta))
        interrupt()
    }

    /// A and -/= are auto-scroll's own controls, so — unlike every other key
    /// — they don't pause it via `interrupt()`; only `registerKeyPress()`
    /// for the status line.
    func toggleAutoScroll() {
        isAutoScrolling.toggle()
        registerKeyPress()
        if isAutoScrolling {
            startAutoScrollLoop()
        } else {
            autoScrollTask?.cancel()
        }
    }

    func adjustAutoScrollSpeed(by delta: Double) {
        autoScrollSpeed = min(5, max(0.25, autoScrollSpeed + delta))
        registerKeyPress()
        // Restart at the new interval immediately rather than waiting out
        // whatever's left of the old one.
        if isAutoScrolling {
            startAutoScrollLoop()
        }
    }

    /// "Slow continuous pan, speed adjustable" (READER-DESIGN §3) —
    /// approximated as a fixed-interval band advance, inversely proportional
    /// to speed, rather than true sub-band scrolling; simpler, and the
    /// bands' own ~8% overlap already keeps the step from reading as a jump.
    private func startAutoScrollLoop() {
        autoScrollTask?.cancel()
        let interval = 3.0 / autoScrollSpeed
        autoScrollTask = Task {
            while isAutoScrolling, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, isAutoScrolling else { return }
                autoAdvance()
            }
        }
    }

    /// Doesn't call `interrupt()` — a tick isn't a keypress and shouldn't
    /// pause itself — and stops cleanly at the last band rather than
    /// wrapping back to the start.
    private func autoAdvance() {
        guard currentBandIndex + 1 < bands.count else {
            isAutoScrolling = false
            autoScrollTask?.cancel()
            return
        }
        currentBandIndex += 1
    }

    private func registerKeyPress() {
        lastKeyPressDate = .now
        isStatusLineVisible = true
        statusLineTask?.cancel()
        statusLineTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            isStatusLineVisible = false
        }
    }

    /// Any keypress other than auto-scroll's own controls pauses it
    /// (READER-DESIGN §3: "any keypress pauses").
    private func interrupt() {
        registerKeyPress()
        if isAutoScrolling {
            isAutoScrolling = false
            autoScrollTask?.cancel()
        }
    }

    // MARK: - External display bridge

    /// Delegate methods on `UIScreen`'s notifications run on whatever thread
    /// posts them — only a `Bool` crosses into this stream; reacting to it
    /// happens back on `MainActor`. Same shape as `ProgressionSyncEngine`'s
    /// `NWPathMonitor` bridge and `DownloadCoordinator`'s
    /// `URLSessionDownloadDelegate` bridge.
    private func startScreenObserving() {
        let center = NotificationCenter.default
        let connect = center.addObserver(
            forName: UIScreen.didConnectNotification, object: nil, queue: nil
        ) { [eventContinuation] _ in
            eventContinuation.yield(true)
        }
        let disconnect = center.addObserver(
            forName: UIScreen.didDisconnectNotification, object: nil, queue: nil
        ) { [eventContinuation] _ in
            eventContinuation.yield(Self.hasExternalScreen())
        }
        screenObservers = [connect, disconnect]

        Task { @MainActor [eventStream] in
            for await connected in eventStream {
                isExternalDisplayConnected = connected
            }
        }
    }

    private static func hasExternalScreen() -> Bool {
        UIScreen.screens.count > 1
    }
}
