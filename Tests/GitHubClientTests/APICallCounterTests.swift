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
//   7. GitHubTransport increments the injected callCounter on every 2xx response.
//      Each successful HTTP page counts as one hit.
//   8. record() trims buffer to hourlyLimit at >5,000 entries.
//   9. purge() retains entries exactly at the 60-minute boundary (inclusive).
//  10. purge() evicts entries just beyond the 60-minute boundary (exclusive).
import Foundation
import Testing

@testable import GitHubClient

@Suite("APICallCounter")
struct APICallCounterTests {

  // MARK: - Defaults

  @Test("fresh actor starts at count zero")
  func freshActorStartsAtZero() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
    #expect(snap.limit == APICallCounter.hourlyLimit)
  }

  @Test("fresh actor fraction is zero")
  func freshActorFractionIsZero() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.fraction == 0.0)
  }

  // MARK: - record()

  @Test("record() increments count by one per call")
  func recordIncrementsCount() async {
    let counter = APICallCounter()
    await counter.record()
    await counter.record()
    await counter.record()
    let snap = await counter.snapshot()
    #expect(snap.count == 3)
  }

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

  @Test("fraction returns 0.0 when limit is zero to prevent NaN propagation")
  func fractionWithZeroLimitIsZero() {
    let snap = APICallCounterSnapshot(count: 42, limit: 0)
    #expect(snap.fraction == 0.0)
  }

  @Test("fraction is clamped to 1.0 when count exceeds limit")
  func fractionClampedToOne() {
    let snap = APICallCounterSnapshot(count: 9_999, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 1.0)
  }

  @Test("fraction is clamped to 0.0 when count is negative")
  func fractionClampedToZeroForNegativeCount() {
    let snap = APICallCounterSnapshot(count: -1, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.0)
  }

  @Test("fraction is exactly 0.5 at half the limit")
  func fractionAtHalf() {
    let snap = APICallCounterSnapshot(
      count: APICallCounter.hourlyLimit / 2, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.5)
  }

  @Test("fraction stays within [0, 1] for any count")
  func fractionBounded() {
    for count in [0, 1, 2_500, 5_000, 7_500, 10_000] {
      let snap = APICallCounterSnapshot(count: count, limit: APICallCounter.hourlyLimit)
      #expect(snap.fraction >= 0.0)
      #expect(snap.fraction <= 1.0)
    }
  }

  // MARK: - snapshot atomicity (P10)

  @Test("snapshot returns consistent count + limit in a single hop")
  func snapshotIsConsistent() async {
    let counter = APICallCounter()
    await counter.record()
    let s1 = await counter.snapshot()
    let s2 = await counter.snapshot()
    #expect(s1 == s2)
  }

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

  @Test("snapshot limit always equals hourlyLimit constant")
  func snapshotLimitMatchesConstant() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.limit == APICallCounter.hourlyLimit)
  }

  // MARK: - Idle-gap regression

  @Test("snapshot() returns zero after all timestamps expire without a record() call")
  func snapshotPurgesIdleStaleEntries() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-5_400))
    await counter.seed(timestamps: [stale, stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
  }

  // MARK: - Boundary regression

  @Test("purge() retains entry seeded exactly at the 60-minute boundary")
  func snapshotRetainsEntryExactlyAtCutoffBoundary() async {
    let counter = APICallCounter()
    let boundary = ContinuousClock.now.advanced(by: .seconds(-3_599))
    await counter.seed(timestamps: [boundary])
    let snap = await counter.snapshot()
    #expect(
      snap.count == 1, "entry at exactly the cutoff boundary must be retained (inclusive window)")
  }

  @Test("purge() evicts entry seeded just beyond the 60-minute boundary")
  func snapshotEvictsEntryBeyondCutoff() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-3_601))
    await counter.seed(timestamps: [stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0, "entry 1 s past the cutoff must be evicted")
  }

  // MARK: - APICallCounterSnapshot struct

  @Test("APICallCounterSnapshot is Equatable")
  func snapshotEquatable() {
    let a = APICallCounterSnapshot(count: 42, limit: 5_000)
    let b = APICallCounterSnapshot(count: 42, limit: 5_000)
    let c = APICallCounterSnapshot(count: 99, limit: 5_000)
    #expect(a == b)
    #expect(a != c)
  }

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

  // MARK: - Transport-layer counter (TransportIncrementGuard)
  //
  // Verifies that GitHubTransport.interpretHTTPResponse() increments the
  // injected callCounter on every 2xx response, using StubURLProtocol
  // (defined in GitHubTransportPaginatedTests.swift) as the network shim.
  //
  // URLSession isolation
  // --------------------
  // GitHubTransportPaginatedTests registers StubURLProtocol on
  // URLSession.shared via URLProtocol.registerClass in its init/deinit.
  // TransportIncrementGuard must NOT rely on that lifecycle, because the
  // two suites run concurrently and GitHubTransportPaginatedTests may
  // not have called registerClass yet (or may have already called
  // unregisterClass) when TransportIncrementGuard tests execute.
  //
  // Fix: each test builds a private URLSession using
  // URLSessionConfiguration.ephemeral with protocolClasses injected
  // directly. This session is fully self-contained and never touches
  // URLSession.shared or the registerClass/unregisterClass lifecycle.
  //
  // .serialized is required so tests within THIS suite do not race on
  // the shared stub registry (each test registers new stubs).
  //
  // final class is required for instance storage (the `org` constant).

  @Suite("TransportIncrementGuard", .serialized)
  final class TransportIncrementGuard {

    // Distinct org — never appears in GitHubTransportPaginatedTests.
    private let org = "counter-test"

    // Private URLSession with StubURLProtocol injected via protocolClasses.
    // Fully self-contained: does not depend on URLProtocol.registerClass /
    // unregisterClass. Safe to use regardless of GitHubTransportPaginatedTests
    // registration lifecycle.
    private let stubSession: URLSession = {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [StubURLProtocol.self]
      return URLSession(configuration: config)
    }()

    private func makeTransport(counter: MockAPICallCounter) -> GitHubTransport {
      GitHubTransport(
        session: stubSession,
        tokenProvider: { "test-token" },
        callCounter: counter)
    }

    private func stub200(_ url: String, data: Data) {
      StubURLProtocol.register(.init(data: data, statusCode: 200, headers: [:]), for: url)
    }

    private var base: String { GitHubConstants.apiBase + "/" }

    // MARK: fetchRunners

    @Test("fetchRunners() increments counter once per successful HTTP response")
    func fetchRunnersIncrementsCounter() async {
      let counter = MockAPICallCounter()
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      stub200(url, data: Data("{\"runners\":[]}".utf8))
      _ = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
    }

    // MARK: fetchActiveRuns

    @Test("fetchActiveRuns() increments counter once per status query (2 total)")
    func fetchActiveRunsIncrementsTwice() async {
      let counter = MockAPICallCounter()
      let ps = GitHubConstants.activeRunsPageSize
      stub200(
        "\(base)orgs/\(org)/actions/runs?status=in_progress&per_page=\(ps)",
        data: Data("{\"workflow_runs\":[]}".utf8))
      stub200(
        "\(base)orgs/\(org)/actions/runs?status=queued&per_page=\(ps)",
        data: Data("{\"workflow_runs\":[]}".utf8))
      _ = await fetchActiveRuns(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 2)
    }

    // MARK: fetchJobs

    @Test("fetchJobs() increments counter once per successful HTTP response")
    func fetchJobsIncrementsCounter() async {
      let counter = MockAPICallCounter()
      let url =
        "\(base)repos/\(org)/myrepo/actions/runs/1/jobs?per_page=\(GitHubConstants.maxPageSize)"
      stub200(url, data: Data("{\"jobs\":[]}".utf8))
      _ = await fetchJobs(
        runID: 1, scope: .repo(owner: org, name: "myrepo"),
        transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
    }

    // MARK: fetchUserOrgs

    @Test("fetchUserOrgs() increments counter once per successful HTTP response")
    func fetchUserOrgsIncrementsCounter() async {
      let counter = MockAPICallCounter()
      let path = GitHubConstants.userOrgsPath.trimmingCharacters(in: .init(charactersIn: "/"))
      stub200("\(base)\(path)?per_page=\(GitHubConstants.maxPageSize)", data: Data("[]".utf8))
      _ = await fetchUserOrgs(transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
    }

    // MARK: fetchUserRepos

    @Test("fetchUserRepos() increments counter once per successful HTTP response")
    func fetchUserReposIncrementsCounter() async {
      let counter = MockAPICallCounter()
      let path = GitHubConstants.userReposPath.trimmingCharacters(in: .init(charactersIn: "/"))
      stub200(
        "\(base)\(path)?sort=updated&per_page=\(GitHubConstants.maxPageSize)",
        data: Data("[]".utf8))
      _ = await fetchUserRepos(transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
    }

    // MARK: non-2xx does not increment

    @Test("counter is not incremented on non-2xx response")
    func counterNotIncrementedOnHttpError() async {
      let counter = MockAPICallCounter()
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      StubURLProtocol.register(
        .init(data: Data("{\"message\":\"Not Found\"}".utf8), statusCode: 404, headers: [:]),
        for: url)
      _ = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 0)
    }

    // MARK: multi-page

    @Test("counter increments once per page for multi-page paginated responses")
    func counterIncrementsPerPage() async {
      let counter = MockAPICallCounter()
      let page1URL = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      let page2URL =
        "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)&page=2"
      StubURLProtocol.register(
        .init(
          data: Data(
            "[{\"id\":1,\"name\":\"r1\",\"status\":\"online\",\"busy\":false,\"labels\":[]}]".utf8),
          statusCode: 200,
          headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
        for: page1URL)
      StubURLProtocol.register(
        .init(
          data: Data(
            "[{\"id\":2,\"name\":\"r2\",\"status\":\"online\",\"busy\":false,\"labels\":[]}]".utf8),
          statusCode: 200, headers: [:]),
        for: page2URL)
      _ = await makeTransport(counter: counter).apiPaginated(
        "orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)")
      #expect(await counter.recordedCount == 2)
    }
  }
}
