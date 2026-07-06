// GitHubTransportShims.swift
// GitHubClient

import Foundation

// MARK: - Process-wide transport instance

/// The process-wide default transport instance.
///
/// Set once by `GitHubClient.init` at app launch before any API calls are made.
/// Declared `nonisolated(unsafe)` because it is written exactly once — before
/// any concurrent reads — satisfying the once-written invariant.
///
/// Deprecated in favour of `currentTransport`. Will be removed once
/// `AppDelegate` is migrated to scope via `withTransport(_:operation:)` (see #25).
@available(*, deprecated, renamed: "currentTransport")
nonisolated(unsafe) public internal(set) var sharedGitHubTransport: any GitHubTransportProtocol = GitHubTransport()

// MARK: - @TaskLocal transport

/// Task-local storage for the transport override.
///
/// Implicitly `nil` by default — `nil` is a value-type constant and is safe to
/// freeze at module load. The public `currentTransport` computed property
/// resolves `nil` to `sharedGitHubTransport` at access time, picking up the
/// live authenticated instance wired by `GitHubClient.init`.
///
/// Do not read this directly. Use `currentTransport` or `withTransport(_:operation:)`.
@TaskLocal private var _taskLocalTransport: (any GitHubTransportProtocol)?

/// The effective transport for the current task.
///
/// Returns the innermost `withTransport` override if one is in scope;
/// otherwise falls back to `sharedGitHubTransport` — the live authenticated
/// instance wired by `GitHubClient.init` — evaluated at call time.
///
/// All 9 shims and 3 domain helpers in this module read `currentTransport`
/// directly and require no changes.
public var currentTransport: any GitHubTransportProtocol {
    _taskLocalTransport ?? sharedGitHubTransport
}

/// Scopes a transport override to the current task and all child tasks.
///
/// Use in tests to inject a mock without touching any global:
/// ```swift
/// await withTransport(MockTransport()) {
///     let orgs = await fetchUserOrgs()
/// }
/// ```
///
/// The `@Sendable` closure and `T: Sendable` bound are required because
/// `$_taskLocalTransport.withValue` crosses task boundaries under strict
/// concurrency checking.
public func withTransport<T: Sendable>(
    _ transport: any GitHubTransportProtocol,
    operation: @Sendable () async throws -> T
) async rethrows -> T {
    try await $_taskLocalTransport.withValue(transport, operation: operation)
}

// MARK: - HTTP verb shims
//
// Call-site-compatible free functions delegating to `currentTransport`.
// TODO(#1513-cleanup): remove each shim as its callers are migrated.

/// Sends a POST to `endpoint`. Returns response `Data` or `nil`.
@concurrent
@discardableResult
public func urlSessionPost(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    await currentTransport.post(endpoint, body: body, timeout: timeout)
}

/// Sends a PUT with `body` to `endpoint`. Returns response `Data` or `nil`.
@concurrent
public func urlSessionPut(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    await currentTransport.put(endpoint, body: body, timeout: timeout)
}

/// Sends a DELETE to `endpoint`. Returns `true` on 2xx.
@concurrent
@discardableResult
public func urlSessionDelete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    await currentTransport.delete(endpoint, timeout: timeout)
}

// MARK: - Domain shims

/// Thin GET alias used widely across the module.
@concurrent
public func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await currentTransport.apiAsync(endpoint, timeout: timeout)
}

/// Fire-and-forget POST alias. Returns `true` on 2xx.
@concurrent
@discardableResult
public func ghPost(_ endpoint: String) async -> Bool {
    let transport = currentTransport
    let result = await transport.post(endpoint)
    let success = result != nil
    transport.logger?.log("ghPost › \(endpoint) success=\(success)", category: "transport")
    return success
}

/// Deregisters a runner from GitHub via DELETE.
@concurrent
@discardableResult
public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    await currentTransport.deleteRunnerByID(scope: scopeString, runnerID: runnerID)
}

/// Replaces all custom labels on a runner.
@concurrent
@discardableResult
public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    await currentTransport.patchRunnerLabels(scope: scopeString, runnerID: runnerID, labels: labels)
}

/// Fetches a runner registration token.
@concurrent
public func fetchRegistrationToken(scope scopeString: String) async -> String? {
    await currentTransport.fetchRegistrationToken(scope: scopeString)
}

/// Fetches a runner removal token.
@concurrent
public func fetchRemovalToken(scope scopeString: String) async -> String? {
    await currentTransport.fetchRemovalToken(scope: scopeString)
}

/// Cancels a workflow run.
@concurrent
@discardableResult
public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    await currentTransport.cancelRun(runID: runID, scope: scopeString)
}
