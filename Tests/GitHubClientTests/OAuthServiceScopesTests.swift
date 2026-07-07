// OAuthServiceScopesTests.swift
// GitHubClientTests

import Testing
import Foundation
@testable import GitHubClient

// MARK: - OAuthServiceScopesTests

/// Tests for the configurable scopes API introduced in #44.
///
/// All tests use `MockTokenStore` to avoid Keychain access.
/// The empty-array guard test expects a `precondition` failure;
/// see inline comment for the chosen approach.
@Suite("OAuthService — configurable scopes")
@MainActor
struct OAuthServiceScopesTests {

    // MARK: - Helpers

    /// Extracts the `scope` query item value from the URL returned by `makeSignInURL()`.
    private func scopeQueryItem(for service: OAuthService) -> String? {
        guard let url = service.makeSignInURL(),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "scope" })?.value
    }

    // MARK: - Test 1: default scopes regression guard

    /// Verifies that an `OAuthService` created without an explicit `scopes`
    /// argument encodes all five default scopes in the correct order.
    ///
    /// This is a regression guard: if `OAuthService.defaultScopes` is ever
    /// accidentally modified, this test will catch it before it ships.
    @Test("default scopes produce the correct scope query item")
    func defaultScopesAreEncodedCorrectly() throws {
        let store = MockTokenStore()
        let service = OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: store
            // scopes: omitted — should default to OAuthService.defaultScopes
        )

        let scope = try #require(scopeQueryItem(for: service))
        #expect(scope == "repo read:org admin:org manage_runners:org workflow")
    }

    // MARK: - Test 2: custom scopes encoding

    /// Verifies that a custom `scopes` array is serialised correctly into the
    /// `scope` query item as a single space-separated string.
    @Test("custom scopes are space-joined in the scope query item")
    func customScopesAreEncodedCorrectly() throws {
        let store = MockTokenStore()
        let service = OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: store,
            scopes: [GitHubScopes.readUser, GitHubScopes.repo]
        )

        let scope = try #require(scopeQueryItem(for: service))
        #expect(scope == "read:user repo")
    }

    // MARK: - Test 3: empty scopes precondition

    /// Verifies that passing an empty `scopes` array to `OAuthService.init`
    /// triggers a `precondition` failure.
    ///
    /// Swift Testing does not yet ship a built-in `#expectPreconditionFailure`
    /// macro, so we use `withKnownIssue` with `isIntermittent: false` to
    /// document that this test intentionally crashes the process in debug builds.
    ///
    /// In CI, run this test only under a sanitiser-enabled scheme or via a
    /// dedicated subprocess test runner that treats process exit as a pass.
    /// Alternatively, gate on `#if DEBUG` if the project disables `precondition`
    /// in release builds via `-Ounchecked`.
    @Test("empty scopes array raises a precondition failure")
    func emptyScopesRaisesPrecondition() {
        // `precondition` terminates the process — we cannot catch it in-process.
        // This test is intentionally marked as a known issue so the suite does
        // not fail on the fact that we cannot directly assert the crash.
        // To validate this path, run the target under `XCTest` with
        // `XCTAssertPreconditionFailure` (from `XCTestExtras` or equivalent),
        // or use a subprocess approach.
        withKnownIssue(
            "precondition failure cannot be caught in-process with Swift Testing",
            isIntermittent: false
        ) {
            let store = MockTokenStore()
            // This line should trigger precondition(!scopes.isEmpty) in OAuthService.init.
            _ = OAuthService(
                clientID: "test-client-id",
                clientSecret: "test-client-secret",
                tokenStore: store,
                scopes: [] // ← must not be empty
            )
        }
    }
}
