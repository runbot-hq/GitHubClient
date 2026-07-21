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

/// Conformance of `URLSession` to `URLSessionProtocol`.
///
/// `URLSessionProtocol` is declared in this module (`OAuthTokenKit`), so
/// `@retroactive` does not apply — the compiler rejects it. This is a
/// standard same-module protocol conformance, not a retroactive one.
extension URLSession: URLSessionProtocol {}
