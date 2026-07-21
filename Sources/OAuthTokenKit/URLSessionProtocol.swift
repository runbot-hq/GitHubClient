// URLSessionProtocol.swift
// OAuthTokenKit
// Migrated from: Sources/GitHubClient/Auth/URLSessionProtocol.swift
import Foundation

// MARK: - URLSessionProtocol

/// Minimal seam over `URLSession` so tests can inject a fake without subclassing.
///
/// `URLSession.data(for:)` is declared in a Foundation extension and is therefore
/// not `open` — it cannot be overridden in a subclass defined outside the module.
/// Using a protocol instead avoids that restriction entirely.
public protocol URLSessionProtocol: Sendable {
    /// Fetches the contents of a URL request and returns the data.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

// MARK: - URLSession + URLSessionProtocol

/// Retroactive conformance of `URLSession` to `URLSessionProtocol`.
///
/// Note: unlike the original `GitHubClient` version of this file, this IS a
/// retroactive conformance — the protocol (`URLSessionProtocol`) is declared
/// in `OAuthTokenKit` while `URLSession` is declared in `Foundation`. Swift
/// requires `@retroactive` here to acknowledge that we own neither type. The
/// conformance is safe: `URLSession.data(for:)` already exists as a Foundation
/// method; we are only declaring that `URLSession` satisfies a protocol we define.
extension URLSession: @retroactive URLSessionProtocol {}
