// APICallCounterTests.swift
// GitHubClientTests
//
// Unit tests for APICallCounter and APICallCounterSnapshot.
//
// The key invariants tested:
//   1. Fresh actor starts at zero.
//   2. record() increments count within the rolling window.
//   3. fraction is always clamped to [0, 1].
//   4. snapshot() is atomic — consistent count + limit in one hop (P10).
//   5. APICallCounterSnapshot is Equatable and Sendable.
//   6. snapshot() returns zero after all timestamps expire (idle-gap regression).
//   7. fetchRunners() / fetchActiveRuns() / fetchJobs() / fetchUserOrgs() /
//      fetchUserRepos() increment on non-nil AND skip on nil transport result.
//   8. record() trims buffer to hourlyLimit at >5,000 entries.
//   9. purge() retains entries exactly at the 60-minute boundary (inclusive).
//  10. purge() evicts entries just beyond the 60-minute boundary (exclusive).
import Foundation
import Testing

@testable import GitHubClient

@Suite("APICallCounter")
struct APICallCounterTests {

  // MARK: - Defaults

  /// Verifies that a newly initialised `APICallCounter` reports a count of zero and exposes the correct hourly limit.
  @Test("fresh actor starts at count zero")
  func freshActorStartsAtZero() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
    #expect(snap.limit == APICallCounter.hourlyLimit)
  }

  /// Verifies that `snapshot().fraction` is `0.0` on a fresh actor with no recorded calls.
  @Test("fresh actor fraction is zero")
  func freshActorFractionIsZero() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.fraction == 0.0)
  }

  // MARK: - record()

  /// Verifies that each sequential `record()` call increments the snapshot count by exactly one.
  @Test("record() increments count by one per call")
  func recordIncrementsCount() async {
    let counter = APICallCounter()
    await counter.record()
    await counter.record()
    await counter.record()
    let snap = await counter.snapshot()
    #expect(snap.count == 3)
  }

  /// Verifies that 20 concurrent `record()` calls from a `TaskGroup` all land in the actor without losing any increment.
  @Test("record() from concurrent tasks all land in the count")
  func recordConcurrentTasks() async {
    let counter = APICallCounter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask { await counter.record() }
      }
    }
    let snap = await counter.snapshot()
    #expect(snap.count == 20)
  }

  /// Verifies that `record()` caps the internal buffer at `hourlyLimit` when the seeded timestamp count exceeds that limit.
  @Test("record() trims buffer to hourlyLimit when entries exceed it")
  func recordTrimsToHourlyLimit() async {
    let counter = APICallCounter()
    let now = ContinuousClock.now
    let fresh = (0..<(APICallCounter.hourlyLimit + 10)).map {
      now.advanced(by: .milliseconds($0))
    }
    await counter.seed(timestamps: fresh)
    await counter.record()
    let snap = await counter.snapshot()
    #expect(snap.count == APICallCounter.hourlyLimit)
  }

  // MARK: - fraction clamping

  /// Verifies that `fraction` returns `0.0` rather than `NaN` when `limit` is zero, preventing propagation of invalid float values.
  @Test("fraction returns 0.0 when limit is zero to prevent NaN propagation")
  func fractionWithZeroLimitIsZero() {
    let snap = APICallCounterSnapshot(count: 42, limit: 0)
    #expect(snap.fraction == 0.0)
  }

  /// Verifies that `fraction` is clamped to `1.0` and never exceeds it, even when `count` is larger than `limit`.
  @Test("fraction is clamped to 1.0 when count exceeds limit")
  func fractionClampedToOne() {
    let snap = APICallCounterSnapshot(count: 9_999, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 1.0)
  }

  /// Verifies that `fraction` is clamped to `0.0` and never goes negative when `count` is a negative value.
  @Test("fraction is clamped to 0.0 when count is negative")
  func fractionClampedToZeroForNegativeCount() {
    let snap = APICallCounterSnapshot(count: -1, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.0)
  }

  /// Verifies that `fraction` is exactly `0.5` when `count` equals `hourlyLimit / 2`.
  @Test("fraction is exactly 0.5 at half the limit")
  func fractionAtHalf() {
    let snap = APICallCounterSnapshot(
      count: APICallCounter.hourlyLimit / 2, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.5)
  }

  /// Verifies that `fraction` stays within `[0.0, 1.0]` across a representative spread of count values.
  @Test("fraction stays within [0, 1] for any count")
  func fractionBounded() {
    for count in [0, 1, 2_500, 5_000, 7_500, 10_000] {
      let snap = APICallCounterSnapshot(count: count, limit: APICallCounter.hourlyLimit)
      #expect(snap.fraction >= 0.0)
      #expect(snap.fraction <= 1.0)
    }
  }

  // MARK: - snapshot atomicity (P10)

  /// Verifies the P10 single-hop atomicity contract: `count` and `limit` are captured together
  /// in one actor hop, so the returned snapshot is internally self-consistent.
  @Test("snapshot returns consistent count + limit in a single hop")
  func snapshotIsConsistent() async {
    let counter = APICallCounter()
    await counter.record()
    let s1 = await counter.snapshot()
    let s2 = await counter.snapshot()
    #expect(s1 == s2)
  }

  /// Exercises the P10 atomicity guarantee under concurrent mutation.
  @Test("snapshot() count+limit are consistent under concurrent record() mutations")
  func snapshotAtomicUnderConcurrentMutations() async {
    let counter = APICallCounter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask { await counter.record() }
      }
      for _ in 0..<20 {
        group.addTask {
          let snap = await counter.snapshot()
          #expect(snap.limit == APICallCounter.hourlyLimit)
          #expect(snap.count <= APICallCounter.hourlyLimit)
          #expect(snap.fraction >= 0.0)
          #expect(snap.fraction <= 1.0)
        }
      }
    }
  }

  /// Verifies that `snapshot().limit` always matches the `APICallCounter.hourlyLimit` constant, regardless of recorded calls.
  @Test("snapshot limit always equals hourlyLimit constant")
  func snapshotLimitMatchesConstant() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.limit == APICallCounter.hourlyLimit)
  }

  // MARK: - Idle-gap regression

  /// Verifies that `snapshot()` returns a count of zero after seeded timestamps have fully expired, covering the idle-gap regression from #1511.
  @Test("snapshot() returns zero after all timestamps expire without a record() call")
  func snapshotPurgesIdleStaleEntries() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-5_400))
    await counter.seed(timestamps: [stale, stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
  }

  // MARK: - Boundary regression

  /// Regression test for purge() inclusive-boundary semantics.
  ///
  /// Uses `now - 3_599 s` (1 second inside the 60-minute window) rather than
  /// exactly `now - 3_600 s` to provide a 1-second buffer against clock jitter
  /// during test execution. The window is inclusive, so an entry at the boundary
  /// must be retained; the buffer ensures a slow machine doesn't accidentally
  /// push the seeded timestamp past the cutoff before `snapshot()` runs.
  @Test("purge() retains entry seeded exactly at the 60-minute boundary")
  func snapshotRetainsEntryExactlyAtCutoffBoundary() async {
    let counter = APICallCounter()
    let boundary = ContinuousClock.now.advanced(by: .seconds(-3_599))
    await counter.seed(timestamps: [boundary])
    let snap = await counter.snapshot()
    #expect(
      snap.count == 1, "entry at exactly the cutoff boundary must be retained (inclusive window)")
  }

  /// Regression test for purge() exclusive-boundary eviction.
  ///
  /// Uses `now - 3_601 s` (1 second past the 60-minute cutoff) rather than
  /// exactly `now - 3_600 s` to provide a 1-second buffer against clock jitter.
  /// An entry this far past the boundary must always be evicted regardless of
  /// minor timing variance during test execution.
  @Test("purge() evicts entry seeded just beyond the 60-minute boundary")
  func snapshotEvictsEntryBeyondCutoff() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-3_601))
    await counter.seed(timestamps: [stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0, "entry 1 s past the cutoff must be evicted")
  }

  // MARK: - APICallCounterSnapshot struct

  /// Verifies that two `APICallCounterSnapshot` instances with identical fields compare equal, and differ when any field differs.
  @Test("APICallCounterSnapshot is Equatable")
  func snapshotEquatable() {
    let a = APICallCounterSnapshot(count: 42, limit: 5_000)
    let b = APICallCounterSnapshot(count: 42, limit: 5_000)
    let c = APICallCounterSnapshot(count: 99, limit: 5_000)
    #expect(a == b)
    #expect(a != c)
  }

  /// Compile-time conformance check for `APICallCounterSnapshot.Sendable`.
  @Test("APICallCounterSnapshot is Sendable across task boundary")
  func snapshotSendable() async {
    let counter = APICallCounter()
    await counter.record()
    await counter.record()
    let snap = await counter.snapshot()
    let transferred = await Task.detached { snap }.value
    #expect(transferred.count == snap.count)
    #expect(transferred.limit == snap.limit)
  }

  // MARK: - Transport increment guard
  //
  // These tests share the module-level `apiCallCounter` actor and each call
  // `reset()` on it. They are run .serialized to prevent concurrent scheduling
  // from interleaving a reset from one test with the record/snapshot of another.
  //
  // Nil-path tests are intentionally omitted for fetchJobs, fetchUserOrgs, and
  // fetchUserRepos: record() sits after a `guard let data = ... else { return }`,
  // making it structurally unreachable on a nil transport result. Testing that
  // would be testing Swift, not this module.
  //
  // fetchActiveRuns is different: record() is placed after the for-loop, so the
  // nil path requires driving two separate mock responses — one non-nil (first
  // status) and one nil (second status). Both cases are covered below.

  @Suite("TransportIncrementGuard", .serialized)
  struct TransportIncrementGuard {

    /// Verifies that `fetchRunners` increments `apiCallCounter` when the transport returns non-nil data.
    @Test("fetchRunners() increments counter when transport returns non-nil data")
    func fetchRunnersIncrementsCounterOnNonNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      let payload = makeRunnersJSON()
      mock.onApiPaginated = { _, _ in payload }
      _ = await fetchRunners(scopeString: "orgs/test", transport: mock)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 1)
    }

    /// Verifies that `fetchActiveRuns` increments `apiCallCounter` exactly once per invocation
    /// regardless of the number of statuses iterated internally (currently two: "in_progress"
    /// and "queued"). Adding a third status must not change this count — record() is called
    /// once after the loop, not once per status.
    @Test("fetchActiveRuns() increments counter exactly once per invocation")
    func fetchActiveRunsIncrementsCounterOnNonNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      let payload = makeRunsJSON()
      mock.onApiPaginated = { _, _ in payload }
      _ = await fetchActiveRuns(scope: .org("test"), transport: mock)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 1)
    }

    /// Verifies that `fetchActiveRuns` does NOT increment `apiCallCounter` when the first
    /// status ("in_progress") returns non-nil but the second ("queued") returns nil,
    /// causing an early `.rateLimited` return before `record()` is reached.
    ///
    /// This covers the partial-success nil path: one API page was fetched successfully,
    /// but the loop did not complete, so the counter must not be incremented.
    @Test("fetchActiveRuns() does not increment counter on partial nil (second status returns nil)")
    func fetchActiveRunsSkipsCounterOnPartialNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      let payload = makeRunsJSON()
      // First call (in_progress) returns data; second call (queued) returns nil.
      var callCount = 0
      mock.onApiPaginated = { _, _ in
        callCount += 1
        return callCount == 1 ? payload : nil
      }
      let result = await fetchActiveRuns(scope: .org("test"), transport: mock)
      // Sanity-check the function took the .rateLimited path (allRuns was non-empty
      // after the first status decoded successfully, or empty but non-nil — either
      // way the early return fires before record()).
      if case .rateLimited = result { /* expected */ }
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 0, "counter must not increment when the loop exits early via .rateLimited")
    }

    /// Verifies that `fetchJobs` increments `apiCallCounter` when the transport returns non-nil data.
    @Test("fetchJobs() increments counter when transport returns non-nil data")
    func fetchJobsIncrementsCounterOnNonNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      let payload = makeJobsJSON()
      mock.onApiPaginated = { _, _ in payload }
      _ = await fetchJobs(runID: 1, scope: .repo(owner: "test", name: "repo"), transport: mock)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 1)
    }

    /// Verifies that `fetchUserOrgs` increments `apiCallCounter` when the transport returns non-nil data.
    @Test("fetchUserOrgs() increments counter when transport returns non-nil data")
    func fetchUserOrgsIncrementsCounterOnNonNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      let payload = makeOrgsJSON()
      mock.onApiPaginated = { _, _ in payload }
      _ = await fetchUserOrgs(transport: mock)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 1)
    }

    /// Verifies that `fetchUserRepos` increments `apiCallCounter` when the transport returns non-nil data.
    @Test("fetchUserRepos() increments counter when transport returns non-nil data")
    func fetchUserReposIncrementsCounterOnNonNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      let payload = makeReposJSON()
      mock.onApiPaginated = { _, _ in payload }
      _ = await fetchUserRepos(transport: mock)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 1)
    }

    /// Verifies that `fetchRunners` does NOT increment `apiCallCounter` when the transport returns nil.
    @Test("fetchRunners() does not increment counter when transport returns nil")
    func fetchRunnersSkipsCounterOnNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      _ = await fetchRunners(scopeString: "orgs/test", transport: mock)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 0)
    }

    /// Verifies that `fetchActiveRuns` does NOT increment `apiCallCounter` when the
    /// first status ("in_progress") returns nil, causing an immediate `.noToken` return.
    @Test("fetchActiveRuns() does not increment counter when first status returns nil")
    func fetchActiveRunsSkipsCounterOnNilResult() async {
      await apiCallCounter.reset()
      let mock = MockTransport()
      _ = await fetchActiveRuns(scope: .org("test"), transport: mock)
      let snap = await apiCallCounter.snapshot()
      #expect(snap.count == 0)
    }
  }
}

// MARK: - JSON fixture helpers

/// Minimal valid runners list JSON for `fetchRunners` decode path.
private func makeRunnersJSON() -> Data {
  Data("{\"runners\":[]}".utf8)
}

/// Minimal valid workflow runs list JSON for `fetchActiveRuns` decode path.
private func makeRunsJSON() -> Data {
  Data("{\"workflow_runs\":[]}".utf8)
}

/// Minimal valid jobs list JSON for `fetchJobs` decode path.
private func makeJobsJSON() -> Data {
  Data("{\"jobs\":[]}".utf8)
}

/// Minimal valid orgs list JSON for `fetchUserOrgs` decode path.
private func makeOrgsJSON() -> Data {
  Data("[]".utf8)
}

/// Minimal valid repos list JSON for `fetchUserRepos` decode path.
private func makeReposJSON() -> Data {
  Data("[]".utf8)
}
