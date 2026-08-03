//
//  UITestContract.swift
//  KontinuityCore
//
//  The vocabulary shared by the app and the XCUITest bundle. A UI test bundle
//  does not link the app it drives, so without a common home these constants
//  would exist twice and drift silently — a renamed identifier would turn into a
//  timeout ten minutes into a CI run rather than a compile error.
//
//  Core is the natural home: it has no UIKit, both targets already link it, and
//  accessibility identifiers are shipping metadata anyway, not test scaffolding.
//

import Foundation

/// Deterministic launch states a UI test can ask for.
///
/// Passed as `-UITestMode <rawValue>`. Arguments in `-key value` form land in
/// `UserDefaults`' volatile domain automatically, so neither side has to parse
/// `CommandLine.arguments` by hand.
public enum UITestMode: String, Sendable {
    /// No saved server: the app opens on the connect screen.
    case fresh
    /// A saved server backed by an in-memory store and a canned library.
    case connected
    /// `.connected`, but every server-hit method fails offline-shaped
    /// (`KomgaError.transport(code: .notConnectedToInternet, …)`) and
    /// nothing is pre-seeded downloaded — PLAN §11's "nothing to fall back
    /// to" case.
    case offline
    /// `.offline`, plus a handful of pre-seeded downloaded `Book` rows so a
    /// UI test can assert the offline fallback views actually show what's
    /// downloaded — and only what's downloaded.
    case offlineWithDownloads

    public static let defaultsKey = "UITestMode"

    /// The mode this process was launched in, or nil for an ordinary run.
    public static var current: UITestMode? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return UITestMode(rawValue: raw)
    }
}

/// Identifiers of the canned library the app serves itself in
/// ``UITestMode/connected``. The fixture data itself lives in the app target;
/// only the ids are shared, so a test can say "open Windrunner" without depending
/// on display text that's free to change.
///
/// Fixture titles are always fictitious — never a real series from Matt's Komga
/// library — so nothing copyrighted ends up committed to the repo.
public enum UITestFixture {
    public static let mangaLibraryID = "lib-manga"
    public static let comicsLibraryID = "lib-comics"

    /// Partly read: has unread books, one in progress. The general case.
    public static let inProgressSeriesID = "series-windrunner"
    /// Every book read — exercises the "no badge" path.
    public static let finishedSeriesID = "series-neon-requiem"
    /// In the second library, so the library filter has something to prove.
    public static let comicsSeriesID = "series-halcyon-drift"

    public static let unreadBookID = "book-windrunner-3"
    public static let inProgressBookID = "book-windrunner-2"
    public static let readBookID = "book-windrunner-1"
    /// Komga hasn't analysed it: zero pages, not readable.
    public static let unanalysedBookID = "book-windrunner-4"
}

/// Accessibility identifiers for the elements UI tests drive.
///
/// Identifiers, not labels: labels are user-facing text that should be free to
/// change without breaking a test, and they're the thing localisation would move
/// if that ever stops being a non-goal.
public enum AID {
    // Connect
    public static let connectAddressField = "connect.address"
    public static let connectEmailField = "connect.email"
    public static let connectPasswordField = "connect.password"
    public static let connectAPIKeyField = "connect.apiKey"
    public static let connectMethodPicker = "connect.method"
    public static let connectSubmit = "connect.submit"
    public static let connectError = "connect.error"

    // Sidebar
    public static let sidebar = "sidebar"
    public static let sidebarKeepReading = "sidebar.keepReading"
    public static let sidebarOnDeck = "sidebar.onDeck"
    public static let sidebarAllSeries = "sidebar.allSeries"
    public static let sidebarDownloaded = "sidebar.downloaded"
    public static let sidebarServer = "sidebar.server"

    /// One row per Komga library, keyed by the server's id.
    public static func sidebarLibrary(_ id: String) -> String {
        "sidebar.library.\(id)"
    }

    // Browse
    public static let seriesGrid = "series.grid"
    public static let seriesSearchField = "series.search"
    public static let browseEmpty = "browse.empty"
    public static let browseError = "browse.error"
    /// The persistent "showing downloaded ... only" banner an offline
    /// fallback view shows so it's never mistaken for the whole library
    /// (PLAN §11).
    public static let offlineBanner = "offline.banner"

    /// Grid cells and book rows are single accessibility elements — combined so
    /// VoiceOver reads them as one thing — so their unread count and read state
    /// live in the element's *label*, not in separately queryable children.
    /// Assert on the label for those; there is deliberately no badge identifier.
    public static func seriesCell(_ id: String) -> String {
        "series.cell.\(id)"
    }

    /// The "go to the whole series" link, on a shelf cell and on book detail —
    /// keyed by the *series* id, since that's what it navigates to and there is
    /// only ever one per screen region.
    public static func seriesLink(_ id: String) -> String {
        "series.link.\(id)"
    }

    // Series detail
    public static let seriesDetailTitle = "seriesDetail.title"
    public static let seriesDetailSummary = "seriesDetail.summary"
    public static let seriesBookList = "seriesDetail.books"
    public static let seriesSortOrder = "seriesDetail.sortOrder"

    public static func bookRow(_ id: String) -> String {
        "book.row.\(id)"
    }

    // Book detail — not combined, so the read state is its own element here.
    public static let bookDetailTitle = "bookDetail.title"
    public static let bookDetailState = "bookDetail.state"
    public static let bookDetailRead = "bookDetail.read"

    /// Sync
    public static let syncConflictNotice = "sync.conflictNotice"

    // Downloads
    public static let seriesDownloadUnread = "seriesDetail.downloadUnread"
    public static let bookDetailDownload = "bookDetail.download"
    public static let downloadsList = "downloads.list"
    public static let downloadsEmpty = "downloads.empty"
    public static let downloadsCapPicker = "downloads.capPicker"
    public static let downloadsAutoRemoveToggle = "downloads.autoRemoveToggle"

    /// One row per downloaded/downloading book, keyed by the book's id.
    public static func downloadRow(_ id: String) -> String {
        "downloads.row.\(id)"
    }

    // Reader
    /// The zoomable page surface itself — a UI test taps normalized coordinates
    /// on it for the left/right turn zones rather than needing separate
    /// identifiers per zone.
    public static let readerPage = "reader.page"
    public static let readerDone = "reader.done"
    public static let readerPageLabel = "reader.pageLabel"
    public static let readerScrubber = "reader.scrubber"
    /// The "swipe/tap again to continue" toast shown on the last page of a
    /// book (READER-DESIGN §2's Komga-style two-step advance).
    public static let readerNextChapterToast = "reader.nextChapterToast"

    // Glasses mode (Mode B, READER-DESIGN §3)
    public static let readerGlassesModeButton = "reader.glassesModeButton"
    public static let glassesSurface = "glasses.surface"
    public static let glassesStatusLabel = "glasses.statusLabel"
    public static let glassesExit = "glasses.exit"
    /// Shown on black while the next page decodes — the page-transition
    /// indicator, and the only thing on screen during a boundary the reader
    /// hasn't prefetched through.
    public static let glassesPageSpinner = "glasses.pageSpinner"

    /// Chrome reached by the centre-half tap (PLAN 6B §C/§D, READER-DESIGN
    /// §3's iPhone section) — the touch-reachable equivalents for the
    /// keyboard-only controls, since a phone in landscape has no keyboard.
    public static let glassesPageLabel = "glasses.pageLabel"
    public static let glassesNextBook = "glasses.nextBook"
    public static let glassesDimDecrease = "glasses.dimDecrease"
    public static let glassesDimIncrease = "glasses.dimIncrease"
    public static let glassesAutoScrollToggle = "glasses.autoScrollToggle"
}
