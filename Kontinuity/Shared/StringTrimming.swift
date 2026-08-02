//
//  StringTrimming.swift
//  Kontinuity
//
//  Trimming user input comes up on the connect form, in the search field, and in
//  the stub service's query matching. `nonisolated` because the app target
//  defaults to `MainActor` isolation, and a string helper that can only be
//  called from the main actor is a helper that stops being usable the moment
//  something moves off it.
//

import Foundation

nonisolated extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
