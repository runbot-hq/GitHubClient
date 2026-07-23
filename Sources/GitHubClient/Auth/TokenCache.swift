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
    ///   each concurrent miss spawns a separate `/bin/zsh` subprocess. The window is
    ///   the full execution time of the shell (100–300 ms in practice), not merely a
    ///   scheduling instant. In production this is rare because `GitHubClient` is a
    ///   singleton and callers are typically serialised through a single call site.
    ///   If your call pattern can produce high-concurrency first-calls, consider
    ///   serialising the first `token()` call yourself.
    ///
    ///   Historical note: an `inFlight` lock was considered and rejected — it added
    ///   complexity for a window that is rare in practice and only occurs during a
    ///   cold Finder/Dock launch where the shell path fires. The thundering-herd
    ///   window is bounded by the shell startup time, not unbounded.
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
    ///
    /// Resetting `envProvider` here is intentional: a sign-out / sign-in cycle
    /// should get exactly one fresh shell attempt on the next `token()` call,
    /// even if the previous attempt timed out. Without this reset the user would
    /// be permanently locked out of the shell path for the process lifetime after
    /// a single `.failed` outcome, regardless of whether they subsequently fix
    /// their `~/.zshrc` or reduce its startup cost.
    ///
    /// Note the latency cost on `.failed` reset: the re-spawned shell adds
    /// ~50–200 ms to the first poll cycle after sign-out on an affected launch
    /// configuration. This cost recurs on every sign-out cycle (each `invalidate()`
    /// resets the outcome), not just once per process lifetime. It is cached
    /// immediately on success, so only the first `token()` call after each
    /// `invalidate()` pays the penalty.
    public func invalidate() {
        state.withLock { $0 = nil }
        envProvider.invalidate()
        logger?.log("TokenCache › invalidate — cache cleared, envProvider reset", category: "transport")
    }

    // MARK: - Synchronous cache peek

    /// Returns the token currently held in the in-memory cache, or `nil` if not yet resolved.
    ///
    /// This is a non-async, zero-I/O read of the Mutex-guarded state — it will never
    /// spawn a login shell, read the Keychain, or check environment variables. It reflects
    /// only what `token()` has already resolved and cached in this `TokenCache` instance.
    ///
    /// ## Why this exists
    /// UI code (e.g. `SettingsView`) needs a synchronous answer to "do we have a token
    /// right now?" to decide which status indicator to show. Calling the async `token()`
    /// from a synchronous SwiftUI view body is not possible without a detached Task, which
    /// would introduce a frame of latency and a potential flicker. `cachedToken` provides
    /// an instant, non-suspending read of whatever the last `token()` resolution produced.
    /// If the cache is cold (e.g. first launch before the first `token()` call completes),
    /// it returns `nil` and the UI shows a neutral / loading state until the async resolution
    /// fires and triggers a state update.
    // Migrated from TokenCache.swift: ## Why this exists block restored in PR #75 review pass.
    // The block was dropped without a // Migrated: annotation, violating #73/#74 rule 7.
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
    /// Empty strings are treated as absent (e.g. corrupted Keychain entry).
    ///
    /// ## Cache-write side effect (not a pure read)
    /// Writes to `state` on success. Named `resolveFrom…` to signal the
    /// resolve-and-cache pattern; the write is the meaningful side-effect,
    /// not the return value.
    ///
    /// ## Why the two failure modes are collapsed
    /// Both `nil` (no Keychain entry) and empty string (corrupted entry) are
    /// treated identically: return nil and fall through to the next resolution
    /// step. Separating them into two guards with distinct log messages adds
    /// branching for a distinction that has no actionable difference — the caller
    /// cannot recover differently based on nil vs. empty. The log message below
    /// covers both cases; if field diagnosis ever requires the distinction, split
    /// this guard at that point.
    ///
    /// ## Why Keychain results are cached in memory
    /// Each `TokenStore.load()` call performs a synchronous `SecItemCopyMatching`
    /// read. On a cold RunnerPoller tick (every ~30 s) this fires once and caches
    /// immediately — negligible cost. Caching is still the right choice because
    /// a tight render loop or a burst of concurrent API calls would otherwise
    /// issue multiple redundant Keychain reads. The cache is intentionally
    /// invalidated by `invalidate()` (called on sign-in and sign-out) so external
    /// token revocation is reflected on the next cycle, not indefinitely masked.
    ///
    /// > Note: Migrated from PR #75 — thundering-herd rationale moved to
    /// > the `token()` `-Warning:` block above.
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
///
/// Access level: `internal` — visible within the `GitHubClient` module only
/// (including `@testable`-importing test targets such as `GitHubClientTests`).
/// `internal` does NOT cross module boundaries: code in `EnvTokenKit`,
/// `OAuthTokenKit`, or any other separately compiled module cannot reference
/// this type. If an `EnvTokenKit` test target ever attempts to use it, the
/// compiler will produce a "cannot find type" error. The doc comment's
/// intended audience is `GitHubClientTests` via `@testable import GitHubClient`.
internal struct NullEnvTokenProvider: EnvTokenProviding {
    /// Always returns `nil` — no env var or shell resolution is performed.
    func token() async -> String? { nil }
    /// No-op — there is no state to reset.
    nonisolated func invalidate() {}
}
