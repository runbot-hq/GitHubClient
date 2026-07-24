// NullEnvTokenProvider.swift
// GitHubClient

import EnvTokenKit

// MARK: - NullEnvTokenProvider

/// A no-op `EnvTokenProviding` implementation that always returns `nil` from
/// `token()` and does nothing in `invalidate()`.
///
/// Used by `TokenCache.init(tokenStore:)` (the test-convenience init) when
/// no env-var or login-shell resolution is needed — parallel to `NullTokenStore`.
///
/// ## When to use
/// Pass `NullEnvTokenProvider()` (or omit the `envProvider:` parameter and
/// let `TokenCache.init(tokenStore:)` construct it implicitly) when the test
/// under construction does not exercise env-var or shell-path token resolution.
/// For tests that do exercise those paths, use `StubEnvTokenProvider` or
/// `EnvReadingStubProvider` from the test target instead.
///
/// ## Why internal, not public
/// `NullEnvTokenProvider` is a test-support type for `GitHubClient`'s own
/// secondary init. It is not part of the library's public API and should not
/// be vended to downstream consumers. Public env-provider stubs belong in a
/// dedicated `GitHubClientTestSupport` product if that is ever added.
struct NullEnvTokenProvider: EnvTokenProviding {
    func token() async -> String? { nil }
    nonisolated func invalidate() {}
}
