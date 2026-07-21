// TokenStore.swift
// OAuthTokenKit
import Foundation

// MARK: - TokenStore

/// Abstraction over a persistent store that saves, loads, and deletes a single
/// GitHub OAuth access token.
///
/// Adopters are responsible for all serialisation and error handling. The protocol
/// does not model partial failure — callers treat a `nil` load as "no token" and a
/// `false` save/delete as a best-effort failure (see `KeychainTokenStore` for the
/// full error-handling rationale).
///
/// `Sendable` is required because `TokenCache` stores `any TokenStore` as a `let`
/// property on a `Sendable` type and accesses it from async contexts.
public protocol TokenStore: Sendable {
    /// Returns the stored token, or `nil` if none is present or an error occurs.
    func load() -> String?
    /// Saves the given token, returning `true` on success.
    @discardableResult func save(_ token: String) -> Bool
    /// Deletes the stored token, returning `true` on success or if not found.
    @discardableResult func delete() -> Bool
}

// MARK: - NullTokenStore

/// A no-op `TokenStore` that always returns `nil` / `false`.
///
/// Used by `GitHubClient`'s test init to satisfy the `TokenCache` init
/// without touching the real Keychain.
public struct NullTokenStore: TokenStore, Sendable {
    public init() {}
    public func load() -> String? { nil }
    @discardableResult public func save(_ token: String) -> Bool { false }
    @discardableResult public func delete() -> Bool { false }
}
