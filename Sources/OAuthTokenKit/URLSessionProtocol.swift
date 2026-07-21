// URLSessionProtocol.swift
// OAuthTokenKit
import Foundation

/// Protocol abstraction over `URLSession` to enable injecting mock sessions in tests.
///
/// Only the `data(for:)` method is required — this is the only `URLSession` call
/// made by `OAuthService` during the token exchange. Additional methods can be
/// added here if future network operations require them.
public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
