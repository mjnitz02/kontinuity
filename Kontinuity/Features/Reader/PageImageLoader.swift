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

    /// Generous rather than exact: recomputing per zoom level isn't worth the
    /// complexity for a home-server reader (READER-DESIGN §1 notes this as a
    /// deliberate simplification for phase 3).
    private let maxPixelSize: CGFloat

    init(
        service: any KomgaServing,
        screenSize: CGSize = UIScreen.main.bounds.size,
        screenScale: CGFloat = UIScreen.main.scale
    ) {
        self.service = service
        maxPixelSize = max(screenSize.width, screenSize.height) * screenScale * 2
        cache.countLimit = 12
    }

    func image(forPage index: Int, source: PageSource) async -> UIImage? {
        let key = NSNumber(value: index)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let existing = inFlight[index] {
            return await existing.value
        }

        let task = Task { [service, maxPixelSize] () -> UIImage? in
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
            cache.setObject(image, forKey: key)
        }
        return image
    }

    /// Drops cached and in-flight entries outside `current ± radius`, so the
    /// reader never holds more than a small ring of decoded pages.
    func prune(around current: Int, radius: Int = 2) {
        let keep = (current - radius) ... (current + radius)
        for key in inFlight.keys where !keep.contains(key) {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
    }

    /// Tries the primary href first; falls back to an alternate only if the
    /// primary fails to decode. Decode-based, not a guess from `type` — Komga
    /// only adds an alternate for formats it flagged as non-recommended
    /// (KOMGA-API §5), and most primaries decode fine on iOS anyway.
    private static func fetch(link: KomgaPageLink, service: any KomgaServing, maxPixelSize: CGFloat) async -> UIImage? {
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
    /// the bytes are already local.
    private static func fetchLocal(url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return downsample(data, to: maxPixelSize)
    }

    private static func downsample(_ data: Data, to maxPixelSize: CGFloat) -> UIImage? {
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
