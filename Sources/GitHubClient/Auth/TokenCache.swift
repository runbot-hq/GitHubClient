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
// The shell is spawned at most once per cache lifetime for a .failed outcome
// (timeout, launch error). A .notFound outcome (shell healthy, no export)
// does NOT latch — the shell path is re-entered on the next token() call.
// After a successful resolution the result is written to the in-memory cache
// and all subsequent calls return immediately from step 1.
// invalidate() resets all state so a sign-out / sign-in cycle gets a fresh attempt.

// MARK: - ShellResolutionOutcome

/// Records the outcome of the most recent login-shell resolution attempt.
///
/// Stored inside `TokenCache.state` alongside the cached token so both fields
/// are read and written atomically under the same `Mutex`.
///
/// ## Why an enum instead of a Bool
/// The previous `shellFailed: Bool` flag collapsed two semantically distinct
/// outcomes — "shell ran but found no export" and "shell failed to launch or
/// timed out" — into a single latch. Both set the flag to `true`, permanently
/// blocking re-entry for the process lifetime. That is correct for `.failed`
/// (retrying a broken shell every 30 s is wasteful) but wrong for `.notFound`
/// (an OAuth-only user who later adds `GH_TOKEN` to their profile should not
/// need a relaunch to pick it up). The enum makes the policy explicit:
/// only `.failed` latches; `.notFound` allows re-entry on the next call.
private enum ShellResolutionOutcome {
    /// No shell attempt has been made yet this cache lifetime.
    case notAttempted
    /// The shell launched and ran successfully but found no `GH_TOKEN` or
    /// `GITHUB_TOKEN` export. The shell path is NOT latched — `token()` will
    /// re-enter it on the next call, allowing the user to add an export
    /// without relaunching the app.
    ///
    /// ## Why not collapse this into `.notAttempted`
    /// Observable behaviour is identical today: both cases allow re-entry.
    /// The distinction is preserved for two reasons:
    /// 1. Diagnostics — logging and future telemetry can distinguish "never
    ///    tried" from "tried and found nothing", which helps triage user
    ///    reports without needing a separate flag.
    /// 2. Future policy — a `.notFound`-specific cooldown (e.g. re-enter at
    ///    most once per 60 s rather than on every poll cycle) could be added
    ///    here without a schema change. Collapsing to `.notAttempted` would
    ///    require a new case or a separate field at that point.
    ///
    /// ## Poll cost for Finder-launch users with no token export
    /// Any Finder-launch user with no `GH_TOKEN` export — OAuth-only users
    /// included — reaches this path on every poll cycle (~30 s) and re-spawns
    /// `/bin/zsh`. This is a known accepted cost: the shell exits quickly
    /// (~50–200 ms on a light config) and the user is unblocked the moment
    /// they add an export without relaunching. The cooldown described in
    /// point 2 above is the right long-term fix and is a schema-free addition
    /// when the cost proves unacceptable in practice.
    ///
    /// ## Why .notFound is NOT latched like .failed
    /// Any Finder-launch user with no `GH_TOKEN` export — OAuth-only users
    /// included — reaches this path on every poll cycle. The decision not to
    /// latch is deliberate: latching `.notFound` like `.failed` would prevent
    /// a user who later adds an export from picking it up without a
    /// sign-out/sign-in cycle, defeating the feature's core promise.
    /// OAuth users launched from a terminal do NOT reach step 4 (step 3
    /// resolves from `ProcessInfo`), but OAuth users launched from Finder
    /// with no export DO. The per-cycle shell cost is real and acknowledged;
    /// the cooldown in issue #68 is the right bounded mitigation — not a
    /// session latch that silently breaks the UX for the users this feature
    /// is designed to help.
    case notFound  // TODO: #68 — add a timestamp-based cooldown so .notFound does not re-spawn /bin/zsh on every poll cycle (~30 s) for Finder-launch users with no token export
    /// The shell timed out, failed to launch, or was blocked by the App Sandbox.
    /// The shell path IS latched — `token()` short-circuits before step 4 on
    /// every subsequent call until `invalidate()` resets the outcome.
    /// Retrying a broken or sandbox-blocked shell every poll cycle (~30 s)
    /// would be a persistent background thread burn with no benefit; the user
    /// must take explicit action (fix `~/.zprofile`, remove the sandbox
    /// entitlement, or sign in via OAuth) before a retry is useful.
    case failed
}

/// A token cache that resolves from an injected `TokenStore` and/or environment variables,
/// falling back to a login shell subprocess on a cold GUI-app launch.
/// All cache reads and writes are guarded by a `Mutex` for thread safety.
public final class TokenCache: Sendable {

    /// An injected `TokenStore` used to persist the token to the keychain.
    private let tokenStore: any TokenStore
    /// An optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?

    /// Combined cache state guarded by a single `Mutex`.
    ///
    /// Both fields are mutated together so reads and writes are always consistent:
    /// - `token`: the resolved token, or `nil` if not yet populated.
    /// - `shellOutcome`: tracks the result of the last login-shell attempt.
    ///   See `ShellResolutionOutcome` for the per-case latch policy.
    ///
    /// ## Why one Mutex for both fields
    /// `token` and `shellOutcome` are always read and mutated as a pair:
    /// `token()` reads `shellOutcome` then writes one or the other, and
    /// `invalidate()` resets both atomically. Two separate locks would require
    /// lock-ordering discipline to prevent deadlock, and would expose an
    /// inconsistent intermediate state where `token` is cleared but
    /// `shellOutcome` is still `.failed` — permanently blocking the shell path
    /// after sign-out until the second lock was also cleared. One lock is
    /// simpler and eliminates that window entirely.
    private let state = Mutex<(token: String?, shellOutcome: ShellResolutionOutcome)>(
        (token: nil, shellOutcome: .notAttempted)
    )

    /// Creates a new `TokenCache`.
    /// - Parameters:
    ///   - tokenStore: The backing store used to load/save/delete the token.
    ///   - logger: Optional logger for diagnostic messages.
    public init(tokenStore: any TokenStore, logger: (any GitHubLogger)? = nil) {
        self.tokenStore = tokenStore
        self.logger = logger
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
    /// is `async` solely because step 4 (`loginShellToken`) is unavoidably async —
    /// it uses `@concurrent` + `withTaskGroup` + `waitUntilExit()`. Swift does not
    /// allow a non-async function to call an async one. The cost of the `async`
    /// declaration on the warm path is a single actor-hop check — negligible
    /// compared to any Keychain or subprocess I/O.
    ///
    /// ## Shell latch policy
    /// Step 4 behaviour depends on the outcome of the last shell attempt:
    /// - `.notAttempted`: shell is spawned normally.
    /// - `.notFound`: shell ran but found no export — NOT latched. Step 4 is
    ///   re-entered on the next call. An OAuth-only user who later adds
    ///   `GH_TOKEN` to their shell profile is unblocked without a relaunch.
    /// - `.failed`: shell timed out, failed to launch, or was blocked by the
    ///   App Sandbox — IS latched. Step 4 is short-circuited on every
    ///   subsequent call until `invalidate()` resets the outcome. Retrying a
    ///   broken shell every poll cycle (~30 s) would burn a background thread
    ///   for no benefit; the user must take explicit action first.
    ///
    /// Transient OS blips (`ENOMEM` at launch etc.) are covered by the `.failed`
    /// latch — the user would need to sign out and back in or relaunch. This is
    /// an accepted trade-off tracked in issue #68.
    ///
    /// ## Why retrying `.failed` on every call is not the answer
    /// A timed backoff would add a timestamp field and timer logic that exists
    /// solely for a condition the user must fix manually anyway. The chosen
    /// policy matches user mental model: act (fix `~/.zprofile`, sign in via
    /// OAuth), then the next sign-out/sign-in cycle resets via `invalidate()`.
    ///
    /// For GUI app launches from Finder/Dock/login items, `launchd` does not source
    /// `~/.zprofile` or `~/.zshrc`, so `ProcessInfo` does not contain `GH_TOKEN`.
    /// Step 4 bridges that gap by spawning `/bin/zsh -i -l` which sources those files.
    ///
    /// Returns `nil` if no token is available from any source (user is signed out,
    /// no env var, no shell export, or shell previously timed out or failed to launch).
    ///
    /// - Warning: Concurrent callers that simultaneously miss all fast paths (steps 1–3)
    ///   will each spawn a separate `/bin/zsh` subprocess. The `.failed` latch check and
    ///   the write-back to `state.token` are separate Mutex lock calls — there is no
    ///   atomic "check-and-enter" operation. This means the latch is NOT set until
    ///   `loginShellToken` returns (which can take up to 10 s on timeout), so the
    ///   window where multiple callers can each independently enter the shell path spans
    ///   the full execution time of the shell, not just a scheduling instant. Correctness
    ///   is preserved (the `if $0.token == nil` Mutex guard in the write-back prevents a
    ///   double-write), but any number of concurrent callers can each spawn a separate
    ///   `/bin/zsh` process simultaneously. In the app, `RunnerPoller` is a single serial
    ///   actor so this never fires in practice. External consumers calling `token()`
    ///   concurrently from multiple tasks should be aware of this.
    ///
    ///   An earlier iteration defended this with a `Mutex<Bool>`-protected
    ///   `warmUpInFlight` flag and a `withTaskGroup` timeout scaffold. That was
    ///   intentionally removed: it added a second Mutex, a waiting task, and a
    ///   timeout-within-a-timeout to guard a scenario that cannot occur today
    ///   (`RunnerPoller` is serial). If a future caller genuinely needs
    ///   concurrent-safe shell resolution, the right fix is a single
    ///   `OSAllocatedUnfairLock<Bool>`-protected in-flight flag here — not
    ///   re-introducing `warmUp()`.
    public func token() async -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = resolveFromEnvironment() { return envToken }
        // Short-circuit if the shell previously failed (timeout / launch error /
        // App Sandbox). .notFound does NOT short-circuit — re-entry is allowed so
        // a Finder-launch user who later adds GH_TOKEN is unblocked without relaunching.
        // See ShellResolutionOutcome and the -Warning: block above for the full
        // concurrent-caller window: the latch is not set until loginShellToken
        // returns, which can take up to 10 s — not just a scheduling instant.
        if case .failed = state.withLock({ $0.shellOutcome }) { return nil }
        // All fast paths missed — cold Finder/Dock/login-item launch.
        // Spawn the login shell to source ~/.zprofile and ~/.zshrc.
        // This suspends for ~50–200 ms on the first call; the result is
        // cached and all subsequent calls return from step 1 above.
        // ⚠️ No atomic entry claim: concurrent callers each spawn a separate
        // /bin/zsh — the latch is not set until loginShellToken returns.
        // Safe today (RunnerPoller is serial); see -Warning: above for the
        // full window and the fix if a concurrent caller is ever added.
        let shellResult = await loginShellToken(logger: logger)
        switch shellResult {
        case .found(let value):
            state.withLock { if $0.token == nil { $0.token = value } }
            return value
        case .notFound:
            // Shell ran fine but no token was exported. Record the outcome but
            // do NOT write to state.token — `nil` in the token field means
            // "not yet populated" and is the signal for all callers to continue
            // down the resolution chain. There is no way to cache a nil result
            // to skip re-entry; the shellOutcome field is the lightweight signal
            // that the shell was already tried. This is intentionally asymmetric
            // with the .found case, which does write state.token.
            // Do NOT latch — allow re-entry. See ShellResolutionOutcome.notFound.
            state.withLock { $0.shellOutcome = .notFound }
            return nil
        case .failed:
            // Shell timed out, failed to launch, or was blocked by the sandbox.
            // Latch to prevent re-spawning on every poll cycle. See .failed.
            state.withLock { $0.shellOutcome = .failed }
            return nil
        }
    }

    /// Clears the in-memory token cache and resets the shell outcome to `.notAttempted`.
    ///
    /// Call after saving a new token or after sign-out so the next `token()`
    /// call re-resolves from the store or shell.
    ///
    /// Resetting `shellOutcome` here is intentional: a sign-out / sign-in cycle
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
        state.withLock { $0 = (token: nil, shellOutcome: .notAttempted) }
        logger?.log("TokenCache › invalidate — cache and shell outcome reset", category: "transport")
    }

    // MARK: - Private helpers

    /// Returns the token from the in-memory cache, or `nil` if not yet populated.
    /// Fast path — no I/O, no subprocess.
    private func resolveFromCache() -> String? {
        let cached = state.withLock { $0.token }
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
    /// Writes to `state.token` on success. Named `resolveFrom…` to signal the
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
    /// `tokenStore.load()`. The `if $0.token == nil` Mutex guard prevents a
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
        state.withLock { if $0.token == nil { $0.token = token } }
        return token
    }

    /// Reads `GH_TOKEN` or `GITHUB_TOKEN` from the process environment and
    /// populates the cache on success.
    ///
    /// Returns `nil` for Finder/Dock/login-item launches — `launchd` does not
    /// source shell profiles, so the token is absent from `ProcessInfo`.
    /// `token()` falls through to the login shell (step 4) in that case.
    ///
    /// ## Cache-write side effect (not a pure read)
    /// Same resolve-and-cache pattern as `resolveFromStore()`.
    ///
    /// ## Why env tokens are cached in memory
    /// Process environment variables are immutable for the lifetime of a process —
    /// `setenv` mutations are possible but no caller of `TokenCache` does this.
    /// Caching the result avoids a `ProcessInfo.processInfo.environment` dictionary
    /// lookup (a lock-guarded NSDictionary copy under the hood) on every `token()`
    /// call, and keeps the resolution behaviour consistent with the store path.
    /// If the env ever changes mid-process (not expected), `invalidate()` flushes
    /// the cache and the next `token()` call re-reads from the environment.
    private func resolveFromEnvironment() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let envValue = ProcessInfo.processInfo.environment[key], !envValue.isEmpty {
                #if DEBUG
                logger?.log("TokenCache › resolved from env var \(key) (len=\(envValue.count)), populating cache", category: "transport")
                #endif
                state.withLock { if $0.token == nil { $0.token = envValue } }
                return envValue
            }
            #if DEBUG
            logger?.log("TokenCache › env var \(key): nil/empty", category: "transport")
            #endif
        }
        return nil
    }
}
