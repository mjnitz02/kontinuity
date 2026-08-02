//
//  ReaderPageView.swift
//  Kontinuity
//
//  Renders one `PageSpread`. A two-page spread is composed into a single image
//  before reaching `ZoomableImageView`, so pinch-zoom treats the pair as one
//  unit rather than needing two scroll views kept in sync.
//

import KontinuityCore
import SwiftUI
import UIKit

struct ReaderPageView: View {
    let spread: PageSpread
    let readingOrder: [KomgaPageLink]
    let loader: PageImageLoader
    let onTapZone: (ZoomableImageView.TapZone) -> Void

    @State private var composedImage: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let composedImage {
                ZoomableImageView(image: composedImage, onTapZone: onTapZone)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: spread) {
            composedImage = nil
            composedImage = await loadImage()
        }
    }

    private func loadImage() async -> UIImage? {
        var images: [UIImage] = []
        for index in spread.pageIndices where readingOrder.indices.contains(index) {
            if let image = await loader.image(forPage: index, link: readingOrder[index]) {
                images.append(image)
            }
        }
        return images.count > 1 ? .sideBySide(images) : images.first
    }
}

private extension UIImage {
    /// Draws the given images left-to-right onto one canvas, each scaled to a
    /// shared height. `spread.pageIndices` already encodes the visual
    /// left-to-right order (``PageLayout`` reverses it for RTL), so this just
    /// draws in the order given.
    static func sideBySide(_ images: [UIImage]) -> UIImage? {
        let height = images.map(\.size.height).max() ?? 0
        guard height > 0 else { return nil }

        let scaledSizes = images.map { image -> CGSize in
            let scale = height / image.size.height
            return CGSize(width: image.size.width * scale, height: height)
        }
        let canvasSize = CGSize(width: scaledSizes.reduce(0) { $0 + $1.width }, height: height)

        return UIGraphicsImageRenderer(size: canvasSize).image { _ in
            var x: CGFloat = 0
            for (image, size) in zip(images, scaledSizes) {
                image.draw(in: CGRect(origin: CGPoint(x: x, y: 0), size: size))
                x += size.width
            }
        }
    }
}
