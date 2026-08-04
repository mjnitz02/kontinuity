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
    /// against the screen's *long* side, so a whole-page-fit page still lands
    /// comfortably above panel resolution with headroom for Mode A's
    /// pinch-zoom — the 2x this used to carry meant a 4776px ceiling on an
    /// 11" iPad, i.e. no downsampling at all for a typical manga scan, ~60MB
    /// decoded per page.
    private let maxPixelSize: CGFloat

    /// The widest any renderer will draw a page at — the panel's long side in
    /// pixels, which is the container width whenever Mode B is on screen. A
    /// long-side budget alone is *wrong* for a tall page, and silently so:
    /// `kCGImageSourceThumbnailMaxPixelSize` constrains the longest edge, so a
    /// 900x5000 web comic slice against an 11" iPad's 3025px budget decodes to
    /// 544x3025 and is then drawn 2420px wide — a 4.4x upscale of an image
    /// that was 900px wide to start with. Every paged manga page is under the
    /// ceiling, so this never fired until the library gained long strips
    /// (PLAN §12).
    private let targetWidthPixels: CGFloat

    /// `nil` defaults rather than `UIScreen.main` in the signature: a default
    /// argument expression runs in a nonisolated context regardless of the
    /// initializer's own isolation, so a `@MainActor`-isolated screen lookup
    /// can only happen in the body below. It also sidesteps `UIScreen.main`
    /// itself, deprecated in iOS 26 in favour of a scene-scoped screen.
    init(
        service: any KomgaServing,
        screenSize: CGSize? = nil,
        screenScale: CGFloat? = nil
    ) {
        self.service = service
        let screen = Self.currentScreen()
        let resolvedSize = screenSize ?? screen?.bounds.size ?? CGSize(width: 1024, height: 1366)
        let resolvedScale = screenScale ?? screen?.scale ?? 2
        let longSide = max(resolvedSize.width, resolvedSize.height) * resolvedScale
        maxPixelSize = longSide * 1.25
        targetWidthPixels = longSide
        cache.countLimit = 8
        // Belt and braces with `countLimit`: a page ring that's small by count
        // can still be huge by bytes, and it was memory pressure — NSCache
        // purging a page mid-read, forcing a re-decode on the next band step —
        // that made glasses mode stutter partway through a page.
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    /// The connected window scene's own screen, in place of the deprecated
    /// `UIScreen.main` — there's no view context to read one through here
    /// (`ReaderView` constructs this before any geometry is known), so this
    /// is the app-wide equivalent Apple's deprecation note points at.
    private static func currentScreen() -> UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
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
        let budget = DecodeBudget(maxPixelSize: maxPixelSize, targetWidthPixels: targetWidthPixels)
        let task = Task.detached(priority: .userInitiated) { [service] () -> UIImage? in
            switch source {
            case let .remote(link):
                await Self.fetch(link: link, service: service, budget: budget)
            case let .local(url, _):
                await Self.fetchLocal(url: url, budget: budget)
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
        budget: DecodeBudget
    ) async -> UIImage? {
        let hrefs = [link.href] + link.alternate.map(\.href)
        for href in hrefs {
            guard let data = try? await service.pageImageData(at: href) else { continue }
            if let image = downsample(data, budget: budget) {
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
    private nonisolated static func fetchLocal(url: URL, budget: DecodeBudget) async -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return downsample(data, budget: budget)
    }

    private nonisolated static func downsample(_ data: Data, budget: DecodeBudget) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: budget.thumbnailMaxPixelSize(for: source),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Turns "how big will this be drawn" into the single long-edge number
/// `kCGImageSourceThumbnailMaxPixelSize` accepts. `nonisolated` and file scope
/// rather than nested inside `PageImageLoader`, because the detached decode
/// task has to both carry this across *and* call into it — nesting would
/// inherit that type's `@MainActor`, and this project's default actor
/// isolation would apply the same to a bare file-scope type.
private nonisolated struct DecodeBudget: Sendable {
    /// A ceiling on decoded pixels per page, so a pathological strip (a whole
    /// chapter as one 1200x30000 image) degrades in sharpness instead of
    /// allocating 144MB inside a cache budgeted for 192MB in total.
    static let maxDecodedPixels: CGFloat = 16_000_000

    let maxPixelSize: CGFloat
    let targetWidthPixels: CGFloat

    /// Reads the header only — `CGImageSourceCopyPropertiesAtIndex` doesn't
    /// decode pixels — so knowing the page's true shape before choosing a size
    /// costs essentially nothing.
    func thumbnailMaxPixelSize(for source: CGImageSource) -> CGFloat {
        guard let size = Self.pixelSize(of: source), size.width > 0, size.height > 0 else {
            return maxPixelSize
        }
        let longSide = max(size.width, size.height)
        // The long edge that lands the *width* on target. For a page wider
        // than it is tall this comes out below the plain long-side budget,
        // which is why the two are combined rather than swapped.
        let widthFitLongSide = targetWidthPixels * longSide / size.width
        let pixelCapLongSide = (Self.maxDecodedPixels * longSide / min(size.width, size.height)).squareRoot()
        // Never ask for more than the source has: a thumbnail request above
        // native size buys nothing and risks an upscale.
        return min(max(maxPixelSize, min(widthFitLongSide, pixelCapLongSide)), longSide)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        // `kCGImageSourceCreateThumbnailWithTransform` applies EXIF
        // orientation, so a sideways-tagged source comes back with its axes
        // swapped relative to these raw values — swap them here too, or the
        // width fit is computed against the wrong edge.
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return (5 ... 8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
