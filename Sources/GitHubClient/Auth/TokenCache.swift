// TokenCache.swift
// GitHubClient

// public import — not internal import — is required here because TokenCache is a
// public type whose initialisers name EnvTokenProviding (from EnvTokenKit) and
// TokenStore (from OAuthTokenKit) directly in their public parameter lists.
// Swift's access-control rule: a public declaration cannot use a type that is
// imported as internal. Changing either import to `internal import` produces:
//   error: initializer cannot be declared public because its parameter uses an internal type
// The alternative — making TokenCache internal — would remove it from the
// GitHubClient public API, which breaks callers who construct TokenCache in tests.
// `public import` re-exports EnvTokenKit and OAuthTokenKit as part of the
// GitHubClient module surface; that is an intentional, unavoidable consequence
// of keeping TokenCache public with protocol-typed parameters.
public import EnvTokenKit
import Foundation
public import OAuthTokenKit
import Synchronization

// MARK: - TokenCache
//
// Thread-safe in-memory cache for the resolved GitHub token.
// Populated on first successful resolution and cleared by invalidate().
// Backed by Synchronization.Mutex for synchronous, lock-guarded access.
//
// token() is async. On every call it walks a linear resolution chain:
//   1. in-memory cache  (sync, no I/O)
//   2. TokenStore       (sync Keychain read)
//   3. ProcessInfo env  (sync, covers terminal / CI launches)
//   4. loginShellToken  (async subprocess — cold Finder launch only)
//
// Steps 3+4 are fully delegated to the injected `any EnvTokenProviding`.
// TokenCache never names the concrete EnvTokenProvider type — it only
// knows the protocol. The concrete type is constructed and injected
// exclusively by GitHubClient.swift at wiring time.
//
// After a successful resolution the result is written to the in-memory
// cache and all subsequent calls return immediately from step 1.
// invalidate() clears the token cache and calls envProvider.invalidate()
// so the shell outcome latch in EnvTokenProvider is also reset.

/// A token cache that resolves from an injected `TokenStore` and an injected
/// `EnvTokenProviding`, in that order, and caches the result in memory.
/// All cache reads and writes are guarded by a `Mutex` for thread safety.
public final class TokenCache: Sendable {

    /// An injected `TokenStore` used to persist the token to the keychain.
    private let tokenStore: any TokenStore
    /// An optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?

    /// Injected env+shell token provider.
    ///
    /// `token()` delegates steps 3+4 of the resolution chain to this provider.
    /// `TokenCache` never names the concrete `EnvTokenProvider` type — it only
    /// knows `any EnvTokenProviding`. The concrete type is constructed and
    /// injected exclusively by `GitHubClient.swift`.
    private let envProvider: any EnvTokenProviding

    /// In-memory token cache guarded by a `Mutex`.
    ///
    /// `nil` means "not yet resolved this cache lifetime".
    /// Written by `resolveFromStore()` and the `envProvider` delegation block
    /// in `token()`. Reset to `nil` by `invalidate()`.
    private let state = Mutex<String?>(nil)

    // MARK: - Initialisers

    /// Creates a new `TokenCache`.
    /// - Parameters:
    ///   - tokenStore: The backing store used to load/save/delete the token.
    ///   - envProvider: Resolves steps 3+4 (env var + login shell). In production
    ///     this is `EnvTokenProvider` constructed by `GitHubClient.swift`. In tests
    ///     pass a stub or `NullEnvTokenProvider`.
    ///   - logger: Optional logger for diagnostic messages.
    public init(
        tokenStore: any TokenStore,
        envProvider: any EnvTokenProviding,
        logger: (any GitHubLogger)? = nil
    ) {
        self.tokenStore = tokenStore
        self.envProvider = envProvider
        self.logger = logger
    }

    /// Creates a `TokenCache` backed by the given store with a `NullEnvTokenProvider`.
    ///
    /// Convenience for tests that only exercise the Keychain / store path and
    /// do not need env-var or shell resolution. Pass a real `EnvTokenProviding`
    /// stub to the primary init when env resolution behaviour is under test.
    ///
    /// - Parameter tokenStore: The backing token store.
    public init(tokenStore: any TokenStore) {
        self.tokenStore = tokenStore
        self.envProvider = NullEnvTokenProvider()
        self.logger = nil
    }

    // MARK: - Public API

    /// Returns a GitHub personal access token from the first available source.
    ///
    /// Resolution order:
    /// 1. In-memory cache — zero I/O, returns immediately on warm cache
    /// 2. `TokenStore.load()` — synchronous Keychain read
    /// 3. `GH_TOKEN` / `GITHUB_TOKEN` process environment — covers terminal / CI launches
    /// 4. Login shell subprocess — cold Finder/Dock/login-item launch only
    ///
    /// Returns `nil` if no token is available from any source.
    public func token() async -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = await envProvider.token() {
            state.withLock { if $0 == nil { $0 = envToken } }
            return envToken
        }
        return nil
    }

    /// Clears the in-memory token cache and resets the injected provider's state.
    ///
    /// Call after saving a new token or after sign-out so the next `token()`
    /// call re-resolves from the store or shell.
    public func invalidate() {
        state.withLock { $0 = nil }
        envProvider.invalidate()
        logger?.log("TokenCache › invalidate — cache cleared, envProvider reset", category: "transport")
    }

    // MARK: - Synchronous cache peek

    /// Returns the token currently held in the in-memory cache, or `nil` if not yet resolved.
    ///
    /// Zero-I/O synchronous read — never spawns a shell, reads the Keychain,
    /// or checks environment variables.
    public var cachedToken: String? {
        state.withLock { $0 }
    }

    // MARK: - Private helpers

    /// Returns the cached token without any I/O, or `nil` if the cache is cold.
    private func resolveFromCache() -> String? {
        let cached = state.withLock { $0 }
        #if DEBUG
        if let cached {
            logger?.log("TokenCache › resolved from cache (len=\(cached.count))", category: "transport")
        }
        #endif
        return cached
    }

    /// Loads the token from the `TokenStore`, populates the cache on success, and returns it.
    ///
    /// Empty strings are treated as absent (corrupted Keychain entry).
    private func resolveFromStore() -> String? {
        guard let token = tokenStore.load(), !token.isEmpty else {
            #if DEBUG
            logger?.log("TokenCache › token store returned nil or empty", category: "transport")
            #endif
            return nil
        }
        #if DEBUG
        logger?.log("TokenCache › resolved from store (len=\(token.count)), populating cache", category: "transport")
        #endif
        state.withLock { if $0 == nil { $0 = token } }
        return token
    }
}

// MARK: - NullEnvTokenProvider

/// A no-op `EnvTokenProviding` used when no env provider is needed.
///
/// Injected by `TokenCache.init(tokenStore:)` (the test convenience init)
/// when the caller does not supply a real provider. Always returns `nil`
/// from `token()` and ignores `invalidate()` calls.
private struct NullEnvTokenProvider: EnvTokenProviding {
    /// Always returns `nil` — no env var or shell resolution is performed.
    func token() async -> String? { nil }
    /// No-op — there is no state to reset.
    func invalidate() {}
}
