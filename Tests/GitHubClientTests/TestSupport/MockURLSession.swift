// MockURLSession.swift
// GitHubClientTests
// Lightweight URLSessionProtocol conformer for intercepting token-exchange network calls in tests.
import Foundation
import GitHubClient

// MARK: - MockURLSession

/// A `URLSessionProtocol` conformer that returns canned responses without touching the network.
///
/// Inject into `OAuthService(session:)` to test `exchangeCode` paths without real HTTP calls.
/// Uses a protocol instead of subclassing `URLSession` because `data(for:)` is declared in
/// a Foundation extension and is not `open`, making it impossible to override outside the module.
final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    /// The result returned from the next `data(for:)` call.
    /// Set this before exercising a code path that triggers a network request.
    var stubbedResult: Result<Data, Error> = .success(Data())

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        switch stubbedResult {
        case .success(let data):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://github.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}
