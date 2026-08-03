//
//  GlassesCoordinatorTests.swift
//  KontinuityTests
//
//  Mode B's impure half (PLAN phase 6) — unlike DownloadCoordinator/
//  ProgressionSyncEngine, this touches no SwiftData/ModelContext at all, so
//  it doesn't need the shared-in-memory-container nesting those two use;
//  each test gets its own `GlassesCoordinator` and an ephemeral UserDefaults
//  suite so runs never bleed into each other or the real `.standard` domain.
//

import CoreGraphics
import Foundation
import Testing
@testable import Kontinuity
@testable import KontinuityCore

@MainActor
@Suite("GlassesCoordinator")
struct GlassesCoordinatorTests {
    /// A typical portrait manga page — aspect ≈ 0.66, matching KOMGA-API §2's
    /// measurement against a real 67-page CBZ.
    private static let portrait = PageGeometry(width: 800, height: 1200)
    /// Tall enough that a 800x800 screen bands it into four (same ratio
    /// BandLayoutTests' "H = 3x visibleH" case pins).
    private static let tall = PageGeometry(width: 800, height: 2400)

    private func makeCoordinator() -> GlassesCoordinator {
        let defaults = UserDefaults(suiteName: "GlassesCoordinatorTests.\(UUID())")!
        return GlassesCoordinator(settings: GlassesSettings(defaults: defaults))
    }

    /// These tests only exercise the band-index/state math, not rendering —
    /// `pageSources`/`loader` are irrelevant to it, so this fills them with
    /// the minimum `enter()` now requires.
    private func enter(
        _ coordinator: GlassesCoordinator,
        pages: [PageGeometry],
        startingPageIndex: Int = 0,
        screenWidth: Double,
        screenHeight: Double
    ) {
        coordinator.enter(
            pageSources: [],
            pageGeometries: pages,
            loader: PageImageLoader(service: StubKomgaService()),
            startingPageIndex: startingPageIndex,
            screenSize: CGSize(width: screenWidth, height: screenHeight)
        )
    }

    @Test("advanceBand and retreatBand clamp at the ends rather than going out of range")
    func bandIndexClampsAtBounds() {
        let coordinator = makeCoordinator()
        enter(coordinator, pages: [Self.portrait], screenWidth: 800, screenHeight: 1200)
        #expect(coordinator.bands.count == 1)

        coordinator.retreatBand()
        #expect(coordinator.currentBandIndex == 0)

        coordinator.advanceBand()
        #expect(coordinator.currentBandIndex == 0)
    }

    @Test("nextPage jumps to the first band of the next page, previousPage to the first band of the one before")
    func pageJumpsLandOnFirstBandOfThePage() {
        let coordinator = makeCoordinator()
        enter(coordinator, pages: [Self.tall, Self.tall], screenWidth: 800, screenHeight: 800)
        #expect(coordinator.bands.count == 8) // 4 bands/page x 2 pages

        coordinator.advanceBand()
        coordinator.advanceBand()
        coordinator.advanceBand()
        #expect(coordinator.currentBandIndex == 3) // last band of page 0

        coordinator.nextPage()
        #expect(coordinator.currentBandIndex == 4) // first band of page 1

        coordinator.previousPage()
        #expect(coordinator.currentBandIndex == 0) // first band of page 0, not band 3
    }

    @Test("previousPage on the first page's bands is a true no-op, not a jump to the page's first band")
    func previousPageAtStartIsANoOp() {
        let coordinator = makeCoordinator()
        enter(coordinator, pages: [Self.tall], screenWidth: 800, screenHeight: 800)
        coordinator.advanceBand()
        coordinator.previousPage()
        #expect(coordinator.currentBandIndex == 1)
    }

    @Test("adjustDim clamps to 0...1")
    func dimLevelClamps() {
        let coordinator = makeCoordinator()
        coordinator.adjustDim(by: -1)
        #expect(coordinator.dimLevel == 0)

        coordinator.adjustDim(by: 2)
        #expect(coordinator.dimLevel == 1)
    }

    @Test("adjustAutoScrollSpeed clamps to 0.25...5")
    func autoScrollSpeedClamps() {
        let coordinator = makeCoordinator()
        coordinator.adjustAutoScrollSpeed(by: -10)
        #expect(coordinator.autoScrollSpeed == 0.25)

        coordinator.adjustAutoScrollSpeed(by: 10)
        #expect(coordinator.autoScrollSpeed == 5)
    }

    @Test("enter() starts at the given page's first band, not band 0 of the book")
    func enterStartsAtTheGivenPagesFirstBand() {
        let coordinator = makeCoordinator()
        enter(coordinator, pages: [Self.tall, Self.tall], startingPageIndex: 1, screenWidth: 800, screenHeight: 800)
        #expect(coordinator.currentBandIndex == 4) // first band of page 1 (4 bands/page)
        #expect(coordinator.currentPageIndex == 1)
    }

    @Test("updateGeometry recomputes bands and preserves position as (page, fraction), not a raw band index")
    func updateGeometryPreservesFractionalPosition() {
        let coordinator = makeCoordinator()
        // 800x800 screen -> 4 bands/page for `tall`. Land on the last band of
        // page 1 (fraction 1.0 through that page's bands).
        enter(coordinator, pages: [Self.tall, Self.tall], startingPageIndex: 1, screenWidth: 800, screenHeight: 800)
        coordinator.advanceBand()
        coordinator.advanceBand()
        coordinator.advanceBand()
        #expect(coordinator.currentPageIndex == 1)

        // A taller screen halves the band count per page (2 instead of 4).
        // A raw index (7) would land past the end; the fraction (1.0) must
        // still resolve to page 1's *last* band under the new geometry.
        coordinator.updateGeometry(width: 800, height: 1600)
        #expect(coordinator.currentPageIndex == 1)
        #expect(coordinator.currentBandIndex == coordinator.bands.count - 1)
    }

    @Test("updateGeometry before enter() is a no-op rather than crashing on empty bands")
    func updateGeometryBeforeEnterIsANoOp() {
        let coordinator = makeCoordinator()
        coordinator.updateGeometry(width: 800, height: 800)
        #expect(coordinator.bands.isEmpty)
    }

    @Test("isExternalSceneConnected starts false and only the dedicated hooks change it")
    func externalSceneConnectionIsASeparateSignalFromGlassesAttached() {
        let coordinator = makeCoordinator()
        #expect(!coordinator.isExternalSceneConnected)

        coordinator.externalSceneDidConnect()
        #expect(coordinator.isExternalSceneConnected)

        coordinator.externalSceneDidDisconnect()
        #expect(!coordinator.isExternalSceneConnected)
    }

    @Test("any navigation keypress pauses auto-scroll, but toggling/adjusting it does not self-interrupt")
    func navigationPausesAutoScrollButItsOwnControlsDont() {
        let coordinator = makeCoordinator()
        enter(coordinator, pages: [Self.tall], screenWidth: 800, screenHeight: 800)

        coordinator.toggleAutoScroll()
        #expect(coordinator.isAutoScrolling)

        // Adjusting speed is auto-scroll's own control — it shouldn't pause it.
        coordinator.adjustAutoScrollSpeed(by: 0.1)
        #expect(coordinator.isAutoScrolling)

        // A navigation key is not — it pauses.
        coordinator.advanceBand()
        #expect(!coordinator.isAutoScrolling)
    }
}
