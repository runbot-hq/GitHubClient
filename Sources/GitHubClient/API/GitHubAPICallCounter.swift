// GitHubAPICallCounter.swift
// GitHubClient
//
// Tracks GitHub REST call timestamps in a rolling 60-minute window.
import Foundation

// MARK: - APICallCounterSnapshot

/// Atomic snapshot of API call-counter state returned by `APICallCounterProtocol.snapshot()`.
public struct APICallCounterSnapshot: Sendable, Equatable {
    /// Number of GitHub REST calls made in the last rolling 60-minute window.
    public let count: Int
    /// GitHub authenticated REST rate limit per rolling hour.
    public let limit: Int
    /// Fraction of the hourly limit consumed, clamped to `[0, 1]`.
    public var fraction: Double {
        guard limit > 0 else { return 0.0 }
        return max(0.0, min(Double(count) / Double(limit), 1.0))
    }
    /// Creates a new snapshot.
    public init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
    }
}

// MARK: - APICallCounterProtocol

/// Injectable abstraction over `APICallCounter` for deterministic testing.
public protocol APICallCounterProtocol: Actor {
    /// Record one GitHub REST API call.
    func record()
    /// Returns `count` and `limit` in a single actor hop.
    func snapshot() -> APICallCounterSnapshot
}

// MARK: - APICallCounter

/// Actor-isolated rolling buffer of GitHub REST call timestamps.
public actor APICallCounter: APICallCounterProtocol {
    /// Shared instance wired at module level.
    public static let shared = APICallCounter()
    /// GitHub authenticated REST rate limit per rolling hour.
    public static let hourlyLimit = 5_000
    /// Rolling buffer of call instants in ascending order. Internal so tests can inspect it directly.
    var timestamps: [ContinuousClock.Instant] = []
    /// Creates a new `APICallCounter` instance.
    public init() {}

    // MARK: - Protocol

    /// Records one GitHub REST API call at the current `ContinuousClock` instant.
    public func record() {
        purge()
        timestamps.append(.now)
        if timestamps.count > Self.hourlyLimit {
            timestamps = Array(timestamps.suffix(Self.hourlyLimit))
        }
    }

    /// Returns `count` and `limit` in a single actor hop.
    public func snapshot() -> APICallCounterSnapshot {
        purge()
        return APICallCounterSnapshot(count: timestamps.count, limit: Self.hourlyLimit)
    }

    // MARK: - Private

    /// Evicts timestamps outside the rolling 60-minute window.
    /// Uses `>=` so an instant at exactly the cutoff boundary is retained (inclusive window).
    /// When no timestamp meets the cutoff all entries are stale and the buffer is cleared.
    private func purge() {
        let cutoff = ContinuousClock.now - .seconds(3_600)
        if let idx = timestamps.firstIndex(where: { $0 >= cutoff }) {
            if idx > 0 { timestamps.removeFirst(idx) }
        } else {
            timestamps.removeAll()
        }
    }
}

// MARK: - Module-level accessor

/// The module-wide `APICallCounter` instance shared by `GitHubTransportShim`.
public let apiCallCounter = APICallCounter.shared
