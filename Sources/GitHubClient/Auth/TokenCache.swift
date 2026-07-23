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
//
// See also: GitHubClient.swift — also requires public import OAuthTokenKit
// independently, for its `public let oauthService: any OAuthServiceProtocol`
// property declaration. Both files have genuinely independent compiler reasons;
// neither import is redundant. Removing the import here does not satisfy the
// requirement in GitHubClient.swift, and vice versa.
public import EnvTokenKit
import Foundation
public import OAuthTokenKit
import Synchronization

// MARK: - TokenCache
//
// Resolution chain:
//   1. In-memory cache  (sync, free)
//   2. TokenStore       (sync, Keychain SecItemCopyMatching)
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
    /// Optional because diagnostics are never required for correctness — the cache
    /// functions identically with or without a logger. Callers that do not need
    /// diagnostic output pass `nil` (or omit the parameter; it defaults to `nil`).
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
    ///
    /// ## Why one Mutex for one field
    ///
    /// > Note: Migrated from PR #75 (EnvTokenKit/OAuthTokenKit extraction).
    /// > The original two-field struct `(token: String?, outcome: ShellResolutionOutcome)`
    /// > required a lock-ordering rationale because both fields were written in different
    /// > call paths (resolveFromStore wrote `token`, EnvTokenProvider wrote `outcome`),
    /// > creating a window where a reader could observe a partial update — a
    /// > deadlock-adjacent ordering issue documented in the original
    /// > `## Why one Mutex for both fields` block.
    /// > That rationale is obsolete: outcome tracking was moved to `EnvTokenProvider`
    /// > in PR #75 when the shell path was extracted into EnvTokenKit. `state` is now
    /// > a single `String?` field with one write path per operation (resolve or
    /// > invalidate). A single-field Mutex has no lock-ordering concern; the original
    /// > deadlock-window argument no longer applies.
    private let state = Mutex<String?>(nil)

    // MARK: - Initialisers

    /// Creates a new `TokenCache`.
    /// - Parameters:
    ///   - tokenStore: The backing store used to load/save/delete the token.
    ///   - envProvider: Resolves steps 3+4 (env var + login shell). In production
    ///     this is `EnvTokenProvider` constructed by `GitHubClient.swift`. In tests
    ///     pass a stub or `NullEnvTokenProvider`. Non-optional: env resolution is a
    ///     load-bearing step in the resolution chain; callers that do not need it
    ///     should pass `NullEnvTokenProvider()` explicitly rather than receiving a
    ///     nil-guarded no-op silently.
    ///   - logger: Optional logger for diagnostic messages. Optional because
    ///     diagnostics are never required for correctness — the cache functions
    ///     identically without one. Defaults to `nil`; existing call sites are
    ///     unaffected.
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
    /// Use this when env-var and login-shell resolution are not needed — for example,
    /// in `GitHubClient`'s test init when no env token path is under test. Pass a
    /// real `EnvTokenProviding` stub to the primary init when env resolution
    /// behaviour is under test.
    ///
    /// NOTE: this init is intentionally `internal`, not `private`. It is called
    /// from `GitHubClient.init(oauthService:transport:tokenCache:)` (the test init)
    /// when `tokenCache` is `nil` — that path lives in `GitHubClient.swift` within
    /// the same module, so `internal` is the correct access level. It is also
    /// reachable from `@testable import GitHubClient` test targets.
    /// Periphery will not flag it as dead code because it is referenced from
    /// `GitHubClient.swift` at the `tokenCache ?? TokenCache(tokenStore: NullTokenStore())`
    /// call site.
    ///
    /// - Parameter tokenStore: The backing token store.
    internal init(tokenStore: any TokenStore) {
        self.tokenStore = tokenStore
        self.envProvider = NullEnvTokenProvider()
        self.logger = nil  // intentional: store-only test path; diagnostics not needed
    }

    // MARK: - Public API

    /// Resolves and returns the best available token, caching the result in memory.
    ///
    /// Resolution order — first match wins:
    /// 1. **In-memory cache** — zero I/O; populated on first successful resolution.
    /// 2. **`TokenStore`** — one synchronous `SecItemCopyMatching` Keychain read.
    /// 3. **Env var + login shell** — delegated to the injected `EnvTokenProviding`.
    ///    For terminal/CI launches step 3 resolves from `ProcessInfo`; for cold
    ///    Finder/Dock launches step 4 spawns `/bin/zsh -i -l` to source shell
    ///    profile exports.
    ///
    /// A successful resolution at any step writes the result to the in-memory
    /// cache. All subsequent calls return from step 1 until `invalidate()` is
    /// called.
    ///
    /// ## Why `async` when steps 1–3 are synchronous
    /// Steps 1–3 are synchronous and return without ever suspending. The function
    /// is `async` solely because step 4 (`loginShellToken`, inside `EnvTokenProvider`)
    /// is unavoidably async — it uses `@concurrent` + `withTaskGroup` + `waitUntilExit()`.
    /// Swift does not allow a non-async function to call an async one. The cost of the
    /// `async` declaration on the warm path is a single actor-hop check — negligible
    /// compared to any Keychain or subprocess I/O.
    ///
    /// Returns `nil` if no token is available from any source.
    ///
    /// - Warning: Concurrent callers that all miss the in-memory cache simultaneously
    ///   (e.g. on first call at app launch) will each independently walk steps 2–4.
    ///   Steps 1–2 are idempotent (double Keychain read is harmless). Step 4 is not:
    ///   each concurrent miss spawns a separate `/bin/zsh` subprocess. The latch is
    ///   not set until `loginShellToken` returns — up to 10 seconds — so the window
    ///   spans the full shell execution time, not merely a scheduling instant. In
    ///   production this is rare because `GitHubClient` is a singleton and callers
    ///   are typically serialised through a single call site. If your call pattern
    ///   can produce high-concurrency first-calls, consider serialising the first
    ///   `token()` call yourself. See `EnvTokenProvider.token()` for the full
    ///   concurrent-spawn rationale.
    ///
    ///   Historical note: an `inFlight` lock was considered and rejected — it added
    ///   complexity for a window that is rare in practice and only occurs during a
    ///   cold Finder/Dock launch where the shell path fires. The thundering-herd
    ///   window is bounded by the shell startup time, not unbounded.
    public func token() async -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = await envProvider.token() {
            state.withLock { $0 = envToken }
            return envToken
        }
        return nil
    }

    /// Clears the in-memory token cache and resets the `EnvTokenProvider` shell
    /// outcome latch.
    ///
    /// ## Two-step atomicity window
    /// `invalidate()` performs two operations that cannot be made atomic without
    /// a shared lock between `TokenCache` and `EnvTokenProvider`:
    ///
    /// 1. `state.withLock { $0 = nil }` — clears the in-memory token cache.
    /// 2. `envProvider.invalidate()` — resets `EnvTokenProvider`'s shell latch.
    ///
    /// Between steps 1 and 2, a concurrent `token()` call that misses the cleared
    /// cache but hits the not-yet-reset shell latch could return a stale shell
    /// result. In practice this window is negligible: `RunnerPoller` is a serial
    /// actor and does not call `token()` concurrently with sign-out. If a future
    /// caller introduces concurrent access, either introduce a shared lock or
    /// document the accepted race.
    ///
    /// ## When invalidate() fires
    /// `invalidate()` is called from two paths in production:
    /// - **Sign-out**: `OAuthService.signOut()` → `onTokenDeleted` callback →
    ///   `TokenCache.invalidate()`. The Keychain entry has already been deleted
    ///   at this point; clearing the in-memory cache ensures the next `token()`
    ///   call re-walks the full resolution chain rather than returning a stale value.
    /// - **Sign-in**: `OAuthService.exchangeCode(_:)` → `onTokenSaved` callback →
    ///   `TokenCache.invalidate()`. The new token has just been written to the
    ///   Keychain; invalidating the cache forces the next `token()` call to re-read
    ///   it from the store rather than returning a value from the previous session.
    ///   The two-step atomicity window above therefore applies on sign-in as well
    ///   as sign-out — specifically during the window between a successful
    ///   `exchangeCode` write and the `envProvider.invalidate()` call here.
    public nonisolated func invalidate() {
        state.withLock { $0 = nil }
        envProvider.invalidate()
        logger?.log("TokenCache › invalidate — cache cleared", category: "transport")
    }

    // MARK: - Private helpers

    /// Returns the cached token if one is available, otherwise `nil`.
    private func resolveFromCache() -> String? {
        guard let cached = state.withLock({ $0 }) else {
            logger?.log("TokenCache › cache miss", category: "transport")
            return nil
        }
        logger?.log("TokenCache › cache hit (len=\(cached.count))", category: "transport")
        return cached
    }

    /// Attempts to resolve the token from the injected `TokenStore` (Keychain).
    /// On a hit, writes the result to the in-memory cache and returns it.
    /// On a miss (nil or empty string), returns nil.
    ///
    /// ## Why empty strings are rejected
    /// `KeychainTokenStore.load()` can return an empty string if the Keychain
    /// entry was written with an empty value (e.g. a corrupted save). An empty
    /// token is not a usable credential — returning it would cause every
    /// subsequent API call to fail with a 401. Rejecting it here forces the
    /// resolution chain to continue to the env-var / shell path, which is the
    /// correct fallback behaviour.
    ///
    /// The same empty-string rejection is applied in `OAuthService.isAuthenticated`
    /// (PR #75) for the same reason. Both rejections are intentional and symmetric.
    private func resolveFromStore() -> String? {
        guard let stored = tokenStore.load(), !stored.isEmpty else {
            logger?.log("TokenCache › store miss", category: "transport")
            return nil
        }
        logger?.log("TokenCache › store hit (len=\(stored.count)), writing to cache", category: "transport")
        state.withLock { $0 = stored }
        return stored
    }
}
