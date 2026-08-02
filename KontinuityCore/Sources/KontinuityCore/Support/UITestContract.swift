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

    /// Grid cells and book rows are single accessibility elements — combined so
    /// VoiceOver reads them as one thing — so their unread count and read state
    /// live in the element's *label*, not in separately queryable children.
    /// Assert on the label for those; there is deliberately no badge identifier.
    public static func seriesCell(_ id: String) -> String {
        "series.cell.\(id)"
    }

    // Series detail
    public static let seriesDetailTitle = "seriesDetail.title"
    public static let seriesDetailSummary = "seriesDetail.summary"
    public static let seriesBookList = "seriesDetail.books"

    public static func bookRow(_ id: String) -> String {
        "book.row.\(id)"
    }

    // Book detail — not combined, so the read state is its own element here.
    public static let bookDetailTitle = "bookDetail.title"
    public static let bookDetailState = "bookDetail.state"
    public static let bookDetailRead = "bookDetail.read"

    // Reader
    /// The zoomable page surface itself — a UI test taps normalized coordinates
    /// on it for the left/right turn zones rather than needing separate
    /// identifiers per zone.
    public static let readerPage = "reader.page"
    public static let readerDone = "reader.done"
    public static let readerPageLabel = "reader.pageLabel"
    public static let readerScrubber = "reader.scrubber"
}
