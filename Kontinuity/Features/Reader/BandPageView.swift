//
//  BandPageView.swift
//  Kontinuity
//
//  Mode B (READER-DESIGN §3-4): renders one `Band` — a width-fit crop of the
//  page (or, under `BandFlow.continuous`, the *pages*) it covers. `BandRect`
//  is fractional page-space (0...1), and pages are width-fit by construction
//  (`BandLayout` normalises every page to width 1), so positioning is a plain
//  SwiftUI stack/offset/clip, not a pixel-level `CGImage` crop — no new
//  image-decoding path, just `PageImageLoader`'s existing cache plus geometry.
//  `widthFit` insets that fit within the container, pillarboxing the page: on
//  a viewport wider than 16:9 — an iPhone in landscape — a full-width fit
//  makes each band a sliver of the page, and two consecutive slivers barely
//  overlap.
//  It's passed in rather than recomputed here because `BandLayout` banded
//  against it; the two must be the same number.
//
//  Held images are keyed by the page they belong to, and only ever drawn for a
//  segment on that same page. That's what keeps a page boundary from flashing:
//  the band index changes before the next page's image exists, so an untagged
//  image would render the *previous* page at the new band's offset — i.e. snap
//  to the top of the page just finished, then snap again as the real image
//  landed. Going black in between is both the honest frame and the one that's
//  readable in glasses.
//
//  Page heights come from the manifest rather than the decoded image wherever
//  they're known, for two reasons: it's the same geometry `BandLayout` banded
//  against, so the two can't disagree, and it lets a not-yet-decoded page in a
//  boundary-straddling band reserve its space instead of collapsing the stack
//  and yanking the visible half out of position.
//

import KontinuityCore
import SwiftUI

struct BandPageView: View {
    let band: Band
    let pageSources: [PageSource]
    let pageGeometries: [PageGeometry]
    let loader: PageImageLoader
    /// The fraction of the container's width the page is fit to, pillarboxed
    /// either side — `BandLayout`'s `widthFit`, which must be the same number
    /// here or the band on screen wouldn't be the band that was computed.
    var widthFit: Double = 1

    @State private var loaded = LoadedPages()

    /// Identity comparison on the images, not `NSObject.isEqual` — the
    /// synthesised `==` would compare multi-megapixel `UIImage`s pixel by
    /// pixel every time SwiftUI checks whether to animate.
    private struct LoadedPages: Equatable {
        var images: [Int: UIImage] = [:]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.images.count == rhs.images.count
                && lhs.images.allSatisfy { pageIndex, image in rhs.images[pageIndex] === image }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if loaded.images[band.pageIndex] != nil {
                    let pageWidth = proxy.size.width * CGFloat(widthFit)
                    strip(width: pageWidth)
                        .offset(y: -band.rect.y * scaledHeight(ofPage: band.pageIndex, width: pageWidth))
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
        // Keyed on the *pages*, not the band: bands sharing a page share its
        // decoded image, so re-running this per band step was a cancel-and-
        // restart plus a cache round-trip on every single keypress.
        .task(id: band.pageIndices) { await loadImages() }
    }

    /// The band's pages stacked in reading order, each width-fit — one image
    /// for the ordinary case, two where a `.continuous` band straddles a slice
    /// boundary. A page still decoding holds its space in black rather than
    /// collapsing to zero height.
    private func strip(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(band.segments, id: \.pageIndex) { segment in
                Group {
                    if let image = loaded.images[segment.pageIndex] {
                        Image(uiImage: image).resizable()
                    } else {
                        Color.black
                    }
                }
                .frame(width: width, height: scaledHeight(ofPage: segment.pageIndex, width: width))
            }
        }
    }

    private func scaledHeight(ofPage pageIndex: Int, width: CGFloat) -> CGFloat {
        if pageGeometries.indices.contains(pageIndex) {
            let geometry = pageGeometries[pageIndex]
            if geometry.isKnown {
                return width * CGFloat(geometry.height / geometry.width)
            }
        }
        // Komga hadn't analysed this page, so the decoded image is the only
        // source of its aspect (READER-DESIGN §4's "degrade" case).
        guard let image = loaded.images[pageIndex], image.size.width > 0 else { return width }
        return width * image.size.height / image.size.width
    }

    private func loadImages() async {
        let pageIndices = band.pageIndices

        // Synchronously first, so a prefetched or still-cached page renders on
        // the very next frame rather than flashing the spinner for the one
        // frame an `await` costs even on a cache hit. Rebuilt rather than
        // merged, so images for pages the band has moved off are released and
        // `PageImageLoader.prune` isn't held hostage by this view's strong
        // references.
        var images: [Int: UIImage] = [:]
        for pageIndex in pageIndices where pageSources.indices.contains(pageIndex) {
            images[pageIndex] = loader.cachedImage(forPage: pageIndex)
        }
        loaded = LoadedPages(images: images)

        for pageIndex in pageIndices where images[pageIndex] == nil && pageSources.indices.contains(pageIndex) {
            let image = await loader.image(forPage: pageIndex, source: pageSources[pageIndex])
            guard !Task.isCancelled else { return }
            guard let image else { continue }
            images[pageIndex] = image
            loaded = LoadedPages(images: images)
        }
    }
}
