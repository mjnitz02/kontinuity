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

    @Environment(\.dismiss) private var dismiss
    @State private var model: ReaderModel
    @State private var loader: PageImageLoader
    @State private var chromeVisible = true

    init(book: KomgaBook, service: any KomgaServing, sync: ProgressionSyncEngine, downloads: DownloadCoordinator) {
        self.book = book
        self.service = service
        self.sync = sync
        self.downloads = downloads
        _model = State(initialValue: ReaderModel(book: book, service: service, sync: sync, downloads: downloads))
        _loader = State(initialValue: PageImageLoader(service: service))
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .onAppear { model.updateLayout(for: proxy.size) }
                .onChange(of: proxy.size) { _, newSize in model.updateLayout(for: newSize) }
        }
        .background(Color.black)
        .statusBar(hidden: true)
        .task { await model.load() }
        // Retention/auto-remove must never delete the book currently open
        // (PLAN §6) — this is how the coordinator knows which one that is.
        .onAppear { downloads.openBookID = book.id }
        .onDisappear {
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
