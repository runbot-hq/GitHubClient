// URLSessionProtocol.swift
// GitHubClient
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
/// `URLSessionProtocol` is declared in this module (`OAuthTokenKit`), so
/// `@retroactive` does not apply here — Swift only requires that annotation
/// when *neither* the protocol nor the conforming type is defined in the
/// current module. `URLSession` is from Foundation; the protocol is ours.
/// The conformance is safe: `URLSession.data(for:)` already exists as a
/// Foundation method; we are only declaring that `URLSession` satisfies a
/// protocol we define.
extension URLSession: URLSessionProtocol {}
