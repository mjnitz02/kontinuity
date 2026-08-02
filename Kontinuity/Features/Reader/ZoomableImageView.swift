//
//  ZoomableImageView.swift
//  Kontinuity
//
//  Pinch/pan/double-tap-to-toggle-fit-fill, the standard UIScrollView pattern —
//  and, deliberately, every page-level gesture in one place. A SwiftUI overlay
//  for the left/right/centre tap zones would sit on top of this view and
//  intercept every touch, breaking the scroll view's own pinch and pan
//  underneath it. Owning the taps here, gated behind the double-tap recognizer
//  via `require(toFail:)`, avoids that entirely (READER-DESIGN §2).
//

import KontinuityCore
import SwiftUI
import UIKit

struct ZoomableImageView: UIViewRepresentable {
    enum TapZone {
        case previous, next, toggleChrome
    }

    let image: UIImage?
    let onTapZone: (TapZone) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        // A plain `UIScrollView` never notices its own bounds changing (first
        // layout pass, or a rotation) — subclassing to hook `layoutSubviews`
        // is what lets the fit-to-screen scale get (re)computed as soon as the
        // real size is known, rather than only when `image` changes.
        let scrollView = FitZoomScrollView()
        scrollView.accessibilityIdentifier = AID.readerPage
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator = context.coordinator] in coordinator?.fitToScreen() }

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_: UIScrollView, context: Context) {
        context.coordinator.onTapZone = onTapZone
        let coordinator = context.coordinator
        guard coordinator.imageView?.image !== image else { return }
        coordinator.imageView?.image = image
        coordinator.fitToScreen()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// A plain `UIScrollView` has no hook for "my bounds just became known" —
    /// `layoutSubviews` is the one that fires both on first layout and on a
    /// rotation, which is exactly when the fit-to-screen scale needs redoing.
    final class FitZoomScrollView: UIScrollView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var onTapZone: ((TapZone) -> Void)?

        func viewForZooming(in _: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_: UIScrollView) {
            center()
        }

        /// Sizes the image view to the image's native pixel size, then picks a
        /// `minimumZoomScale` that fits it to the current bounds — the actual
        /// "portrait: one page fit-to-screen" behaviour (READER-DESIGN §2).
        /// Without this, `imageView.frame` stays at the image's full (often
        /// larger-than-screen) pixel size and the scroll view is pannable even
        /// at "zoomScale 1", which also swallows the TabView's own swipe.
        func fitToScreen() {
            guard let scrollView, let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }

            imageView.frame = CGRect(origin: .zero, size: image.size)
            scrollView.contentSize = image.size

            let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            scrollView.minimumZoomScale = fitScale
            scrollView.maximumZoomScale = fitScale * 4
            scrollView.zoomScale = fitScale
            center()
        }

        /// Centers the image within the scroll view when it's smaller than the
        /// viewport (the common case at the fit scale, and after zooming out).
        func center() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            var frame = imageView.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            imageView.frame = frame
        }

        @objc
        func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let fillScale = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 2.5)
            let point = recognizer.location(in: imageView)
            let size = CGSize(
                width: scrollView.bounds.width / fillScale,
                height: scrollView.bounds.height / fillScale
            )
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }

        @objc
        func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let x = recognizer.location(in: scrollView).x
            let width = scrollView.bounds.width
            switch x {
            case ..<(width / 3):
                onTapZone?(.previous)
            case (width * 2 / 3)...:
                onTapZone?(.next)
            default:
                onTapZone?(.toggleChrome)
            }
        }
    }
}
