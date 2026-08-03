//
//  PageImageLoaderTests.swift
//  KontinuityTests
//
//  The reader's decode budget (READER-DESIGN §1: "never hold a whole book
//  decoded"). `prune(around:)` was documented as dropping cached *and*
//  in-flight entries but only ever cancelled the in-flight ones — leaving
//  `NSCache` to decide on its own when to purge, which it did under memory
//  pressure, sometimes evicting the page being read and forcing a re-decode
//  mid-page. These pin the ring behaviour so that can't silently return.
//
//  Nothing here can assert "the decode ran off the main thread" directly —
//  that's a property of `Task.detached` plus `nonisolated` in
//  `PageImageLoader`, not something the caller can observe. What it *can*
//  assert is that the cache the fix depends on actually holds and releases
//  what it claims to.
//

import CoreGraphics
import Foundation
import Testing
@testable import Kontinuity
@testable import KontinuityCore

@MainActor
@Suite("PageImageLoader")
struct PageImageLoaderTests {
    private func makeLoader() -> PageImageLoader {
        // A small screen keeps `maxPixelSize` — and so the decoded fixtures —
        // tiny; this suite is about cache bookkeeping, not image quality.
        PageImageLoader(
            service: StubKomgaService(),
            screenSize: CGSize(width: 100, height: 100),
            screenScale: 1
        )
    }

    /// The stub's fixture pages are addressed by href, and any href decodes —
    /// page index is the loader's own key, independent of the source.
    private func source(forPage index: Int) -> PageSource {
        .remote(KomgaPageLink(href: "/pages/\(index + 1)", type: "image/jpeg", width: 800, height: 1200))
    }

    @Test("a fetched page becomes synchronously available, which is what lets a band render without a spinner")
    func fetchedPageIsCachedSynchronously() async {
        let loader = makeLoader()
        #expect(loader.cachedImage(forPage: 0) == nil)

        let image = await loader.image(forPage: 0, source: source(forPage: 0))
        #expect(image != nil)
        #expect(loader.cachedImage(forPage: 0) != nil)
    }

    @Test("prune drops cached pages outside the ring and keeps the ones inside it")
    func pruneEvictsOutsideTheRing() async {
        let loader = makeLoader()
        for index in 0 ... 5 {
            _ = await loader.image(forPage: index, source: source(forPage: index))
        }
        #expect(loader.cachedImage(forPage: 0) != nil)

        loader.prune(around: 4, radius: 2)

        // Ring is 2...6: everything below 2 goes, everything from 2 up stays.
        #expect(loader.cachedImage(forPage: 0) == nil)
        #expect(loader.cachedImage(forPage: 1) == nil)
        #expect(loader.cachedImage(forPage: 2) != nil)
        #expect(loader.cachedImage(forPage: 4) != nil)
        #expect(loader.cachedImage(forPage: 5) != nil)
    }

    @Test("a page pruned and re-fetched is cached again — eviction doesn't poison the index bookkeeping")
    func evictedPageCanBeFetchedAgain() async {
        let loader = makeLoader()
        _ = await loader.image(forPage: 0, source: source(forPage: 0))
        loader.prune(around: 10)
        #expect(loader.cachedImage(forPage: 0) == nil)

        _ = await loader.image(forPage: 0, source: source(forPage: 0))
        #expect(loader.cachedImage(forPage: 0) != nil)
    }

    @Test("prefetch warms a page the reader hasn't reached, so a page boundary lands on a decoded image")
    func prefetchWarmsTheCache() async {
        let loader = makeLoader()
        loader.prefetch(page: 3, source: source(forPage: 3))

        // The prefetch is fire-and-forget; awaiting the same page joins the
        // in-flight task rather than starting a second decode.
        _ = await loader.image(forPage: 3, source: source(forPage: 3))
        #expect(loader.cachedImage(forPage: 3) != nil)
    }
}
