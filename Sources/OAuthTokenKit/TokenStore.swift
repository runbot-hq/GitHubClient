// TokenStore.swift
// OAuthTokenKit
import Foundation

// MARK: - TokenStore

/// Injectable abstraction over a persistent token storage mechanism.
///
/// Conforming types must be `Sendable` and implement all three operations
/// as `nonisolated` so they can be called from any actor domain.
///
/// `Sendable` is required because `TokenCache` stores `any TokenStore` as a `let`
/// property on a `Sendable` type and accesses it from async contexts.
public protocol TokenStore: Sendable {
    /// Loads the token from storage. Returns `nil` if no token is stored.
    nonisolated func load() -> String?

    /// Saves `token` to storage. Returns `true` on success.
    ///
    /// - Important: `OAuthService` calls this after a successful token exchange but holds
    ///   no reference to any `TokenCache`. If you need the cache invalidated after a save,
    ///   pass an `onTokenSaved` closure to `GitHubClient.init` — it is called automatically
    ///   after every successful `save()`. Without it the cache will continue serving the
    ///   pre-sign-in `nil` until the process restarts.
    @discardableResult nonisolated func save(_ token: String) -> Bool

    /// Deletes the token from storage. Returns `true` on success or if not found.
    ///
    /// - Important: Deletion is **best-effort**. `OAuthService.signOut()` always clears
    ///   the in-memory cache (`onTokenDeleted`) and emits the sign-out stream, regardless
    ///   of this return value. A `false` return is logged but does not block sign-out.
    ///
    ///   Implementations **must** return `true` when the item is already absent
    ///   (not-found is a success). Return `false` only on a genuine storage error.
    @discardableResult nonisolated func delete() -> Bool
}

// MARK: - NullTokenStore

/// A no-op `TokenStore` used as the default backing store for `GitHubClient`'s
/// test init. Always returns `nil` from `load()` and reports success for
/// `save(_:)` and `delete()` without touching any persistent storage.
///
/// ## Why this is in Sources, not Tests
/// `GitHubClient`'s test init resolves a `nil` `tokenCache` argument to
/// `TokenCache(tokenStore: NullTokenStore())` inside the init body. Because
/// that expression is in a function body (not a default argument value), the
/// `public` visibility is required so both `GitHubClient` and its test targets
/// can construct it without a test-target dependency.
public struct NullTokenStore: TokenStore, Sendable {
    public init() {}
    /// Always returns `nil` — no token is stored.
    public nonisolated func load() -> String? { nil }
    /// Discards the token and reports success.
    @discardableResult public nonisolated func save(_ token: String) -> Bool { true }
    /// No-ops and reports success — nothing to delete.
    @discardableResult public nonisolated func delete() -> Bool { true }
}
