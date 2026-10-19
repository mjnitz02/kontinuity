//
//  ZoomableImageViewTests.swift
//  KontinuityTests
//
//  The paging `TabView` reuses page views, so a `ZoomableImageView` that has
//  already fit one image routinely gets handed another of the same size — the
//  swipe-back case. The fit has to come out the same the second time as the
//  first, not just on a freshly made scroll view.
//

import Testing
import UIKit
@testable import Kontinuity

@MainActor
struct ZoomableImageViewTests {
    private let viewport = CGSize(width: 1194, height: 834)
    private let pageSize = CGSize(width: 2000, height: 3000)

    /// The second size is a page more than four times the viewport, whose fit
    /// leaves a maximum zoom scale below 1.
    @Test(
        "refitting a same-size image on a reused scroll view still fits it to the viewport",
        arguments: [CGSize(width: 2000, height: 3000), CGSize(width: 4000, height: 6000)]
    )
    func refitSameSizeImage(pageSize: CGSize) {
        let surface = Surface(viewport: viewport)

        surface.show(Self.image(pageSize))
        let firstFit = surface.imageView.frame.size

        surface.show(Self.image(pageSize))

        #expect(Self.approximatelyEqual(surface.imageView.frame.size, firstFit))
        #expect(Self.approximatelyEqual(surface.imageView.frame.size, fittedSize(pageSize)))
    }

    @Test("a second layout pass at the same size leaves a zoomed-in page alone")
    func layoutPassKeepsZoom() {
        let surface = Surface(viewport: viewport)
        surface.show(Self.image(pageSize))

        let zoomed = surface.scrollView.minimumZoomScale * 2
        surface.scrollView.zoomScale = zoomed
        surface.scrollView.setNeedsLayout()
        surface.scrollView.layoutIfNeeded()

        #expect(abs(surface.scrollView.zoomScale - zoomed) < 0.0001)
    }

    @Test("a viewport resize refits the page")
    func resizeRefits() {
        let surface = Surface(viewport: viewport)
        surface.show(Self.image(pageSize))
        surface.scrollView.zoomScale = surface.scrollView.minimumZoomScale * 2

        surface.scrollView.frame.size = CGSize(width: viewport.height, height: viewport.width)
        surface.scrollView.layoutIfNeeded()

        let portraitFit = min(viewport.height / pageSize.width, viewport.width / pageSize.height)
        #expect(abs(surface.scrollView.zoomScale - portraitFit) < 0.0001)
    }

    private func fittedSize(_ pageSize: CGSize) -> CGSize {
        let scale = min(viewport.width / pageSize.width, viewport.height / pageSize.height)
        return CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    }

    private static func image(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    /// The same wiring `ZoomableImageView.makeUIView` does, minus SwiftUI —
    /// `updateUIView`'s job reduces to assigning the image and refitting.
    private struct Surface {
        let scrollView: ZoomableImageView.FitZoomScrollView
        let imageView = UIImageView()
        let coordinator = ZoomableImageView.Coordinator()

        init(viewport: CGSize) {
            scrollView = ZoomableImageView.FitZoomScrollView(frame: CGRect(origin: .zero, size: viewport))
            scrollView.delegate = coordinator
            scrollView.addSubview(imageView)
            coordinator.scrollView = scrollView
            coordinator.imageView = imageView
            scrollView.onLayout = { [coordinator] in coordinator.boundsDidLayout() }
        }

        func show(_ image: UIImage) {
            imageView.image = image
            coordinator.fitToScreen()
        }
    }
}
