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

extension URLSession: URLSessionProtocol {}
