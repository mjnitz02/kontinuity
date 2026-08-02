//
//  SwiftDataTests.swift
//  KontinuityTests
//

import Testing

/// Shared parent for every suite that touches a `Book`/SwiftData
/// `ModelContainer`. Each such suite already serializes its own tests and
/// shares one container across them (see `ProgressionSyncEngineTests` and
/// `DownloadCoordinatorTests`), but Swift Testing still runs distinct
/// top-level suites in parallel with each other by default — and two
/// containers for the same `@Model` types being touched concurrently from
/// different suites is what was actually crashing the app (SIGABRT/SIGTRAP
/// deep in SwiftData's macro-generated property accessors). Nesting both
/// suites here and serializing the parent keeps them from ever overlapping.
@Suite(.serialized)
enum SwiftDataTests {}
