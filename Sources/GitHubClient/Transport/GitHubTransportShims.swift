// GitHubTransportShims.swift
// GitHubClient

import Foundation

// MARK: - @TaskLocal transport

/// The task-local default transport used by all API free functions.
///
/// In production, `GitHubClient.init` sets this via `sharedGitHubTransport` (deprecated
/// alias below) until the host app is migrated to scope it via
/// `$currentTransport.withValue(transport) { ... }` at the root task.
///
/// In tests, override per-task without touching any global:
/// ```swift
/// await $currentTransport.withValue(MockTransport()) {
///     let orgs = await fetchUserOrgs()
/// }
/// ```
@TaskLocal public var currentTransport: any GitHubTransportProtocol = GitHubTransport()

// MARK: - Deprecated global alias

/// Deprecated. Use `currentTransport` instead.
///
/// Kept temporarily so `GitHubClient.init` and host app call sites continue
/// to compile while the migration to `$currentTransport.withValue` is in progress.
/// Will be removed once `AppDelegate` is updated (see #25).
@available(*, deprecated, renamed: "currentTransport")
nonisolated(unsafe) public internal(set) var sharedGitHubTransport: GitHubTransport = GitHubTransport() {
    didSet { currentTransport = sharedGitHubTransport }
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
