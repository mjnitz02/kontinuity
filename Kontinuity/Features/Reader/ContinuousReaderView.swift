//
//  ContinuousReaderView.swift
//  Kontinuity
//
//  Mode A's continuous/web-comic surface (PLAN §12, phase 9B): a vertical
//  `ScrollView` of width-fit pages, replacing the paging `TabView` when
//  `ReaderModel.flow == .continuous`. Width-fit only, no zoom — confirmed
//  with Matt rather than assumed from §12's recommendation alone, since
//  pinch-zoom over a continuous strip is a different problem from
//  `ZoomableImageView`'s per-page scroll view, and phase 3's "zoomable child
//  eats the parent's gesture" bug is waiting to be re-made there.
//
//  Page heights are reserved from the manifest (`ContinuousScrollLayout`,
//  `KontinuityCore`) before any image loads, so the scroll position never
//  jumps under the reader as images land in — the single most likely way to
//  get this wrong (§12).
//
//  Progress has no page turn to hook, unlike the `TabView`'s
//  `currentSpreadIndex.didSet`: a single `GeometryReader`-backed preference
//  key tracks the scroll offset, and `ContinuousScrollLayout.currentPageIndex`
//  (pure, in Core) turns that into "which page's bottom has passed the
//  viewport" — debounced here, then fed to the same `ReaderModel.recordPageRead`
//  Mode B already uses.
//

import KontinuityCore
import SwiftUI
import UIKit

struct ContinuousReaderView: View {
    let pageSources: [PageSource]
    let pageGeometries: [PageGeometry]
    let loader: PageImageLoader
    let initialPageIndex: Int
    let nextBook: KomgaBook?
    /// Fired immediately (not debounced) on every page-boundary crossing —
    /// `ReaderView` mirrors it into its own state so a mid-scroll "enter
    /// glasses mode" tap hands off from wherever the reader actually is,
    /// the continuous counterpart of `reader`'s `currentSpreadIndex`.
    @Binding var currentPageIndex: Int
    let onPageRead: (Int) -> Void
    let onReachEnd: () -> Void
    let onStartNextBook: (KomgaBook) -> Void
    let onDone: () -> Void
    let onEnterGlasses: () -> Void
    let onToggleFlow: () -> Void

    @State private var chromeVisible = true
    @State private var scrollOffset: Double = 0
    @State private var containerWidth: Double = 1
    @State private var progressTask: Task<Void, Never>?
    @State private var hasScrolledToStart = false

    private var pageCount: Int {
        pageSources.count
    }

    private var heights: [Double] {
        pageGeometries.map { ContinuousScrollLayout.pageHeight($0, width: containerWidth) }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ZStack {
                    scrollContent(scrollProxy: scrollProxy)
                        .onAppear {
                            containerWidth = proxy.size.width
                            scrollToStart(scrollProxy)
                        }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            containerWidth = newWidth
                        }

                    if chromeVisible {
                        chrome(scrollProxy: scrollProxy)
                    }
                }
            }
        }
        .background(Color.black)
        .accessibilityIdentifier(AID.readerContinuousSurface)
    }

    private func scrollContent(scrollProxy _: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                GeometryReader { inner in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: inner.frame(in: .named("strip")).minY
                    )
                }
                .frame(height: 0)

                LazyVStack(spacing: 0) {
                    ForEach(pageSources.indices, id: \.self) { index in
                        ContinuousPageRow(
                            index: index,
                            height: heights.indices.contains(index) ? heights[index] : containerWidth,
                            source: pageSources[index],
                            loader: loader
                        )
                        .id(index)
                    }
                    footer
                }
            }
        }
        .coordinateSpace(name: "strip")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            scrollOffset = -value
            handleScrollChange()
        }
        .onTapGesture { withAnimation { chromeVisible.toggle() } }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var footer: some View {
        if currentPageIndex == pageCount - 1, let nextBook {
            Button("Start \(nextBook.displayTitle)") { onStartNextBook(nextBook) }
                .buttonStyle(.borderedProminent)
                .padding(32)
        }
    }

    private func scrollToStart(_ scrollProxy: ScrollViewProxy) {
        guard !hasScrolledToStart, pageSources.indices.contains(initialPageIndex) else { return }
        hasScrolledToStart = true
        scrollProxy.scrollTo(initialPageIndex, anchor: .top)
    }

    /// Debounced (300ms of settled scrolling) rather than firing on every
    /// preference update — `ReaderModel.recordProgress` already de-dupes by
    /// page, so this is about not doing the offset→page arithmetic and
    /// cache housekeeping on every scroll frame of a fast fling, not about
    /// correctness.
    private func handleScrollChange() {
        let heights = heights
        let offsets = ContinuousScrollLayout.offsets(for: heights)
        let index = ContinuousScrollLayout.currentPageIndex(
            offsets: offsets,
            heights: heights,
            scrollOffset: scrollOffset
        )
        guard index != currentPageIndex else { return }
        currentPageIndex = index

        progressTask?.cancel()
        progressTask = Task {
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            onPageRead(index)
            loader.prune(around: index)
            for neighbour in [index - 1, index + 1] where pageSources.indices.contains(neighbour) {
                loader.prefetch(page: neighbour, source: pageSources[neighbour])
            }
            if index == pageCount - 1 {
                onReachEnd()
            }
        }
    }

    private func chrome(scrollProxy: ScrollViewProxy) -> some View {
        VStack {
            HStack {
                Button("Done", action: onDone)
                    .accessibilityIdentifier(AID.readerDone)
                Spacer()
                if pageCount > 0 {
                    Text("\(min(currentPageIndex + 1, pageCount)) / \(pageCount)")
                        .accessibilityIdentifier(AID.readerPageLabel)
                }
                Spacer()
                Button(action: onToggleFlow) {
                    Image(systemName: "arrow.up.and.down")
                }
                .accessibilityIdentifier(AID.readerFlowToggle)
                Button(action: onEnterGlasses) {
                    Image(systemName: "eyeglasses")
                }
                .accessibilityIdentifier(AID.readerGlassesModeButton)
            }
            .padding()
            .background(.ultraThinMaterial)

            Spacer()

            if pageCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentPageIndex) },
                        set: { newValue in scrollProxy.scrollTo(Int(newValue.rounded()), anchor: .top) }
                    ),
                    in: 0 ... Double(pageCount - 1),
                    step: 1
                )
                .padding()
                .background(.ultraThinMaterial)
                .accessibilityIdentifier(AID.readerScrubber)
            }
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}

/// One page, width-fit with no zoom. Height is reserved by the parent from
/// the manifest before this ever decodes anything, so the row never resizes
/// once the image lands — that's what keeps the scroll position stable.
private struct ContinuousPageRow: View {
    let index: Int
    let height: Double
    let source: PageSource
    let loader: PageImageLoader

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .task(id: source) {
            image = loader.cachedImage(forPage: index)
            guard image == nil else { return }
            image = await loader.image(forPage: index, source: source)
        }
    }
}
