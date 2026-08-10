//
//  TextFormatting.swift
//  Kontinuity
//
//  The two string chores that come up on more than one screen. `nonisolated`
//  because the app target defaults to `MainActor` isolation, and a string
//  helper only callable from the main actor stops being usable the moment
//  something moves off it.
//

import Foundation

nonisolated extension String {
    /// Trimming user input: the connect form, the search field, and the stub
    /// service's query matching.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated extension Int {
    /// "1 book" / "12 books". Regular plurals only — every noun this counts is
    /// one, and a full pluralisation rule set would be dead weight.
    func counted(_ singular: String) -> String {
        "\(self) \(singular)\(self == 1 ? "" : "s")"
    }
}
