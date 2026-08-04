//
//  ReaderView.swift
//  Kontinuity
//
//  Mode A (iPad panel) from READER-DESIGN §2. Portrait: one page. Landscape:
//  two-page spreads, decided off the container's own aspect rather than device
//  orientation directly, so split-screen/Stage Manager sizing is honoured too.
//

import KontinuityCore
import SwiftUI
import UIKit

struct ReaderView: View {
    let book: KomgaBook
    let service: any KomgaServing
    let sync: ProgressionSyncEngine
    let downloads: DownloadCoordinator
    let glasses: GlassesCoordinator

    @Environment(\.dismiss) private var dismiss
    /// Compact height is true for iPhone landscape and false for every iPad
    /// configuration, including Stage Manager and Split View — the
    /// distinction PLAN 6B §B wants, and not one `UIDevice.orientation`
    /// or raw aspect can make (a face-up iPad fires orientation
    /// notifications despite never changing shape).
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var model: ReaderModel
    @State private var loader: PageImageLoader
    @State private var chromeVisible = true
    @State private var containerSize: CGSize = .zero
    @State private var nextChapterPrompt: NextChapterPrompt?
    /// The continuous surface's counterpart to `model.currentSpreadIndex` —
    /// mirrored here (rather than left inside `ContinuousReaderView`) because
    /// `enterGlassesMode()` needs to read it synchronously at the moment of
    /// the tap, and because it has to survive a glasses round trip, which
    /// tears down and rebuilds `ContinuousReaderView`'s own state.
    @State private var continuousPageIndex = 0

    init(
        book: KomgaBook,
        service: any KomgaServing,
        sync: ProgressionSyncEngine,
        downloads: DownloadCoordinator,
        glasses: GlassesCoordinator
    ) {
        self.book = book
        self.service = service
        self.sync = sync
        self.downloads = downloads
        self.glasses = glasses
        _model = State(initialValue: ReaderModel(book: book, service: service, sync: sync, downloads: downloads))
        _loader = State(initialValue: PageImageLoader(service: service))
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if glasses.isActive {
                    GlassesReaderView(
                        glasses: glasses,
                        showsContent: !glasses.isExternalSceneConnected,
                        onExit: exitGlassesAndReader,
                        onNextBook: { Task { await advanceToNextBookForGlasses() } }
                    )
                } else {
                    content
                        .onAppear { model.updateLayout(for: proxy.size) }
                        .onChange(of: proxy.size) { _, newSize in model.updateLayout(for: newSize) }
                }
            }
            .onAppear { containerSize = proxy.size }
            .onChange(of: proxy.size) { _, newSize in containerSize = newSize }
        }
        .background(Color.black)
        .statusBar(hidden: true)
        .task {
            await model.load()
            // Opening directly into landscape (book reached with the phone
            // already turned sideways) needs the same auto-entry a rotation
            // triggers — `onChange` alone only fires on a subsequent change.
            if verticalSizeClass == .compact {
                enterGlassesMode()
            }
        }
        // Retention/auto-remove must never delete the book currently open
        // (PLAN §6) — this is how the coordinator knows which one that is.
        .onAppear { downloads.openBookID = book.id }
        // Mode B's progression entry point (READER-DESIGN §5, PLAN 6B §C gap
        // 1): `GlassesCoordinator` must not learn about `ProgressionSyncEngine`
        // (PLAN's constraint), so this — the input surface mounted in every
        // Mode B configuration — is what maps a band reaching the last band
        // of its page to `ReaderModel.recordPageRead`.
        .onChange(of: glasses.isActive) { _, active in
            if active {
                handleGlassesBandChange(glasses.currentBandIndex)
            }
        }
        .onChange(of: glasses.currentBandIndex) { _, newIndex in
            guard glasses.isActive else { return }
            handleGlassesBandChange(newIndex)
        }
        // Resets to the resolved resume page on every load — the first
        // open, "Start Volume N", and glasses' own "N" all replace `model`
        // and reload rather than mutating it in place.
        .onChange(of: model.isLoading) { _, loading in
            if !loading {
                continuousPageIndex = model.initialPageIndex
            }
        }
        // iPhone reader mode selection (PLAN 6B §B): compact height is
        // landscape on every iPhone and never true on an iPad, so this only
        // ever fires there — the iPad's manual eyeglasses button is
        // untouched. The round trip is position-preserving in both
        // directions: entering at the page currently open, and leaving at
        // the page the current band belongs to.
        .onChange(of: verticalSizeClass) { _, newValue in
            if newValue == .compact {
                enterGlassesMode()
            } else if glasses.isActive {
                exitGlassesModeToMatchingPage()
            }
        }
        .onDisappear {
            glasses.exit()
            model.flushProgress()
            if downloads.openBookID == book.id {
                downloads.openBookID = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().tint(.white)
        } else if let error = model.loadError {
            errorState(error)
        } else if model.flow == .continuous {
            continuousReader
        } else {
            reader
        }
    }

    /// Mode A's web-comic surface (PLAN §12, phase 9B) — a vertical scroll
    /// replacing `reader`'s `TabView` for a book `ReaderModel.flow` resolved
    /// as `.continuous`. Has no spread pairing, so `updateLayout`/rotation
    /// handling below is a `reader`-only concern.
    private var continuousReader: some View {
        ContinuousReaderView(
            pageSources: model.pageSources,
            pageGeometries: model.pageGeometries,
            loader: loader,
            initialPageIndex: continuousPageIndex,
            nextBook: model.nextBook,
            currentPageIndex: $continuousPageIndex,
            onPageRead: { model.recordPageRead(pageIndex: $0) },
            onReachEnd: { Task { await model.loadNextBookIfNeeded() } },
            onStartNextBook: openNextBook,
            onDone: { dismiss() },
            onEnterGlasses: enterGlassesMode,
            onToggleFlow: toggleFlow
        )
    }

    /// Mode A's own per-page/continuous correction (PLAN §12) — mirrors
    /// `GlassesCoordinator.toggleFlow`, and is position-preserving the same
    /// way `exitGlassesModeToMatchingPage` is: the page currently showing on
    /// whichever surface is active carries over to the other.
    private func toggleFlow() {
        let resumePageIndex = currentLeadingPageIndex
        let newFlow: BandFlow = model.flow == .continuous ? .perPage : .continuous
        model.setFlow(newFlow)
        if newFlow == .continuous {
            continuousPageIndex = resumePageIndex
        } else if let spreadIndex = model.spreads.firstIndex(where: { $0.pageIndices.contains(resumePageIndex) }) {
            model.currentSpreadIndex = spreadIndex
        }
    }

    private var reader: some View {
        ZStack {
            TabView(selection: $model.currentSpreadIndex) {
                ForEach(Array(model.spreads.enumerated()), id: \.offset) { offset, spread in
                    ReaderPageView(
                        spread: spread,
                        pageSources: model.pageSources,
                        loader: loader,
                        onTapZone: handleTapZone
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onChange(of: model.currentSpreadIndex) { _, _ in
                loader.prune(around: currentLeadingPageIndex)
                if model.isAtLastSpread {
                    Task { await model.loadNextBookIfNeeded() }
                } else {
                    nextChapterPrompt = nil
                }
            }
            // Detects an overswipe attempt on the last page — the `TabView`
            // itself just bounces (no selection change, nothing to hook), so
            // this runs alongside it rather than replacing it. Simultaneous,
            // not exclusive, so normal mid-book paging swipes are untouched;
            // gated to a mostly-horizontal, leftward (forward, LTR-pinned —
            // see `ReaderModel.recomputeSpreads`) drag so panning a zoomed-in
            // page doesn't false-trigger it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard model.isAtLastSpread else { return }
                        guard value.translation.width < -40,
                              abs(value.translation.width) > abs(value.translation.height) * 2
                        else { return }
                        handleEndOfBookAdvance()
                    }
            )

            if chromeVisible {
                chrome
            }

            if let prompt = nextChapterPrompt {
                VStack {
                    Spacer()
                    NextChapterToastView(hasNextBook: prompt.hasNextBook)
                        .padding(.bottom, 40)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: nextChapterPrompt)
    }

    /// Komga's "swipe/tap past the last page" affordance (READER-DESIGN §2):
    /// the first forward action once there are no more pages arms a toast
    /// instead of doing nothing; a second forward action within the window
    /// actually advances. Reuses the same next-book plumbing as the "Start
    /// Volume N" chrome button — this is just a faster way to trigger it.
    private func handleEndOfBookAdvance() {
        if nextChapterPrompt != nil {
            nextChapterPrompt = nil
            if let next = model.nextBook {
                openNextBook(next)
            }
            return
        }

        let prompt = NextChapterPrompt(hasNextBook: model.nextBook != nil)
        nextChapterPrompt = prompt
        Task {
            try? await Task.sleep(for: .seconds(4))
            if nextChapterPrompt?.id == prompt.id {
                nextChapterPrompt = nil
            }
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier(AID.readerDone)
                Spacer()
                if !model.spreads.isEmpty {
                    Text("\(model.currentSpreadIndex + 1) / \(model.spreads.count)")
                        .accessibilityIdentifier(AID.readerPageLabel)
                }
                Spacer()
                Button(action: toggleFlow) {
                    Image(systemName: "square.stack")
                }
                .accessibilityIdentifier(AID.readerFlowToggle)
                Button(action: enterGlassesMode) {
                    Image(systemName: "eyeglasses")
                }
                .accessibilityIdentifier(AID.readerGlassesModeButton)
            }
            .padding()
            .background(.ultraThinMaterial)

            Spacer()

            VStack(spacing: 8) {
                if model.isAtLastSpread, let next = model.nextBook {
                    Button("Start \(next.displayTitle)") { openNextBook(next) }
                        .buttonStyle(.borderedProminent)
                }
                if model.spreads.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(model.currentSpreadIndex) },
                            set: { model.currentSpreadIndex = Int($0.rounded()) }
                        ),
                        in: 0 ... Double(model.spreads.count - 1),
                        step: 1
                    )
                    .accessibilityIdentifier(AID.readerScrubber)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private func handleTapZone(_ zone: ZoomableImageView.TapZone) {
        switch zone {
        case .previous: model.retreat()
        case .next:
            if model.isAtLastSpread {
                handleEndOfBookAdvance()
            } else {
                model.advance()
            }
        case .toggleChrome: withAnimation { chromeVisible.toggle() }
        }
    }

    /// Replaces the model in place so "Start Volume N" stays inside this
    /// full-screen cover rather than dismissing and re-presenting.
    private func openNextBook(_ next: KomgaBook) {
        nextChapterPrompt = nil
        model.flushProgress()
        if downloads.openBookID == book.id {
            downloads.openBookID = next.id
        }
        model = ReaderModel(book: next, service: service, sync: sync, downloads: downloads)
        Task { await model.load() }
    }

    private func exitGlassesAndReader() {
        glasses.exit()
        dismiss()
    }

    /// The iPad's manual button and the iPhone's auto-entry on rotation both
    /// land here — same action, different trigger (PLAN 6B §B). Entering at
    /// `currentLeadingPageIndex` rather than band 0 of the book is gap 2
    /// (PLAN 6B §C): a rotation must not throw the reader back to page 1.
    /// The eyeglasses button doesn't itself turn the phone sideways, and
    /// glasses mode has no portrait layout at all on an iPhone — left
    /// unrotated, entry via the button (rather than via the rotation this
    /// mode is actually designed around) leaves bands rendered into a
    /// portrait frame. Nudging the scene to landscape here closes that gap;
    /// it's a no-op on iPad, which has a real portrait glasses layout and
    /// whose button is left untouched (PLAN 6B §B).
    private func rotateToLandscapeIfPhone() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }

    private func enterGlassesMode() {
        rotateToLandscapeIfPhone()
        glasses.enter(
            GlassesContent(
                pageSources: model.pageSources,
                pageGeometries: model.pageGeometries,
                loader: loader,
                seriesID: model.book.seriesId
            ),
            startingPageIndex: currentLeadingPageIndex,
            screenSize: containerSize
        )
    }

    /// Compact height going away — an iPhone rotating back to portrait —
    /// leaves Mode B at the page its current band belongs to, resolved to
    /// the `PageSpread` that contains it so Mode A resumes on the very same
    /// page rather than snapping back to wherever the reader was before
    /// rotating into landscape.
    private func exitGlassesModeToMatchingPage() {
        let resumePageIndex = glasses.currentPageIndex
        glasses.exit()
        if model.flow == .continuous {
            continuousPageIndex = resumePageIndex
            return
        }
        guard let spreadIndex = model.spreads.firstIndex(where: { $0.pageIndices.contains(resumePageIndex) })
        else { return }
        model.currentSpreadIndex = spreadIndex
    }

    /// Glasses mode's `N` binding — unlike `openNextBook`, this awaits the
    /// new model's load before recomputing bands, so glasses mode stays
    /// active across the volume boundary instead of showing stale/empty
    /// bands for a beat.
    private func advanceToNextBookForGlasses() async {
        await model.loadNextBookIfNeeded()
        guard let next = model.nextBook else { return }
        model.flushProgress()
        if downloads.openBookID == book.id {
            downloads.openBookID = next.id
        }
        let newModel = ReaderModel(book: next, service: service, sync: sync, downloads: downloads)
        model = newModel
        await newModel.load()
        glasses.enter(
            GlassesContent(
                pageSources: newModel.pageSources,
                pageGeometries: newModel.pageGeometries,
                loader: loader,
                seriesID: newModel.book.seriesId
            ),
            startingPageIndex: 0,
            screenSize: containerSize
        )
    }

    /// Records progress for every page this band *completes* — READER-DESIGN
    /// §5: "a page counts as read... when its **last** band is reached", not
    /// its first, so a book skimmed in glasses mode doesn't report pages never
    /// actually seen.
    ///
    /// Plural, not singular, because a `.continuous` band covers more than one
    /// page (PLAN §12): a page short enough to be swallowed whole by a single
    /// band is completed by the same band that completes the one before it,
    /// and looking only at the band's own `pageIndex` would leave it
    /// permanently unread.
    private func handleGlassesBandChange(_ index: Int) {
        let bands = glasses.bands
        guard bands.indices.contains(index) else { return }
        let next = bands.indices.contains(index + 1) ? bands[index + 1] : nil
        for pageIndex in bands[index].pageIndices where next?.touches(page: pageIndex) != true {
            model.recordPageRead(pageIndex: pageIndex)
        }
    }

    private var currentLeadingPageIndex: Int {
        if model.flow == .continuous {
            return continuousPageIndex
        }
        guard model.spreads.indices.contains(model.currentSpreadIndex) else { return 0 }
        return model.spreads[model.currentSpreadIndex].pageIndices.first ?? 0
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't open this book", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await model.load() } }
            Button("Done") { dismiss() }
        }
        .foregroundStyle(.white)
    }
}

/// Armed by the first forward action on a book's last page; a second one
/// within the window consumes it (see `ReaderView.handleEndOfBookAdvance`).
private struct NextChapterPrompt: Identifiable, Equatable {
    let id = UUID()
    let hasNextBook: Bool
}

private struct NextChapterToastView: View {
    let hasNextBook: Bool

    var body: some View {
        Text(hasNextBook ? "Swipe or tap again to read the next chapter" : "No more chapters")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: .capsule)
            .shadow(radius: 4, y: 2)
            .accessibilityIdentifier(AID.readerNextChapterToast)
    }
}
