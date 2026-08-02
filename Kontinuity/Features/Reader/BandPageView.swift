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

import KontinuityCore
import SwiftUI

struct BandPageView: View {
    let band: Band
    let pageSources: [PageSource]
    let loader: PageImageLoader

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image {
                    let scaledHeight = proxy.size.width * (image.size.height / image.size.width)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: proxy.size.width, height: scaledHeight)
                        .offset(y: -band.rect.y * scaledHeight)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .clipped()
                } else {
                    ProgressView().tint(.white)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .task(id: band) { await loadImage() }
    }

    private func loadImage() async {
        guard pageSources.indices.contains(band.pageIndex) else { return }
        image = await loader.image(forPage: band.pageIndex, source: pageSources[band.pageIndex])
    }
}
