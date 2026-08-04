//
//  CoverImage.swift
//  Kontinuity
//
//  A Komga poster with a placeholder that holds its shape. Covers arrive at
//  different times and different aspect ratios; reserving the frame up front
//  keeps a grid from reflowing under the user's thumb as they load.
//

import KontinuityCore
import SwiftUI

struct CoverImage: View {
    let target: KomgaThumbnail
    /// Komga generates posters from the first page, so book and series covers
    /// are both roughly 2:3. Fixed rather than measured — a grid whose cells
    /// each size themselves is a grid that jumps.
    var aspectRatio: CGFloat = 2.0 / 3.0

    @Environment(KomgaSession.self) private var session
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if !isLoading {
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .task(id: target) {
                isLoading = true
                image = await session.thumbnails.image(for: target)
                isLoading = false
            }
            // The poster is decoration for a label the caller already provides;
            // announcing "image" beside every title just doubles the reading.
            .accessibilityHidden(true)
    }
}
