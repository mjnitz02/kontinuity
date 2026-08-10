//
//  PageSource.swift
//  Kontinuity
//
//  Decompressed files on disk when downloaded, streamed otherwise. A
//  downloaded book has no hrefs — `ReaderModel` resolves a
//  local file URL for every page instead — so `PageImageLoader`/
//  `ReaderPageView` take this rather than a bare `KomgaPageLink`, and neither
//  needs to know which case it's holding.
//

import Foundation
import KontinuityCore

enum PageSource: Hashable {
    case remote(KomgaPageLink)
    case local(url: URL, mediaType: String)
}
