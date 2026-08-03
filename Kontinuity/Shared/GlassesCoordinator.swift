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
    /// `didSet` rather than a setter method so every path that moves the
    /// reader — the nav methods below, auto-scroll's tick, `enter()`,
    /// `updateGeometry` — warms and trims the image cache identically.
    var currentBandIndex = 0 {
        didSet { prepareImagesForCurrentPage() }
    }

    private(set) var isActive = false

    /// The single source of truth both render targets read from — the
    /// iPad's own `GlassesReaderView` in the fallback case, and
    /// `GlassesExternalView` (built by `GlassesSceneDelegate`, which has no
    /// other path to a `ReaderModel`) when a real external display is
    /// connected. Set once by `enter()`; glasses mode always reuses whatever
    /// the open `ReaderModel` already loaded rather than re-fetching.
    private(set) var pageSources: [PageSource] = []
    private(set) var loader: PageImageLoader?

    /// Retained so `updateGeometry(width:height:)` can recompute `bands`
    /// against a new size without the caller re-supplying the manifest.
    private var pageGeometries: [PageGeometry] = []

    /// "Are glasses attached?" (READER-DESIGN §3's two-signals table) —
    /// bridged from `UIScreen.didConnectNotification`/
    /// `didDisconnectNotification` below. A fine trigger for offering or
    /// auto-entering the mode; **not** what gates the panel blackout —
    /// mirroring makes this true while `isExternalSceneConnected` stays
    /// false, which is exactly the case a screen count alone can't
    /// distinguish.
    private(set) var isGlassesAttached: Bool

    /// "Do I have a second surface to draw on?" — set by
    /// `GlassesSceneDelegate.scene(_:willConnectTo:)` and cleared in
    /// `sceneDidDisconnect`, via `AppDelegate`'s static handoff. This is the
    /// only signal that means "there is a real, independent
    /// `…RoleExternalDisplayNonInteractive` scene" — under mirroring the
    /// panel *is* the thing the glasses show, so only this flag may black it
    /// out (READER-DESIGN §3).
    private(set) var isExternalSceneConnected = false

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

    /// No default: a default argument expression runs in a nonisolated
    /// context regardless of this initializer's own isolation, so
    /// `GlassesSettings()` — main-actor-isolated under this project's default
    /// actor isolation — can't be constructed as one. The one real call site
    /// threads its own instance.
    init(settings: GlassesSettings) {
        self.settings = settings
        dimLevel = settings.dimLevel
        autoScrollSpeed = settings.autoScrollSpeed
        isGlassesAttached = Self.hasExternalScreen()
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
    ///
    /// Enters at the first band of `startingPageIndex` — Mode A's currently
    /// open page — rather than always band 0 of the book (gap 2, PLAN 6B
    /// §C): entering glasses mode, or auto-rotating into it on iPhone, must
    /// not throw the reader back to page 1.
    func enter(
        pageSources: [PageSource],
        pageGeometries: [PageGeometry],
        loader: PageImageLoader,
        startingPageIndex: Int,
        screenSize: CGSize
    ) {
        self.pageSources = pageSources
        self.pageGeometries = pageGeometries
        self.loader = loader
        bands = BandLayout.bands(
            for: pageGeometries,
            screenWidth: screenSize.width,
            screenHeight: screenSize.height,
            overlap: settings.bandOverlap
        )
        // Cleared before the assignment below so `prepareImagesForCurrentPage`
        // doesn't mistake a new book's page 0 for the outgoing book's.
        lastPreparedPageIndex = nil
        currentBandIndex = firstBandIndex(forPage: startingPageIndex)
        isActive = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Recomputes `bands` for a new size — a rotation while Mode B is active
    /// (gap 3, PLAN 6B §C) — preserving position as **(page index, fraction
    /// through that page's bands)** rather than a raw band index, since the
    /// band count per page changes with the geometry and a raw index would
    /// drift (READER-DESIGN §3's iPhone section).
    func updateGeometry(width: Double, height: Double) {
        guard isActive, !bands.isEmpty else { return }
        let position = currentPosition()
        bands = BandLayout.bands(
            for: pageGeometries,
            screenWidth: width,
            screenHeight: height,
            overlap: settings.bandOverlap
        )
        currentBandIndex = bandIndex(forPage: position.pageIndex, fraction: position.fraction)
    }

    func exit() {
        isActive = false
        isAutoScrolling = false
        autoScrollTask?.cancel()
        statusLineTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The page the current band belongs to — what Mode A resumes at when
    /// leaving Mode B (`ReaderModel.recordGlassesPageRead`'s counterpart for
    /// navigation rather than sync; the iPhone rotation round-trip reads
    /// this).
    var currentPageIndex: Int {
        bands.indices.contains(currentBandIndex) ? bands[currentBandIndex].pageIndex : 0
    }

    private func firstBandIndex(forPage pageIndex: Int) -> Int {
        bands.firstIndex { $0.pageIndex == pageIndex } ?? 0
    }

    /// `(pageIndex, fraction)` where `fraction` is this band's position
    /// among its page's own bands, 0 at the first and 1 at the last — the
    /// geometry-independent coordinate `updateGeometry` preserves across a
    /// recompute.
    private func currentPosition() -> (pageIndex: Int, fraction: Double) {
        guard bands.indices.contains(currentBandIndex) else { return (0, 0) }
        let pageIndex = bands[currentBandIndex].pageIndex
        let bandsForPage = bands.indices.filter { bands[$0].pageIndex == pageIndex }
        guard let start = bandsForPage.first, bandsForPage.count > 1 else { return (pageIndex, 0) }
        let fraction = Double(currentBandIndex - start) / Double(bandsForPage.count - 1)
        return (pageIndex, fraction)
    }

    private func bandIndex(forPage pageIndex: Int, fraction: Double) -> Int {
        let indices = bands.indices.filter { bands[$0].pageIndex == pageIndex }
        guard let start = indices.first else { return min(currentBandIndex, bands.count - 1) }
        guard indices.count > 1 else { return start }
        return start + Int((fraction * Double(indices.count - 1)).rounded())
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

    // MARK: - Page images

    /// The page `prepareImagesForCurrentPage` last warmed around, so stepping
    /// bands *within* a page — the common case by far — doesn't re-issue the
    /// same prefetch and prune on every keypress.
    private var lastPreparedPageIndex: Int?

    /// Mode A prunes on every spread change (`ReaderView`); Mode B had no
    /// equivalent, so a long volume read in glasses mode grew the decoded-page
    /// cache until `NSCache` started purging under pressure — including the
    /// page being read, which then re-decoded on the next band step. This is
    /// Mode B's counterpart, plus the prefetch that makes a page boundary land
    /// on an image that's already decoded.
    private func prepareImagesForCurrentPage() {
        guard let loader, bands.indices.contains(currentBandIndex) else { return }
        let pageIndex = bands[currentBandIndex].pageIndex
        guard pageIndex != lastPreparedPageIndex else { return }
        lastPreparedPageIndex = pageIndex

        // Prune first: it cancels in-flight work outside the ring, and the
        // neighbours prefetched below sit inside it.
        loader.prune(around: pageIndex)
        for neighbour in [pageIndex + 1, pageIndex - 1] where pageSources.indices.contains(neighbour) {
            loader.prefetch(page: neighbour, source: pageSources[neighbour])
        }
    }

    // MARK: - Controls

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
                isGlassesAttached = connected
            }
        }
    }

    private static func hasExternalScreen() -> Bool {
        UIScreen.screens.count > 1
    }

    /// Called by `GlassesSceneDelegate.scene(_:willConnectTo:)` via
    /// `AppDelegate`'s static handoff — the only signal that a real,
    /// independent external surface exists rather than a mirror of the iPad
    /// panel (gap 4, PLAN 6B §C).
    func externalSceneDidConnect() {
        isExternalSceneConnected = true
    }

    /// Called by `GlassesSceneDelegate.sceneDidDisconnect(_:)`.
    func externalSceneDidDisconnect() {
        isExternalSceneConnected = false
    }
}
