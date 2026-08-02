//
//  ReadStateViews.swift
//  Kontinuity
//
//  Read state is the thing this app exists to get right, so it gets one
//  presentation shared by the grid, the book list and the detail screens rather
//  than three that drift.
//

import KontinuityCore
import SwiftUI

/// The unread count on a series cover, in the corner Komga's own web UI uses.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint, in: .capsule)
            .foregroundStyle(.white)
    }
}

/// The thin progress bar along the bottom of an in-progress cover.
struct ReadProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.35))
                Rectangle()
                    .fill(.tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

extension KomgaReadState {
    /// Short enough for a table row; spelled out enough to be unambiguous.
    var label: String {
        switch self {
        case .unread: "Unread"
        case let .inProgress(page, total): "Page \(page) of \(total)"
        case .read: "Read"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .read: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unread: .secondary
        case .inProgress: .accentColor
        case .read: .green
        }
    }
}

struct ReadStateLabel: View {
    let state: KomgaReadState

    var body: some View {
        Label(state.label, systemImage: state.systemImage)
            .font(.caption)
            .foregroundStyle(state.tint)
            .labelStyle(.titleAndIcon)
    }
}
