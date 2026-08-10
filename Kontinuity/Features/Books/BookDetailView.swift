//
//  BookDetailView.swift
//  Kontinuity
//
//  Where a tapped book lands: everything known about a book, including why it
//  might not be readable, plus the ways in — read, download, mark read.
//

import KontinuityCore
import SwiftData
import SwiftUI

struct BookDetailView: View {
    let book: KomgaBook

    @Environment(KomgaSession.self) private var session
    /// Re-fetched so read progress reflects another device rather than whatever
    /// the list happened to be holding.
    @State private var refreshed: KomgaBook?
    @State private var showingReader = false
    @State private var isTogglingReadState = false
    @State private var readStateError: String?
    @Query private var bookRows: [Book]

    private var downloadRow: Book? {
        bookRows.first { $0.id == current.id }
    }

    private var current: KomgaBook {
        refreshed ?? book
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        CoverImage(target: .book(current.id))
                            .frame(width: 200)
                        details
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        CoverImage(target: .book(current.id))
                            .frame(maxWidth: 200)
                        details
                    }
                }

                if !summary.isEmpty {
                    Divider()
                    MarkdownText(raw: summary).font(.callout)
                }
            }
            .padding(20)
        }
        .navigationTitle(current.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: book.id) { await reload() }
        .fullScreenCover(isPresented: $showingReader) {
            ReaderView(
                book: current,
                service: session.service,
                sync: session.sync,
                downloads: session.downloads,
                glasses: session.glasses
            )
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.displayTitle)
                .font(.title2.bold())
                .accessibilityIdentifier(AID.bookDetailTitle)

            // Also a link, not just context: arriving here from Keep Reading or
            // On Deck, this is the only thing on screen that knows where the
            // rest of the series is.
            if !current.seriesTitle.isEmpty {
                SeriesLink(book: current)
            }

            Button {
                toggleReadState()
            } label: {
                ReadStateLabel(state: current.readState)
            }
            .font(.subheadline)
            .disabled(isTogglingReadState)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AID.bookDetailState)
            .accessibilityHint("Double tap to change read status")

            if let readStateError {
                Text(readStateError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let progress = current.readProgress {
                // Which device last moved this book is exactly the information
                // missing when a position looks wrong, so it's shown rather than
                // buried in a sync log.
                Text("Last read \(progress.readDate.formatted(date: .abbreviated, time: .shortened))"
                    + (progress.deviceName.isEmpty ? "" : " on \(progress.deviceName)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if !current.metadata.number.isEmpty {
                    detailRow("Number", current.metadata.number)
                }
                detailRow("Pages", current.media.pagesCount > 0 ? "\(current.media.pagesCount)" : "—")
                detailRow("Format", current.media.mediaProfile.isEmpty ? "Unknown" : current.media.mediaProfile)
                if !current.size.isEmpty {
                    detailRow("Size", current.size)
                }
                if let released = current.metadata.releaseDate?.date {
                    detailRow("Released", released.formatted(date: .abbreviated, time: .omitted))
                }
                let credits = current.metadata.authors.creditLine()
                if !credits.isEmpty {
                    detailRow("Authors", credits)
                }
            }
            .font(.caption)

            HStack(spacing: 12) {
                readButton
                downloadControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showingReader = true
            } label: {
                Label(current.readState == .unread ? "Read" : "Continue", systemImage: "book")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!current.isReadable)
            .accessibilityIdentifier(AID.bookDetailRead)

            if !current.isReadable {
                // Being specific matters here: "not analysed yet" resolves on its
                // own, "unreadable" needs the user to go look at the file.
                Label(unreadableReason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch downloadRow?.downloadState ?? .notDownloaded {
        case .notDownloaded, .failed:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    session.downloads.enqueue(book: current)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!current.isReadable)
                .accessibilityIdentifier(AID.bookDetailDownload)

                if let error = downloadRow?.downloadError, downloadRow?.downloadState == .failed {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

        case .queued, .downloading, .decompressing:
            HStack(spacing: 8) {
                ProgressView(value: downloadRow?.downloadProgressFraction ?? 0).frame(width: 60)
                Button("Cancel") { session.downloads.cancel(bookID: current.id) }
            }
            .accessibilityIdentifier(AID.bookDetailDownload)

        case .downloaded:
            Button(role: .destructive) {
                session.downloads.remove(bookID: current.id)
            } label: {
                Label("Remove download", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AID.bookDetailDownload)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// Cycles unread/in-progress → read → unread on a single tap each, so
    /// backing out of an accidental "read" or a too-fast skim is just a
    /// second tap rather than a trip to Komga's web UI. Applied optimistically
    /// — the whole point of surfacing this here is that it should feel as
    /// instant as the tap itself — then pushed to the server; a failure rolls
    /// back by re-fetching the real state rather than guessing at one.
    private func toggleReadState() {
        guard !isTogglingReadState else { return }
        let bookID = current.id
        let pagesCount = current.media.pagesCount
        let markingRead = current.readState != .read

        isTogglingReadState = true
        readStateError = nil
        refreshed = current.withReadProgress(markingRead ? optimisticReadProgress() : nil)
        session.sync.applyExplicitReadState(bookID: bookID, read: markingRead, pagesCount: pagesCount)

        Task {
            defer { isTogglingReadState = false }
            do {
                if markingRead {
                    try await session.service.markRead(bookID: bookID)
                } else {
                    try await session.service.markUnread(bookID: bookID)
                }
            } catch {
                readStateError = error.userMessage
                await reload()
            }
        }
    }

    private func optimisticReadProgress() -> KomgaReadProgress {
        KomgaReadProgress(
            page: current.media.pagesCount,
            completed: true,
            readDate: .now,
            deviceId: session.server.deviceID.uuidString,
            deviceName: session.server.deviceName
        )
    }

    private func reload() async {
        // Manual refresh trigger #5: push anything pending first, so
        // the fetch that follows reflects this device's own latest write too.
        await session.flushAndReconcileDownloads()
        guard let fetched = try? await session.service.book(id: book.id) else { return }
        refreshed = fetched
        session.sync.reconcile(with: fetched)
    }

    private var unreadableReason: String {
        switch current.media.status {
        case "ERROR":
            current.media.comment.isEmpty ? "Komga couldn't read this file." : current.media.comment
        case "READY" where current.media.mediaProfile != "DIVINA":
            "Kontinuity reads CBZ archives only; this is \(current.media.mediaProfile.lowercased())."
        default:
            "Komga hasn't analysed this book yet."
        }
    }

    private var summary: String {
        current.metadata.summary
    }
}
