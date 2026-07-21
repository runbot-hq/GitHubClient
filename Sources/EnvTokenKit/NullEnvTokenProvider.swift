// NullEnvTokenProvider.swift
// EnvTokenKit

// MARK: - NullEnvTokenProvider

/// A no-op `EnvTokenProviding` used as the default `envProvider` for
/// `TokenCache` in test contexts where no env-var or shell resolution is needed.
///
/// Always returns `nil` from `token()` and is a no-op for `invalidate()`.
/// Mirrors the pattern of `NullTokenStore` in `OAuthTokenKit`.
///
/// ## Why `public`
/// `GitHubClient`'s test init resolves a `nil` `tokenCache` argument to
/// `TokenCache(tokenStore: NullTokenStore(), envProvider: NullEnvTokenProvider())`.
/// Both `GitHubClient` and downstream test targets that import `EnvTokenKit`
/// must be able to construct this type, so `public` is required.
public struct NullEnvTokenProvider: EnvTokenProviding, Sendable {
    /// Creates a new `NullEnvTokenProvider`.
    public init() {}
    /// Always returns `nil` — no token is resolved.
    public func token() async -> String? { nil }
    /// No-op — no state to reset.
    public func invalidate() {}
}
