//
//  ThumbnailLoader.swift
//  Kontinuity
//
//  Covers can't go through `AsyncImage`: Komga authenticates posters with the
//  `X-API-Key` header and there is no query-parameter form, so every fetch has
//  to carry a header `AsyncImage` gives no way to set.
//
//  Two caches, doing different jobs. `URLCache` (on the session) holds the
//  bytes and does the conditional revalidation Komga already supports — every
//  poster response carries an ETag and `max-age=0, must-revalidate`, so a
//  revisit costs a 304 rather than a re-download. `NSCache` holds the decoded
//  images, which is what actually keeps a grid scrolling.
//

import KontinuityCore
import SwiftUI

@MainActor
@Observable
final class ThumbnailLoader {
    private let service: any KomgaServing
    private let cache = NSCache<NSString, UIImage>()
    /// One task per target, so a cell that scrolls off and back doesn't start a
    /// second fetch, and two cells showing the same poster share one.
    private var inFlight: [KomgaThumbnail: Task<UIImage?, Never>] = [:]

    init(service: any KomgaServing, decodedImageLimit: Int = 400) {
        self.service = service
        cache.countLimit = decodedImageLimit
    }

    func image(for target: KomgaThumbnail) async -> UIImage? {
        let key = target.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let existing = inFlight[target] {
            return await existing.value
        }

        let task = Task { [service] () -> UIImage? in
            guard let data = try? await service.thumbnailData(for: target),
                  let image = UIImage(data: data)
            else {
                return nil
            }
            // `UIImage(data:)` defers decoding until first draw, which lands on
            // the main thread mid-scroll. `byPreparingForDisplay` moves that
            // work off it up front.
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[target] = task

        let image = await task.value
        inFlight[target] = nil
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    /// Drops decoded images so a refresh picks up a poster the server has
    /// regenerated. The `URLCache` layer still revalidates rather than
    /// re-downloading, so this is cheap.
    func invalidate() {
        cache.removeAllObjects()
    }
}
