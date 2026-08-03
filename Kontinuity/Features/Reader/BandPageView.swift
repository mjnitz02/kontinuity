//
//  BandPageView.swift
//  Kontinuity
//
//  Mode B (READER-DESIGN §3-4): renders one `Band` — a width-fit crop of a
//  single already-decoded page image. `BandRect` is fractional page-space
//  (0...1), and the page is width-fit by construction (`BandLayout`'s own
//  scale = screenWidth/page.width), so positioning it is a plain SwiftUI
//  offset/frame/clip, not a pixel-level `CGImage` crop — no new
//  image-decoding path, just `PageImageLoader`'s existing cache plus geometry.
//
//  The held image is tagged with the page it belongs to, and only ever drawn
//  for a band on that same page. That's what keeps a page boundary from
//  flashing: the band index changes before the next page's image exists, so an
//  untagged image would render the *previous* page at the new band's offset —
//  i.e. snap to the top of the page just finished, then snap again as the real
//  image landed. Going black in between is both the honest frame and the one
//  that's readable in glasses.
//

import KontinuityCore
import SwiftUI

struct BandPageView: View {
    let band: Band
    let pageSources: [PageSource]
    let loader: PageImageLoader

    @State private var loaded: LoadedPage?

    /// Identity comparison on the image, not `NSObject.isEqual` — the
    /// synthesised `==` would compare two multi-megapixel `UIImage`s pixel
    /// by pixel every time SwiftUI checks whether to animate.
    private struct LoadedPage: Equatable {
        let pageIndex: Int
        let image: UIImage

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pageIndex == rhs.pageIndex && lhs.image === rhs.image
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let loaded, loaded.pageIndex == band.pageIndex {
                    let scaledHeight = proxy.size.width * (loaded.image.size.height / loaded.image.size.width)
                    Image(uiImage: loaded.image)
                        .resizable()
                        .frame(width: proxy.size.width, height: scaledHeight)
                        .offset(y: -band.rect.y * scaledHeight)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .clipped()
                } else {
                    ProgressView()
                        .tint(.white)
                        .accessibilityIdentifier(AID.glassesPageSpinner)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Only the black↔page swap animates; stepping bands within a page
            // stays instant, since `loaded` doesn't change for those.
            .animation(.easeOut(duration: 0.12), value: loaded)
        }
        // Keyed on the *page*, not the band: bands within a page share one
        // decoded image, so re-running this per band step was a cancel-and-
        // restart plus a cache round-trip on every single keypress.
        .task(id: band.pageIndex) { await loadImage() }
    }

    private func loadImage() async {
        let pageIndex = band.pageIndex
        guard pageSources.indices.contains(pageIndex) else { return }

        // Synchronously first, so a prefetched or still-cached page renders on
        // the very next frame rather than flashing the spinner for the one
        // frame an `await` costs even on a cache hit.
        if let cached = loader.cachedImage(forPage: pageIndex) {
            loaded = LoadedPage(pageIndex: pageIndex, image: cached)
            return
        }

        let image = await loader.image(forPage: pageIndex, source: pageSources[pageIndex])
        guard !Task.isCancelled, let image else { return }
        loaded = LoadedPage(pageIndex: pageIndex, image: image)
    }
}
