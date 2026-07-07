// GitHubRequestBuilder.swift
// GitHubClient
import Foundation

// swiftlint:disable:next missing_docs
private let slashCharacterSet = CharacterSet(charactersIn: "/")

// MARK: - URL helpers

/// Resolves an endpoint string to a full GitHub API URL string.
public func resolveURL(_ endpoint: String) -> String {
    endpoint.hasPrefix("http") ? endpoint : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: slashCharacterSet))"
}

// MARK: - Request factories

/// Builds a `URLRequest` with headers common to all GitHub API calls.
// swiftlint:disable:next missing_docs
private func makeBaseRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Builds a `URLRequest` with the `application/vnd.github+json` Accept header.
public func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
}

/// Builds a `URLRequest` with the `application/vnd.github.v3.raw` Accept header.
/// Uses `application/vnd.github.v3.raw` to request raw file/log content from the GitHub API.
/// GitHub's log endpoints issue an S3 redirect; URLSession follows it automatically,
/// and the redirect preserves this Accept header so the S3 response is the raw bytes.
public func makeRawRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
    return req
}
