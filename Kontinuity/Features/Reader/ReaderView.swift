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
        // of its page to `ReaderModel.recordGlassesPageRead`.
        .onChange(of: glasses.isActive) { _, active in
            if active {
                handleGlassesBandChange(glasses.currentBandIndex)
            }
        }
        .onChange(of: glasses.currentBandIndex) { _, newIndex in
            guard glasses.isActive else { return }
            handleGlassesBandChange(newIndex)
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
        } else {
            reader
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
                }
            }

            if chromeVisible {
                chrome
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
        case .next: model.advance()
        case .toggleChrome: withAnimation { chromeVisible.toggle() }
        }
    }

    /// Replaces the model in place so "Start Volume N" stays inside this
    /// full-screen cover rather than dismissing and re-presenting.
    private func openNextBook(_ next: KomgaBook) {
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
    private func enterGlassesMode() {
        glasses.enter(
            pageSources: model.pageSources,
            pageGeometries: model.pageGeometries,
            loader: loader,
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
            pageSources: newModel.pageSources,
            pageGeometries: newModel.pageGeometries,
            loader: loader,
            startingPageIndex: 0,
            screenSize: containerSize
        )
    }

    /// Maps a band index to "did this just reach the last band of its page"
    /// and, if so, records progress for that page — READER-DESIGN §5: "a page
    /// counts as read... when its **last** band is reached", not its first,
    /// so a book skimmed in glasses mode doesn't report pages never actually
    /// seen.
    private func handleGlassesBandChange(_ index: Int) {
        let bands = glasses.bands
        guard bands.indices.contains(index) else { return }
        let pageIndex = bands[index].pageIndex
        let isLastBandOfPage = index + 1 >= bands.count || bands[index + 1].pageIndex != pageIndex
        guard isLastBandOfPage else { return }
        model.recordGlassesPageRead(pageIndex: pageIndex)
    }

    private var currentLeadingPageIndex: Int {
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
