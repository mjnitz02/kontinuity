//
//  BookStore.swift
//  Kontinuity
//
//  The `Book` row access both engines need. `ProgressionSyncEngine` and
//  `DownloadCoordinator` write different halves of the same row and are
//  deliberately not coupled to each other, but they reached for the identical
//  fetch/upsert helpers — so those live here once instead of twice.
//

import Foundation
import KontinuityCore
import SwiftData

@MainActor
struct BookStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Filters in plain Swift rather than a `#Predicate` — a library's worth of
    /// rows is small, and fetching the lot sidesteps a real crash in SwiftData's
    /// predicate compilation when several in-memory containers are queried
    /// concurrently. That's a test-harness scenario, but the fetch shape
    /// shouldn't depend on it.
    func all() -> [Book] {
        (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
    }

    /// Resolves one row. Callers touching many rows at once should work from
    /// `all()` instead — this reads the whole table per call.
    func find(_ bookID: String) -> Book? {
        all().first { $0.id == bookID }
    }

    func findOrCreate(_ bookID: String) -> Book {
        if let existing = find(bookID) {
            return existing
        }
        let book = Book(id: bookID, localPage: 0, localReadDate: .now, pageHref: "", mediaType: "")
        modelContext.insert(book)
        return book
    }

    /// Rows with an unpushed write — the outbox, which is just a flag on the
    /// row rather than a table of its own.
    func pending() -> [Book] {
        all().filter(\.isPending)
    }

    func save() {
        try? modelContext.save()
    }
}
