//
//  ReaderChromeBar.swift
//  Kontinuity
//
//  The top bar both Mode A surfaces show. The paging reader counts spreads and
//  the continuous strip counts pages, so position arrives as text rather than
//  as an index — everything else is identical, and having it in one place is
//  what keeps the two from drifting into different icons for the same action.
//

import KontinuityCore
import SwiftUI

struct ReaderChromeBar: View {
    /// Nil while there's nothing to count yet.
    let position: String?
    let flow: BandFlow
    let onDone: () -> Void
    let onToggleFlow: () -> Void
    let onEnterGlasses: () -> Void

    var body: some View {
        HStack {
            Button("Done", action: onDone)
                .accessibilityIdentifier(AID.readerDone)
            Spacer()
            if let position {
                Text(position)
                    .accessibilityIdentifier(AID.readerPageLabel)
            }
            Spacer()
            Button(action: onToggleFlow) {
                Image(systemName: flow.symbolName)
            }
            .accessibilityIdentifier(AID.readerFlowToggle)
            Button(action: onEnterGlasses) {
                Image(systemName: "eyeglasses")
            }
            .accessibilityIdentifier(AID.readerGlassesModeButton)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

extension BandFlow {
    /// Reports the flow currently in effect, not the one a press switches to —
    /// the button is a state readout you can also act on. Lives here rather
    /// than in `KontinuityCore`, which stays free of presentation.
    var symbolName: String {
        switch self {
        case .perPage: "square.stack"
        case .continuous: "arrow.up.and.down"
        }
    }
}
