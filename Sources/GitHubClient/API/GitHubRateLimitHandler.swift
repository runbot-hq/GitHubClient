// GitHubRateLimitHandler.swift
// GitHubClient
// swiftlint:disable missing_docs
import Foundation

// MARK: - RateLimitSnapshot

/// An atomic snapshot of rate-limit state returned by `RateLimitActorProtocol.snapshot()`.
///
/// Using a nominal struct rather than an anonymous tuple prevents conformers from
/// accidentally dropping named labels (which Swift permits silently for tuples),
/// and keeps the return type extensible (e.g. `Equatable`, `Codable`) without
/// an API break.
public struct RateLimitSnapshot: Sendable, Equatable, Hashable {
    /// Whether the GitHub API is currently rate-limiting this client.
    public let isLimited: Bool
    /// The moment at which the rate-limit window expires, or `nil` if unknown.
    public let resetDate: Date?
    /// Creates a new snapshot with the given rate-limit state.
    ///
    /// - Parameters:
    ///   - isLimited: `true` when the GitHub API is currently rate-limiting this client.
    ///   - resetDate: The moment the rate-limit window expires, or `nil` if unknown.
    public init(isLimited: Bool, resetDate: Date?) {
        self.isLimited = isLimited
        self.resetDate = resetDate
    }
}

// MARK: - RateLimitActorProtocol

/// Injectable abstraction over `RateLimitActor` for deterministic testing.
public protocol RateLimitActorProtocol: Actor {
    /// Whether the GitHub API is currently rate-limiting this client.
    var isLimited: Bool { get }
    /// Arms the rate-limit flag and schedules an automatic reset.
    func set(resetAt: TimeInterval?)
    /// Clears the rate-limit flag and cancels any pending reset task.
    func clear()
    /// Clears the rate-limit flag only when the actor is not currently limited.
    func clearIfNotLimited()
    /// Returns `isLimited` and `resetDate` in a single actor hop.
    func snapshot() -> RateLimitSnapshot
}

// MARK: - RateLimitActor

/// Actor-isolated rate-limit state for the GitHub REST API.
public actor RateLimitActor: RateLimitActorProtocol {
    /// Whether the GitHub API is currently rate-limiting this client.
    public private(set) var isLimited = false
    /// The moment at which the rate-limit window expires.
    /// `nil` when the reset time is unknown.
    public private(set) var resetDate: Date?
    /// Structured task that clears `isLimited` when the rate-limit window expires.
    private var resetTask: Task<Void, Never>?
    /// Monotonically increasing generation counter; guards stale reset tasks.
    private var generation = 0
    /// Optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?

    /// Creates a new `RateLimitActor`.
    /// - Parameter logger: The injected logger, or `nil` to suppress output.
    public init(logger: (any GitHubLogger)? = nil) {
        self.logger = logger
    }

    /// Arms the rate-limit flag and schedules an automatic reset.
    /// - Parameter resetAt: Unix timestamp from the `X-RateLimit-Reset` response header.
    public func set(resetAt: TimeInterval?) {
        let delay: TimeInterval
        if let ts = resetAt {
            let secondsUntilReset = ts - Date().timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
        } else {
            delay = 3600
        }
        let date = Date().addingTimeInterval(delay)
        logger?.log("RateLimitActor › arming: delay=\(Int(delay))s resetDate=\(date)", category: "transport")
        generation &+= 1
        let capturedGeneration = generation
        resetTask?.cancel()
        isLimited = true
        resetDate = date
        resetTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self.didFire(generation: capturedGeneration, scheduledDelay: delay)
        }
    }

    /// Clears the rate-limit flag and cancels any pending reset task.
    public func clear() {
        resetTask?.cancel()
        resetTask = nil
        isLimited = false
        resetDate = nil
    }

    /// Clears the rate-limit flag only when the actor is not currently limited.
    public func clearIfNotLimited() {
        guard !isLimited else { return }
        clear()
    }

    /// Returns both `isLimited` and `resetDate` in a single actor hop.
    public func snapshot() -> RateLimitSnapshot {
        RateLimitSnapshot(isLimited: isLimited, resetDate: resetDate)
    }

    // MARK: Private

    /// Fires when `Task.sleep` in `set(resetAt:)` completes without cancellation.
    /// Guards against stale tasks via the `generation` counter.
    private func didFire(generation: Int, scheduledDelay: TimeInterval) async {
        guard generation == self.generation else {
            logger?.log("RateLimitActor › stale didFire ignored (gen=\(generation) current=\(self.generation))", category: "transport")
            return
        }
        isLimited = false
        resetDate = nil
        resetTask = nil
        logger?.log("RateLimitActor › auto-reset fired after \(Int(scheduledDelay))s", category: "transport")
    }
}

/// The module-wide `RateLimitActor` instance.
public let rateLimitActor = RateLimitActor()

// MARK: - Rate-limit accessors

/// Whether the GitHub API is currently rate-limiting this client.
public var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

/// Clears the rate-limit flag. Called at the start of each poll cycle in `RunnerStore.fetch()`.
nonisolated(nonsending)
public func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

/// Returns a `RateLimitSnapshot` in a single actor hop.
nonisolated(nonsending)
public func ghRateLimitSnapshot() async -> RateLimitSnapshot {
    await rateLimitActor.snapshot()
}
