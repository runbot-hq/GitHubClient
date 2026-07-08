// MockURLSession.swift
// GitHubClientTests
// Lightweight URLSession subclass for intercepting token-exchange network calls in tests.
import Foundation

// MARK: - MockURLSession

/// A `URLSession` subclass that returns canned responses without touching the network.
///
/// Inject into `OAuthService(session:)` to test `exchangeCode` paths without real HTTP calls.
final class MockURLSession: URLSession {
    /// The result returned from the next `data(for:)` call.
    /// Set this before exercising a code path that triggers a network request.
    var stubbedResult: Result<Data, Error> = .success(Data())

    override func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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
