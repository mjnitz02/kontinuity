//
//  ConflictNoticeBanner.swift
//  Kontinuity
//
//  When both sides moved since the last sync, take the further page and *say
//  so* — silently discarding a position is exactly the failure mode
//  that makes the other clients frustrating. One banner, mounted once at the
//  split view, rather than threaded through every screen that can trigger a
//  reconciliation.
//

import KontinuityCore
import SwiftUI

struct ConflictNoticeBanner: View {
    let notice: ConflictNotice

    var body: some View {
        Label(message, systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: .capsule)
            .shadow(radius: 4, y: 2)
            .padding(.top, 8)
            .accessibilityIdentifier(AID.syncConflictNotice)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var message: String {
        notice.resolvedToLocal
            ? "Kept this device's further progress (page \(notice.resolvedPage))."
            : "Synced progress from another device (page \(notice.resolvedPage))."
    }
}
