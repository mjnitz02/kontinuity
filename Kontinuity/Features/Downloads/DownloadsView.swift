//
//  DownloadsView.swift
//  Kontinuity
//
//  PLAN §7: "Downloaded" is a first-class sidebar root that works with no
//  server at all — every row here is built from the SwiftData `Book` cache,
//  never from a live fetch. Also where PLAN §6's two retention knobs (storage
//  cap, auto-remove-on-finish) live, colocated with what they act on.
//

import KontinuityCore
import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(KomgaSession.self) private var session
    @Query private var books: [Book]

    private let settings = DownloadSettings()
    @State private var storageCapBytes = DownloadSettings().storageCapBytes
    @State private var autoRemoveOnFinish = DownloadSettings().autoRemoveOnFinish
    @State private var readerBook: KomgaBook?

    private static let capOptionsGB = [2, 4, 8, 16, 32, 64]

    var body: some View {
        List {
            storageSection
            if let warning = session.downloads.retentionWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            activityContent
        }
        .accessibilityIdentifier(AID.downloadsList)
        .navigationTitle("Downloaded")
        .fullScreenCover(item: $readerBook) { book in
            ReaderView(book: book, service: session.service, sync: session.sync, downloads: session.downloads)
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Storage") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(byteCount(totalDownloadedBytes))
                    Text("of").foregroundStyle(.secondary)
                    Text(byteCount(storageCapBytes)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                ProgressView(value: min(1, capUsageFraction))
                    .tint(capUsageFraction > 1 ? .orange : .accentColor)
            }

            Picker("Storage limit", selection: capBinding) {
                ForEach(Self.capOptionsGB, id: \.self) { gigabytes in
                    Text("\(gigabytes) GB").tag(Int64(gigabytes) * 1_073_741_824)
                }
            }
            .accessibilityIdentifier(AID.downloadsCapPicker)

            Toggle("Remove finished books automatically", isOn: autoRemoveBinding)
                .accessibilityIdentifier(AID.downloadsAutoRemoveToggle)
        }
    }

    private var capUsageFraction: Double {
        guard storageCapBytes > 0 else { return 0 }
        return Double(totalDownloadedBytes) / Double(storageCapBytes)
    }

    private var capBinding: Binding<Int64> {
        Binding(
            get: { storageCapBytes },
            set: { newValue in
                storageCapBytes = newValue
                settings.storageCapBytes = newValue
                Task { await session.downloads.applyRetention() }
            }
        )
    }

    private var autoRemoveBinding: Binding<Bool> {
        Binding(
            get: { autoRemoveOnFinish },
            set: { newValue in
                autoRemoveOnFinish = newValue
                settings.autoRemoveOnFinish = newValue
            }
        )
    }

    // MARK: - Book lists

    @ViewBuilder
    private var activityContent: some View {
        if !active.isEmpty {
            Section("Downloading") {
                ForEach(active) { row(for: $0) }
            }
        }
        if !failed.isEmpty {
            Section("Couldn't download") {
                ForEach(failed) { row(for: $0) }
            }
        }
        if !downloaded.isEmpty {
            Section("Downloaded") {
                ForEach(downloaded) { row(for: $0) }
            }
        }
        if active.isEmpty, failed.isEmpty, downloaded.isEmpty {
            Section {
                ContentUnavailableView(
                    "Nothing downloaded",
                    systemImage: "arrow.down.circle",
                    description: Text("Download unread volumes from a series to read them offline.")
                )
                .accessibilityIdentifier(AID.downloadsEmpty)
            }
        }
    }

    private var active: [Book] {
        books
            .filter { [.queued, .downloading, .decompressing].contains($0.downloadState) }
            .sorted { ($0.title ?? $0.id) < ($1.title ?? $1.id) }
    }

    private var failed: [Book] {
        books.filter { $0.downloadState == .failed }.sorted { ($0.title ?? $0.id) < ($1.title ?? $1.id) }
    }

    private var downloaded: [Book] {
        books
            .filter { $0.downloadState == .downloaded }
            .sorted { ($0.downloadedDate ?? .distantPast) > ($1.downloadedDate ?? .distantPast) }
    }

    private var totalDownloadedBytes: Int64 {
        downloaded.reduce(0) { $0 + $1.downloadedBytes }
    }

    private func row(for book: Book) -> some View {
        Button {
            guard book.downloadState == .downloaded else { return }
            readerBook = book.asKomgaBook
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title ?? book.id).font(.body).lineLimit(1)
                    Text(subtitle(for: book)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                trailing(for: book)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AID.downloadRow(book.id))
    }

    private func subtitle(for book: Book) -> String {
        var parts: [String] = []
        if let seriesTitle = book.seriesTitle, !seriesTitle.isEmpty {
            parts.append(seriesTitle)
        }
        if book.downloadState == .downloaded {
            parts.append(byteCount(book.downloadedBytes))
        } else if let error = book.downloadError, book.downloadState == .failed {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func trailing(for book: Book) -> some View {
        switch book.downloadState {
        case .queued:
            cancelButton(for: book, label: "Queued")
        case .downloading, .decompressing:
            HStack(spacing: 8) {
                ProgressView(value: progressFraction(for: book)).frame(width: 60)
                cancelButton(for: book, label: nil)
            }
        case .failed:
            Button("Retry") { session.downloads.enqueue(book: book.asKomgaBook) }
                .font(.caption)
        case .downloaded:
            Button(role: .destructive) { session.downloads.remove(bookID: book.id) } label: {
                Image(systemName: "trash")
            }
        case .notDownloaded:
            EmptyView()
        }
    }

    private func cancelButton(for book: Book, label: String?) -> some View {
        HStack(spacing: 8) {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel") { session.downloads.cancel(bookID: book.id) }.font(.caption)
        }
    }

    private func progressFraction(for book: Book) -> Double {
        guard book.expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(book.downloadedBytes) / Double(book.expectedBytes)))
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension Book {
    /// Reconstructs a `KomgaBook` from the cached metadata so the reader can
    /// open a downloaded book with no server involved at all — the whole
    /// point of the "Downloaded" root (PLAN §7). `readProgress` is left nil:
    /// `ReaderModel` resolves the resume position through `ProgressionSyncEngine`
    /// against this same row, not from this field.
    var asKomgaBook: KomgaBook {
        KomgaBook(
            id: id,
            seriesId: seriesID ?? "",
            seriesTitle: seriesTitle ?? "",
            name: title ?? id,
            sizeBytes: sizeBytes ?? 0,
            media: KomgaMedia(pagesCount: pagesCount ?? 0),
            metadata: KomgaBookMetadata(title: title ?? "", number: number ?? "", numberSort: numberSort ?? 0)
        )
    }
}
