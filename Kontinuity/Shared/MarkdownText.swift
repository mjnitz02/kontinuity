//
//  MarkdownText.swift
//  Kontinuity
//
//  Komga stores summaries as Markdown — its own web UI renders them — and real
//  library metadata is full of `[AnimeNewsNetwork](https://…)` links. Rendered
//  as a plain string those show up as raw source, which is how the Skyward Bound
//  summary looked before this existed.
//

import SwiftUI

struct MarkdownText: View {
    let raw: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        // `inlineOnlyPreservingWhitespace`, not `full`: summaries are prose with
        // links, and the paragraph breaks are load-bearing. The full parser
        // collapses them, and it would also honour a stray `#` in a title as a
        // heading.
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        // Malformed Markdown from a scraped summary shouldn't blank the text.
        return (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }
}
