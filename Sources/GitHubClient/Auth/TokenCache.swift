// TokenCache.swift
// GitHubClient
import Foundation
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
    ///
    /// ## Boundary rule
    /// `TokenCache` must never import `EnvTokenKit` directly. The `internal import`
    /// of `EnvTokenKit` lives only in `GitHubClient.swift`; `TokenCache` accesses
    /// the kit solely through this protocol existential.
    private let envProvider: any EnvTokenProviding

    /// In-memory token cache guarded by a `Mutex`.
    ///
    /// `nil` means "not yet resolved this cache lifetime".
    /// Written by `resolveFromStore()` and the `envProvider` delegation block
    /// in `token()`. Reset to `nil` by `invalidate()`.
    ///
    /// ## Why the shell outcome latch moved out of this Mutex
    /// In the legacy inline path, `token` and `shellOutcome` were stored together
    /// so they could be reset atomically in `invalidate()`. Now that the shell
    /// latch lives inside `EnvTokenProvider` (behind its own `Mutex`), the two
    /// fields are no longer co-located — but atomicity is preserved: `invalidate()`
    /// calls `state.withLock { $0 = nil }` then `envProvider.invalidate()` in
    /// sequence. A window exists between the two calls where `state.token` is
    /// `nil` but `EnvTokenProvider`'s latch is not yet reset. This is safe:
    /// the only caller of `invalidate()` is `GitHubClient`'s `onTokenSaved` /
    /// `onTokenDeleted` callbacks, which run on the `@MainActor`; `token()` is
    /// not called again until after both resets complete.
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

    // MARK: - Public API

    /// Returns a GitHub personal access token from the first available source.
    ///
    /// Resolution order:
    /// 1. In-memory cache — zero I/O, returns immediately on warm cache
    /// 2. `TokenStore.load()` — synchronous Keychain read
    /// 3. `GH_TOKEN` / `GITHUB_TOKEN` process environment — covers terminal / CI launches
    ///    (delegated to the injected `EnvTokenProviding`)
    /// 4. Login shell subprocess — cold Finder/Dock/login-item launch only
    ///    (delegated to the injected `EnvTokenProviding`)
    ///
    /// ## Why `async` when steps 1–3 are synchronous
    /// Steps 1–3 are synchronous and return without ever suspending. The function
    /// is `async` solely because step 4 (`loginShellToken`) is unavoidably async —
    /// it uses `@concurrent` + `withTaskGroup` + `waitUntilExit()`. Swift does not
    /// allow a non-async function to call an async one. The cost of the `async`
    /// declaration on the warm path is a single actor-hop check — negligible
    /// compared to any Keychain or subprocess I/O.
    ///
    /// ## Shell latch policy
    /// The latch is owned by `EnvTokenProviding`. See `ShellResolutionOutcome`
    /// and `EnvTokenProvider.token()` in `EnvTokenKit` for the full per-case
    /// policy. In summary:
    /// - `.notAttempted`: shell is spawned normally.
    /// - `.notFound`: shell ran but found no export — NOT latched. Re-entry
    ///   allowed so a Finder-launch user who later adds `GH_TOKEN` is unblocked
    ///   without a relaunch.
    /// - `.failed`: shell timed out or failed to launch — IS latched until
    ///   `invalidate()` resets the latch via `envProvider.invalidate()`.
    ///
    /// ## Concurrent callers
    /// The thundering-herd window is documented in `EnvTokenProvider.token()`.
    /// In practice `RunnerPoller` is a single serial actor so at most one
    /// concurrent caller exists. External consumers calling `token()` from
    /// multiple tasks concurrently should be aware of the per-caller shell-spawn
    /// risk described there.
    ///
    /// Returns `nil` if no token is available from any source.
    public func token() async -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        // Delegate steps 3+4 to the injected provider.
        // EnvTokenProvider checks ProcessInfo first (step 3, sync), then
        // falls through to /bin/zsh only on a cold Finder/Dock launch (step 4).
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

    /// Returns the token that is currently held in the in-memory cache, or `nil`
    /// if no token has been resolved yet during this process lifetime.
    ///
    /// This is a **non-async, zero-I/O** read of the Mutex-guarded state — it
    /// will never spawn a login shell, read the Keychain, or check environment
    /// variables. It reflects only what a prior `token()` call has already
    /// resolved and written into the cache.
    ///
    /// ## Why this exists
    /// UI code (e.g. `SettingsView`) needs a synchronous answer to "do we have
    /// a token right now?" to decide which status indicator to show. Callers
    /// that need a fully-resolved token (including shell fallback) must still
    /// call `token()`. This property answers only: "has any prior resolution
    /// already succeeded?"
    public var cachedToken: String? {
        state.withLock { $0 }
    }

    // MARK: - Private helpers

    /// Returns the token from the in-memory cache, or `nil` if not yet populated.
    /// Fast path — no I/O, no subprocess.
    private func resolveFromCache() -> String? {
        let cached = state.withLock { $0 }
        #if DEBUG
        if let cached {
            logger?.log("TokenCache › resolved from cache (len=\(cached.count))", category: "transport")
        }
        #endif
        return cached
    }

    /// Loads the token from the `TokenStore` and populates the cache on success.
    /// Empty strings are treated as absent (e.g. corrupted Keychain entry).
    ///
    /// ## Cache-write side effect (not a pure read)
    /// Writes to `state` on success. Named `resolveFrom…` to signal the
    /// resolve-and-cache pattern; the write is the meaningful side-effect,
    /// not the return value.
    ///
    /// ## Why Keychain results are cached in memory
    /// `tokenStore.load()` is a synchronous Keychain read — a kernel call with
    /// non-trivial overhead on every invocation. `RunnerPoller` calls `token()`
    /// on every poll cycle (~30 s). Without the in-memory cache, every poll
    /// cycle would pay a Keychain round-trip even after the token is known.
    /// The cache is cleared by `invalidate()` on sign-out, so it never holds
    /// a stale token across a credential change.
    ///
    /// ## Thundering-herd window (intentional)
    /// Two concurrent callers that both miss the in-memory cache may both call
    /// `tokenStore.load()`. The `if $0 == nil` Mutex guard prevents a
    /// double-write; the double Keychain read is idempotent and cheaper than
    /// an extra init lock.
    private func resolveFromStore() -> String? {
        // The two failure modes (nil = no Keychain entry, empty = corrupted entry)
        // are deliberately collapsed into one guard. Both are treated identically:
        // return nil and fall through to the next resolution step. Separating them
        // into two guards with distinct log messages adds branching for a distinction
        // that has no actionable difference — the caller cannot recover differently
        // based on nil vs. empty. The log message below covers both cases; if field
        // diagnosis ever requires the distinction, split this guard at that point.
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
