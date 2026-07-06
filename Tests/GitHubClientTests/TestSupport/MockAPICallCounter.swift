// MockAPICallCounter.swift
// GitHubClientTests
//
// Spy conformer for APICallCounterProtocol.
// Injected into GitHubTransport(callCounter:) in tests that need to
// assert how many times the transport-layer counter fires.

import Foundation
@testable import GitHubClient

/// A spy `APICallCounterProtocol` actor that records every `record()` call.
///
/// Inject into `GitHubTransport(callCounter:)` to assert counter behaviour
/// without touching the shared `APICallCounter.shared` singleton.
actor MockAPICallCounter: APICallCounterProtocol {

    /// Number of times `record()` has been called.
    private(set) var recordedCount: Int = 0

    /// Increments `recordedCount` by one.
    func record() {
        recordedCount += 1
    }

    /// Returns a snapshot using `recordedCount` as the count.
    func snapshot() -> APICallCounterSnapshot {
        APICallCounterSnapshot(count: recordedCount, limit: APICallCounter.hourlyLimit)
    }

    /// Resets `recordedCount` to zero.
    func reset() {
        recordedCount = 0
    }
}
