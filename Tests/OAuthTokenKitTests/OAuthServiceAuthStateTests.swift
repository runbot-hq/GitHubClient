// OAuthServiceAuthStateTests.swift
// OAuthTokenKitTests
//
// Exercises `OAuthService.isAuthenticated` and `OAuthService.hasAnyToken`.
//
// ⚠️ ISOLATION REQUIREMENT
// `hasAnyToken` reads `ProcessInfo.processInfo.environment` directly.
// `setenv`/`unsetenv` mutate the process-global environment, so this suite
// is `.serialized` and every env-var test wraps its body in `withCleanEnv`.
//
// Keychain is never touched: token store operations are exercised through a
// `MockTokenStore`, keeping these tests sandboxing-free and safe to run with
// `swift test`.

import Foundation
import Testing

@testable import OAuthTokenKit

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
///
/// ⚠️ SERIALIZED DEPENDENCY: `setenv`/`unsetenv` mutate the process-global
/// environment. Correctness relies on the `@Suite(.serialized)` attribute on
/// `OAuthServiceAuthStateTests`.
///
/// Uses `getenv()` (not `ProcessInfo.processInfo.environment`) for save/restore
/// because `ProcessInfo` captures a snapshot at process start and does not
/// reflect live `setenv`/`unsetenv` mutations. `getenv()` always reflects the
/// current state of the process environment.
private func withCleanEnv(_ body: () -> Void) {
    let prevGH = getenv("GH_TOKEN").flatMap { String(cString: $0) }
    let prevGitHub = getenv("GITHUB_TOKEN").flatMap { String(cString: $0) }
    unsetenv("GH_TOKEN")
    unsetenv("GITHUB_TOKEN")
    body()
    if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
    if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

// MARK: - OAuthServiceAuthStateTests

@Suite("OAuthServiceAuthState", .serialized)
@MainActor
struct OAuthServiceAuthStateTests {

    /// Builds an `OAuthService` backed by an (optionally seeded) `MockTokenStore`.
    private func makeService(storeToken: String? = nil) -> OAuthService {
        OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: MockTokenStore(initial: storeToken)
        )
    }

    // MARK: - isAuthenticated

    /// `isAuthenticated` is `false` when the token store is empty.
    @Test func isAuthenticated_noToken_returnsFalse() {
        let service = makeService()
        #expect(service.isAuthenticated == false)
    }

    /// `isAuthenticated` is `true` when the token store holds a valid token.
    @Test func isAuthenticated_withToken_returnsTrue() {
        let service = makeService(storeToken: "oauth-token-xyz")
        #expect(service.isAuthenticated == true)
    }

    // MARK: - hasAnyToken

    /// `hasAnyToken` is `false` when the store is empty and no env var is set.
    @Test func hasAnyToken_noSource_returnsFalse() {
        withCleanEnv {
            let service = makeService()
            #expect(service.hasAnyToken == false)
        }
    }

    /// `hasAnyToken` is `true` when `isAuthenticated` is true (store has a token),
    /// even with no env var set.
    @Test func hasAnyToken_oauthToken_returnsTrue() {
        withCleanEnv {
            let service = makeService(storeToken: "oauth-token")
            #expect(service.hasAnyToken == true)
        }
    }

    /// `hasAnyToken` is `true` when `GH_TOKEN` is set in the environment,
    /// even when the token store is empty (`isAuthenticated == false`).
    ///
    /// This is the env-var fallback path described in `OAuthService.hasAnyToken`.
    /// It is exercised by the CI runner via the `GH_TOKEN: test-ci-token` env
    /// var injected in `.github/workflows/swift-test.yml`.
    @Test func oauthService_hasAnyToken_envVarFallback() {
        withCleanEnv {
            setenv("GH_TOKEN", "test-ci-token", 1)
            let service = makeService()  // empty store — isAuthenticated == false
            // GH_TOKEN is set → hasAnyToken must return true via the env-var branch.
            #expect(service.hasAnyToken == true)
        }
    }

    /// `hasAnyToken` is `true` when `GITHUB_TOKEN` is set and `GH_TOKEN` is absent.
    @Test func hasAnyToken_githubTokenEnvVar_returnsTrue() {
        withCleanEnv {
            setenv("GITHUB_TOKEN", "github-env-token", 1)
            let service = makeService()
            #expect(service.hasAnyToken == true)
        }
    }
}
