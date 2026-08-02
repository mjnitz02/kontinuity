//
//  BookDetailView.swift
//  Kontinuity
//
//  Where a tapped book lands. Phase 3 turns the Read button into the reader; for
//  now it's the honest end of the browse path — everything known about a book,
//  including why it might not be readable.
//

import KontinuityCore
import SwiftUI

struct BookDetailView: View {
    let book: KomgaBook

    @Environment(KomgaSession.self) private var session
    /// Re-fetched so read progress reflects another device rather than whatever
    /// the list happened to be holding.
    @State private var refreshed: KomgaBook?
    @State private var showingReader = false

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
            ReaderView(book: current, service: session.service, sync: session.sync)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.displayTitle)
                .font(.title2.bold())
                .accessibilityIdentifier(AID.bookDetailTitle)

            if !current.seriesTitle.isEmpty {
                Text(current.seriesTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ReadStateLabel(state: current.readState)
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AID.bookDetailState)

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
                if !authors.isEmpty {
                    detailRow("Authors", authors)
                }
            }
            .font(.caption)

            readButton
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

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func reload() async {
        // Manual refresh trigger #5 (PLAN §5): push anything pending first, so
        // the fetch that follows reflects this device's own latest write too.
        await session.sync.flush()
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

    private var authors: String {
        let writers = current.metadata.authors.filter { $0.role == "writer" }
        let names = (writers.isEmpty ? current.metadata.authors : writers).map(\.name)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.prefix(3).joined(separator: ", ")
    }

    private var summary: String {
        current.metadata.summary
    }
}
