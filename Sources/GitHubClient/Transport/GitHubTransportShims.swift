// GitHubTransportShims.swift
// GitHubClient

import Foundation

// MARK: - Shared default instance

/// The process-wide default `GitHubTransport` instance.
///
/// Set once by `GitHubClient.init` to a fully token-wired instance before any
/// API calls are made. Declared `nonisolated(unsafe)` because it is written
/// exactly once at app launch — before any concurrent reads — satisfying the
/// same once-written invariant that `TransportBox` previously enforced with
/// `OSAllocatedUnfairLock`.
///
/// The setter is `internal(set)` so that only code within the `GitHubClient`
/// module (i.e. `GitHubClient.init`) can write it. External consumers get
/// read-only access, enforcing the once-written invariant structurally.
///
/// - Note: The initial `GitHubTransport()` value has `tokenProvider: nil`
///   and will silently return `.noToken` for any call made before
///   `GitHubClient.init` runs. This is intentional: it matches the previous
///   behaviour and is the correct degraded path before auth is wired.
///
/// - Warning: Do **not** reassign this after `GitHubClient.init` has run.
///   Tests should always pass `transport:` explicitly at the call site and
///   never rely on this global.
nonisolated(unsafe) public internal(set) var sharedGitHubTransport: GitHubTransport = GitHubTransport()

// MARK: - HTTP verb shims
//
// Call-site-compatible free functions delegating to `sharedGitHubTransport`.
// TODO(#1513-cleanup): remove each shim as its callers are migrated.

/// Sends a POST to `endpoint`. Returns response `Data` or `nil`.
/// - SeeAlso: ``GitHubTransport/post(_:body:timeout:)``
@concurrent
@discardableResult
public func urlSessionPost(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    await sharedGitHubTransport.post(endpoint, body: body, timeout: timeout)
}

/// Sends a PUT with `body` to `endpoint`. Returns response `Data` or `nil`.
/// - SeeAlso: ``GitHubTransport/put(_:body:timeout:)``
@concurrent
public func urlSessionPut(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    await sharedGitHubTransport.put(endpoint, body: body, timeout: timeout)
}

/// Sends a DELETE to `endpoint`. Returns `true` on 2xx.
/// - SeeAlso: ``GitHubTransport/delete(_:timeout:)``
@concurrent
@discardableResult
public func urlSessionDelete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    await sharedGitHubTransport.delete(endpoint, timeout: timeout)
}

// MARK: - Domain shims

/// Thin GET alias used widely across the module.
/// - SeeAlso: ``GitHubTransport/apiAsync(_:timeout:)``
///
/// Uses `@concurrent` (not `nonisolated(nonsending)`) because this calls
/// `sharedGitHubTransport.apiAsync` directly rather than a shim.
/// Consistent with all other domain shims in this file.
@concurrent
public func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await sharedGitHubTransport.apiAsync(endpoint, timeout: timeout)
}

/// Fire-and-forget POST alias. Returns `true` on 2xx.
/// - SeeAlso: ``GitHubTransport/post(_:body:timeout:)``
/// - Note: Intentionally discards response body (converts `Data?` → `Bool`).
///   Use the transport method directly if the body is needed.
/// - Note: Returns `Bool` (success/failure) rather than `Data?`. This is an intentional
///   lossy conversion — existing callers only care whether the POST succeeded. If the
///   response body ever becomes relevant, call `sharedGitHubTransport.post(_:)` directly.
@concurrent
@discardableResult
public func ghPost(_ endpoint: String) async -> Bool {
    let transport = sharedGitHubTransport
    let result = await transport.post(endpoint)
    let success = result != nil
    transport.logger?.log("ghPost › \(endpoint) success=\(success)", category: "transport")
    return success
}

/// Deregisters a runner from GitHub via DELETE.
/// - SeeAlso: ``GitHubTransport/deleteRunnerByID(scope:runnerID:)``
@concurrent
@discardableResult
public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    await sharedGitHubTransport.deleteRunnerByID(scope: scopeString, runnerID: runnerID)
}

/// Replaces all custom labels on a runner.
/// - SeeAlso: ``GitHubTransport/patchRunnerLabels(scope:runnerID:labels:)``
@concurrent
@discardableResult
public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    await sharedGitHubTransport.patchRunnerLabels(scope: scopeString, runnerID: runnerID, labels: labels)
}

/// Fetches a runner registration token.
/// - SeeAlso: ``GitHubTransport/fetchRegistrationToken(scope:)``
@concurrent
public func fetchRegistrationToken(scope scopeString: String) async -> String? {
    await sharedGitHubTransport.fetchRegistrationToken(scope: scopeString)
}

/// Fetches a runner removal token.
/// - SeeAlso: ``GitHubTransport/fetchRemovalToken(scope:)``
@concurrent
public func fetchRemovalToken(scope scopeString: String) async -> String? {
    await sharedGitHubTransport.fetchRemovalToken(scope: scopeString)
}

/// Cancels a workflow run.
/// - SeeAlso: ``GitHubTransport/cancelRun(runID:scope:)``
@concurrent
@discardableResult
public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    await sharedGitHubTransport.cancelRun(runID: runID, scope: scopeString)
}
