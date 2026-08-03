//
//  PageImageLoader.swift
//  Kontinuity
//
//  Same shape as ThumbnailLoader (Kontinuity/Shared/ThumbnailLoader.swift), but
//  keyed by page index rather than a thumbnail target, and downsampled to
//  reader-sized pixels rather than grid-cell-sized ones.
//
//  READER-DESIGN §1's decode budget: never hold a whole book decoded. Only the
//  page ring around the current position is kept; ``prune(around:)`` drops the
//  rest as the reader turns pages.
//

import ImageIO
import KontinuityCore
import UIKit

@MainActor
@Observable
final class PageImageLoader {
    private let service: any KomgaServing
    private let cache = NSCache<NSNumber, UIImage>()
    private var inFlight: [Int: Task<UIImage?, Never>] = [:]

    /// `NSCache` can't be enumerated, so `prune(around:)` has no way to drop
    /// the entries it's documented to drop without a key list of its own.
    /// Entries `NSCache` evicted on its own linger here harmlessly —
    /// `removeObject` on an absent key is a no-op.
    private var cachedIndices: Set<Int> = []

    /// Generous rather than exact: recomputing per zoom level isn't worth the
    /// complexity for a home-server reader (READER-DESIGN §1 notes this as a
    /// deliberate simplification for phase 3). The 1.25 factor is measured
    /// against the screen's *long* side, so a width-fit portrait page still
    /// lands comfortably above panel resolution with headroom for Mode A's
    /// pinch-zoom — the 2x this used to carry meant a 4776px ceiling on an
    /// 11" iPad, i.e. no downsampling at all for a typical manga scan, ~60MB
    /// decoded per page.
    private let maxPixelSize: CGFloat

    init(
        service: any KomgaServing,
        screenSize: CGSize = UIScreen.main.bounds.size,
        screenScale: CGFloat = UIScreen.main.scale
    ) {
        self.service = service
        maxPixelSize = max(screenSize.width, screenSize.height) * screenScale * 1.25
        cache.countLimit = 8
        // Belt and braces with `countLimit`: a page ring that's small by count
        // can still be huge by bytes, and it was memory pressure — NSCache
        // purging a page mid-read, forcing a re-decode on the next band step —
        // that made glasses mode stutter partway through a page.
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    /// The synchronous cache hit, for callers that would rather render a page
    /// this frame than show a spinner for one frame while an `await` on
    /// `image(forPage:source:)` round-trips (`BandPageView`).
    func cachedImage(forPage index: Int) -> UIImage? {
        cache.object(forKey: NSNumber(value: index))
    }

    func image(forPage index: Int, source: PageSource) async -> UIImage? {
        let key = NSNumber(value: index)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let existing = inFlight[index] {
            return await existing.value
        }

        // `Task.detached`, not `Task` — this type is `@MainActor`, so a plain
        // `Task` would inherit main-actor isolation and run the decode below
        // *on the main thread*, and `SWIFT_APPROACHABLE_CONCURRENCY` (i.e.
        // `NonisolatedNonsendingByDefault`) means marking the helpers
        // `nonisolated` wouldn't move them off it either — a nonisolated async
        // function now runs on its caller's executor. Detached is the one
        // spelling that means "not on this actor" under every language mode.
        // Downsampling a full-resolution page blocks the main thread for
        // hundreds of milliseconds, which is what queued up keypresses in
        // glasses mode and then flushed them in a burst.
        let task = Task.detached(priority: .userInitiated) { [service, maxPixelSize] () -> UIImage? in
            switch source {
            case let .remote(link):
                await Self.fetch(link: link, service: service, maxPixelSize: maxPixelSize)
            case let .local(url, _):
                await Self.fetchLocal(url: url, maxPixelSize: maxPixelSize)
            }
        }
        inFlight[index] = task

        let image = await task.value
        inFlight[index] = nil
        if let image {
            cache.setObject(image, forKey: key, cost: Self.byteCost(of: image))
            cachedIndices.insert(index)
        }
        return image
    }

    /// Fire-and-forget warming for a page the reader is about to reach, so a
    /// page boundary doesn't wait on a decode that could have happened while
    /// the previous page was still being read (READER-DESIGN §3's page
    /// transition). Dedupes through `image(forPage:source:)`'s own `inFlight`
    /// map, so calling it repeatedly costs nothing.
    func prefetch(page index: Int, source: PageSource) {
        guard cache.object(forKey: NSNumber(value: index)) == nil, inFlight[index] == nil else { return }
        Task { _ = await image(forPage: index, source: source) }
    }

    /// Drops cached and in-flight entries outside `current ± radius`, so the
    /// reader never holds more than a small ring of decoded pages.
    func prune(around current: Int, radius: Int = 2) {
        let keep = (current - radius) ... (current + radius)
        for key in inFlight.keys where !keep.contains(key) {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        for index in cachedIndices where !keep.contains(index) {
            cache.removeObject(forKey: NSNumber(value: index))
        }
        cachedIndices.formIntersection(keep)
    }

    /// Decoded bytes, not file bytes — what `totalCostLimit` is budgeting.
    private static func byteCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Tries the primary href first; falls back to an alternate only if the
    /// primary fails to decode. Decode-based, not a guess from `type` — Komga
    /// only adds an alternate for formats it flagged as non-recommended
    /// (KOMGA-API §5), and most primaries decode fine on iOS anyway.
    private nonisolated static func fetch(
        link: KomgaPageLink,
        service: any KomgaServing,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        let hrefs = [link.href] + link.alternate.map(\.href)
        for href in hrefs {
            guard let data = try? await service.pageImageData(at: href) else { continue }
            if let image = downsample(data, to: maxPixelSize) {
                return image
            }
        }
        return nil
    }

    /// Off the main thread, same as the network path — decoding and
    /// downsampling a full-resolution manga page is not free just because
    /// the bytes are already local. `nonisolated` is what makes that true:
    /// without it these inherit the type's `@MainActor` and the detached task
    /// above would hop straight back onto the main thread to run them.
    private nonisolated static func fetchLocal(url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return downsample(data, to: maxPixelSize)
    }

    private nonisolated static func downsample(_ data: Data, to maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
