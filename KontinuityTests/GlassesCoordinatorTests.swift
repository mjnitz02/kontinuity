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
        screenWidth: Double,
        screenHeight: Double
    ) {
        coordinator.enter(
            pageSources: [],
            pageGeometries: pages,
            loader: PageImageLoader(service: StubKomgaService()),
            screenWidth: screenWidth,
            screenHeight: screenHeight
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

    @Test("touchArmed re-arms to false on every enter(), even if it was toggled on")
    func touchArmedResetsOnEveryEnter() {
        let coordinator = makeCoordinator()
        enter(coordinator, pages: [Self.portrait], screenWidth: 800, screenHeight: 1200)
        coordinator.toggleTouch()
        #expect(coordinator.touchArmed)

        enter(coordinator, pages: [Self.portrait], screenWidth: 800, screenHeight: 1200)
        #expect(!coordinator.touchArmed)
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
