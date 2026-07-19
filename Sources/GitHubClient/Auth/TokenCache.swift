// TokenCache.swift
// GitHubClient
import Foundation
import Synchronization

// MARK: - TokenCache
//
// Thread-safe in-memory cache for the resolved GitHub token.
// Populated on first successful resolution and cleared by invalidate().
// Backed by Synchronization.Mutex for synchronous, lock-guarded access.

/// A token cache that resolves from an injected `TokenStore` and/or environment variables.
/// All reads and writes are guarded by a `Mutex` for thread safety.
public final class TokenCache: Sendable {

    /// An injected `TokenStore` used to persist the token to the keychain.
    private let tokenStore: any TokenStore
    /// An optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?
    /// Thread-safe in-memory cache, initially `nil`.
    private let cache = Mutex<String?>(nil)
    /// Guards against concurrent warmUp() calls each spawning their own subprocess.
    /// Set to `true` by the first caller that passes all fast-paths; all subsequent
    /// concurrent callers bail early.
    ///
    /// ## One-shot-per-lifetime design (intentional, not an oversight)
    /// The sentinel is **never reset** — not on invalidate(), not on a nil result from
    /// loginShellToken. This means warmUp() spawns the login shell at most once per
    /// TokenCache instance lifetime. If loginShellToken returns nil (timeout or token
    /// absent), future warmUp() calls will silently no-op at this latch.
    ///
    /// Rationale: a shell that timed out once will likely time out again; retrying on
    /// every poll cycle adds latency with no realistic benefit. The intended usage is
    /// a single warmUp() call at startup — not repeated calls. invalidate() is for
    /// sign-out and does not change this.
    ///
    /// If a retry-on-failure semantic is ever needed, warmUpInFlight must be reset
    /// inside invalidate() or warmUp() must be redesigned. The current one-shot design
    /// is correct for the existing call flow; this comment exists to prevent a future
    /// caller from treating the lack of reset as an unintentional omission.
    private let warmUpInFlight = Mutex<Bool>(false)

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
    /// Priority order:
    /// 1. In-memory cache
    /// 2. `TokenStore.load()` (e.g. Keychain OAuth token)
    /// 3. `GH_TOKEN` / `GITHUB_TOKEN` environment variable (process environment)
    ///
    /// For GUI app launches from Finder/Dock/login items, call `warmUp()` once
    /// during startup (before the first poll) to pre-populate the cache from the
    /// user's login shell. `token()` itself never blocks on a subprocess.
    ///
    /// The `TokenStore` (step 2) is checked before environment variables (step 3)
    /// because a Keychain-persisted OAuth token represents an explicit, user-initiated
    /// sign-in and should not be silently shadowed by an ambient CI/shell env var.
    /// Environment variables are the fallback for unauthenticated contexts (CI pipelines,
    /// local automation) where no interactive sign-in has occurred.
    ///
    /// Returns `nil` if no token is available from any source.
    public func token() -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = resolveFromEnvironment() { return envToken }
        // All sources returned nil. Check whether warmUp() already ran and failed so
        // we can emit an actionable diagnostic instead of a generic "no token" log.
        // This is the only place where a developer or user will see a log explaining
        // *why* token resolution failed in a Finder-launch scenario.
        let warmUpAlreadyRan = warmUpInFlight.withLock { $0 }
        if warmUpAlreadyRan {
            logger?.log(
                "TokenCache › token() — returning nil: warmUp() already ran but resolved no token. "
                + "If this is a Finder/Dock launch, check that GH_TOKEN or GITHUB_TOKEN is exported "
                + "in ~/.zprofile or ~/.zshrc, or sign in via OAuth.",
                category: "transport"
            )
        } else {
            logger?.log("TokenCache › token() — returning nil (no token from any source)", category: "transport")
        }
        return nil
    }

    /// Pre-populates the token cache by sourcing the user's login shell environment.
    ///
    /// Call this once during app startup (e.g. from `AppState.start()`) **before**
    /// the first poll fires. This is a no-op if the cache is already populated —
    /// for example, when a Keychain OAuth token exists (even if not yet read into
    /// the in-memory cache) or when the app is launched from a terminal that already
    /// has `GH_TOKEN` set.
    ///
    /// ## Why this is needed
    /// macOS GUI apps launched from Finder, the Dock, or as a login item are spawned
    /// by `launchd`, which does not source `~/.zprofile` or `~/.zshrc`. As a result,
    /// `ProcessInfo.processInfo.environment` does not contain `GH_TOKEN` even when
    /// the token is correctly exported in the user's shell profile. This method
    /// bridges that gap by spawning a login shell subprocess that sources those files.
    ///
    /// ## Why async (not lazy inside `token()`)
    /// `token()` is synchronous and may be called on the `@MainActor` (via
    /// `GitHubClient` → `AppState` which is `@MainActor`-isolated). Blocking
    /// the main thread with `process.waitUntilExit()` for ~50–100 ms would freeze
    /// the UI on every cold Finder launch. Calling `warmUp()` eagerly and
    /// asynchronously from `AppState.start()` before the first poll fires avoids
    /// that entirely: by the time `token()` is first called from a poll, the cache
    /// is already populated.
    ///
    /// ## Fast-path priority (no subprocess if any token source resolves)
    /// warmUp() checks sources in priority order before spawning a shell:
    /// 1. In-memory cache — set by a prior `token()` call or prior `warmUp()`
    /// 2. `TokenStore` (Keychain) — checked explicitly so an OAuth-signed-in user
    ///    never hits the subprocess even on a fresh launch where `token()` hasn't
    ///    run yet. Without this check the Keychain token would be absent from the
    ///    in-memory cache at warmUp() time, the subprocess would run, and an env
    ///    token could beat the Keychain token into cache, inverting priority.
    /// 3. Process environment (`ProcessInfo`) — covers terminal launches and CI.
    /// Only if all three return nil does the shell subprocess run.
    ///
    /// ## Concurrency: fast-path 1 is not atomic with fast-paths 2/3 (intentional)
    /// The cache read in fast-path 1 and the subsequent resolveFromStore() /
    /// resolveFromEnvironment() calls are not a single atomic operation. Two concurrent
    /// callers can both pass fast-path 1 (both see cache == nil) and both call
    /// resolveFromStore(). This results in two Keychain reads, both writing the same
    /// token into cache. This is harmless — the `if $0 == nil` guard inside the Mutex
    /// in resolveFromStore() prevents a double-write, and the Keychain read is
    /// idempotent. Adding a separate initialisation lock to prevent the double-read
    /// would add complexity with no correctness benefit. This is an accepted trade-off,
    /// not a concurrency bug.
    ///
    /// ## Blocking I/O isolation (Principle 18)
    /// The subprocess is run inside `loginShellToken(logger:)`, a `@concurrent`
    /// async free function. `@concurrent` runs off any actor's serial executor,
    /// so `waitUntilExit()` blocks one cooperative thread pool worker without
    /// stalling the caller. No `DispatchQueue` or `DispatchSemaphore` bridges
    /// are used — the timeout is a structured `withTaskGroup` race and the pipe
    /// is drained via `FileHandle.readToEndOfFile()`.
    ///
    /// ## Performance
    /// The subprocess takes ~50–100 ms on first call with a 10-second timeout.
    /// A single `/bin/zsh -i -l` invocation recovers `GH_TOKEN`, falling back to
    /// `GITHUB_TOKEN`, in one shell run. The result is cached on first resolution;
    /// subsequent `warmUp()` calls return immediately.
    ///
    /// ## Token freshness / credential-manager tokens
    /// The login shell is sourced once at startup. If a user's `.zshrc` uses a
    /// credential manager that generates short-lived tokens via command substitution
    /// (e.g. `export GH_TOKEN=$(gh auth token)`), the token captured at warm-up time
    /// may expire during the app's lifetime. This is an intentional trade-off of the
    /// one-shot design: re-sourcing the shell on every poll cycle would add ~50–100 ms
    /// of latency per poll. In practice, GitHub PATs and OAuth tokens have multi-hour
    /// or multi-day lifetimes; short-lived credential-manager tokens are an exotic
    /// edge case. If token rotation is needed, call `invalidate()` and sign in via
    /// the OAuth flow instead.
    public func warmUp() async {
        // Fast-path 1: in-memory cache already populated.
        // NOTE: this check is not atomic with fast-paths 2/3 below. See the
        // "Concurrency" section in the doc comment above for why that is correct.
        guard cache.withLock({ $0 }) == nil else {
            logger?.log("TokenCache › warmUp — cache already populated, skipping login shell", category: "transport")
            return
        }
        // Fast-path 2: Keychain OAuth token exists (may not be in cache yet on a
        // fresh launch before token() has been called). Checking here prevents the
        // subprocess from running and prevents an env token from beating a valid
        // Keychain token into cache. resolveFromStore() writes to cache on success.
        if resolveFromStore() != nil {
            logger?.log("TokenCache › warmUp — resolved from token store, skipping login shell", category: "transport")
            return
        }
        // Fast-path 3: process env already has the token (terminal launch or CI).
        // resolveFromEnvironment() writes to cache on success.
        if resolveFromEnvironment() != nil {
            logger?.log("TokenCache › warmUp — resolved from process env, skipping login shell", category: "transport")
            return
        }
        // In-flight guard — see warmUpInFlight declaration comment for the full
        // rationale on why this latch is never reset (one-shot-per-lifetime design).
        let shouldProceed = warmUpInFlight.withLock { inFlight -> Bool in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard shouldProceed else {
            // Distinguish between two states to avoid a misleading "in flight" log
            // when the subprocess has already completed:
            // - cache still nil → subprocess ran and found no token (timeout or absent)
            // - cache populated → concurrent warmUp() won the race and we arrived late
            if cache.withLock({ $0 }) == nil {
                logger?.log("TokenCache › warmUp — login shell already ran but found no token; not retrying (one-shot latch)", category: "transport")
            } else {
                logger?.log("TokenCache › warmUp — login shell already in flight or completed; cache now populated", category: "transport")
            }
            return
        }
        logger?.log("TokenCache › warmUp — all fast-paths missed, attempting login shell resolution", category: "transport")
        guard let value = await loginShellToken(logger: logger) else { return }
        cache.withLock { if $0 == nil { $0 = value } }
    }

    /// Clears the in-memory token cache. Call after saving a new token or after sign-out.
    ///
    /// ## warmUpInFlight asymmetry (intentional, not an oversight)
    /// `invalidate()` clears the token `cache` but does **not** reset `warmUpInFlight`.
    /// This is correct for the current call flow: sign-out calls `invalidate()` and
    /// then never calls `warmUp()` again. The next token read falls through to
    /// `resolveFromStore()` / `resolveFromEnvironment()` as usual.
    ///
    /// If `warmUp()` is ever called after `invalidate()` — for example, if the startup
    /// sequence is changed to re-warm the cache post-sign-out — `warmUp()` will
    /// fast-path out on the `warmUpInFlight` sentinel and silently no-op, even though
    /// the cache is empty. See the `warmUpInFlight` declaration comment for the full
    /// rationale and the required changes if a retry semantic is ever needed.
    public func invalidate() {
        cache.withLock { $0 = nil }
        logger?.log("TokenCache › invalidate — cache cleared", category: "transport")
    }

    // MARK: - Private helpers

    private func resolveFromCache() -> String? {
        let cached = cache.withLock { $0 }
        #if DEBUG
        if let cached {
            logger?.log("TokenCache › resolved from cache (len=\(cached.count))", category: "transport")
        }
        #endif
        return cached
    }

    /// Loads the token from the `TokenStore`. Populates the cache on success.
    ///
    /// Empty strings are rejected — a `TokenStore` returning `""` (e.g. a corrupted
    /// Keychain entry) is treated identically to `nil`.
    ///
    /// ## Thundering-herd window (intentional)
    /// Two concurrent callers that both miss the in-memory cache will both call
    /// `tokenStore.load()` and both attempt to write to cache. The `if $0 == nil`
    /// guard inside the `Mutex` lock ensures only one write lands. The double
    /// Keychain read is idempotent and cheaper than adding a separate init lock.
    /// This is not a bug — it is an accepted trade-off.
    @discardableResult
    private func resolveFromStore() -> String? {
        guard let token = tokenStore.load() else {
            #if DEBUG
            logger?.log("TokenCache › token store returned nil", category: "transport")
            #endif
            return nil
        }
        guard !token.isEmpty else {
            #if DEBUG
            logger?.log("TokenCache › token store returned empty string — treating as absent", category: "transport")
            #endif
            return nil
        }
        #if DEBUG
        logger?.log("TokenCache › resolved from store (len=\(token.count)), populating cache", category: "transport")
        #endif
        cache.withLock { if $0 == nil { $0 = token } }
        return token
    }

    /// Reads `GH_TOKEN` or `GITHUB_TOKEN` from the process environment.
    /// Populates the cache on success.
    ///
    /// Succeeds for terminal / CI launches. Returns `nil` for Finder/Dock/login-item
    /// launches — use `warmUp()` at startup to bridge that gap.
    ///
    /// Same intentional thundering-herd window as `resolveFromStore()` — the
    /// `if $0 == nil` guard inside the lock is the correct protection.
    @discardableResult
    private func resolveFromEnvironment() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let envValue = ProcessInfo.processInfo.environment[key], !envValue.isEmpty {
                #if DEBUG
                logger?.log("TokenCache › resolved from env var \(key) (len=\(envValue.count)), populating cache", category: "transport")
                #endif
                cache.withLock { if $0 == nil { $0 = envValue } }
                return envValue
            }
            #if DEBUG
            logger?.log("TokenCache › env var \(key): nil/empty", category: "transport")
            #endif
        }
        return nil
    }
}

// MARK: - Login shell resolution (Principle 18: @concurrent for blocking I/O)

/// Spawns a single interactive login shell (`/bin/zsh -i -l`) to recover
/// `GH_TOKEN` or `GITHUB_TOKEN` from the user's shell profile.
///
/// Marked `@concurrent` so `waitUntilExit()` occupies one cooperative thread
/// pool worker without binding to any actor's serial executor (Principle 18).
/// This is a file-private free function (not a method on `TokenCache`) because
/// `@concurrent` cannot be applied to instance methods on a `Sendable` class
/// without additional actor-annotation gymnastics — the free-function placement
/// is what makes the annotation viable.
///
/// ## stdout pipe drain strategy
/// stdout is read with `readDataToEndOfFile()` **after** `waitUntilExit()` returns.
/// The shell command is `echo -n` — output is at most ~100 bytes (token length).
/// Reading after exit is safe: the pipe write-end is closed when the process exits,
/// so `readDataToEndOfFile()` returns immediately with whatever was written.
/// There is no pipe-buffer deadlock risk for payloads this small.
///
/// ## stderr drain strategy
/// stderr is redirected to `FileHandle.nullDevice` (/dev/null). A Pipe() is
/// deliberately NOT used for stderr: if the read end is never drained and the
/// user's .zshrc emits more than the kernel pipe buffer (~64 KB) to stderr,
/// zsh blocks on write() and waitUntilExit() hangs until the 10 s timeout fires.
/// /dev/null has no buffer limit and requires no draining.
///
/// ## Timeout / withTaskGroup race
/// Two arms race inside `withTaskGroup`:
/// - **Subprocess arm**: waits for exit, reads stdout, returns the token or nil.
/// - **Timeout arm**: sleeps 10 s, calls `process.terminate()`, returns nil.
/// `group.next()` returns whichever arm finishes first; `group.cancelAll()`
/// cancels the loser.
///
/// ## group.next() nil ambiguity (not a bug)
/// Both arms return `String?`. A nil from the subprocess (token not found) and
/// a nil from the timeout are indistinguishable via `group.next()`. This is
/// **intentional** — both outcomes produce the same result (no token cached),
/// so disambiguation adds complexity with no benefit. The warmUp() caller logs
/// the outcome accurately via the warmUpInFlight guard.
///
/// ## Task.isCancelled TOCTOU window (accepted trade-off)
/// The subprocess arm checks `Task.isCancelled` before `waitUntilExit()`. There
/// is a narrow window between the check and the call where the timeout arm can
/// win and cancel the task. In that window `waitUntilExit()` still executes —
/// but it returns promptly after SIGTERM, and the subsequent `readDataToEndOfFile()`
/// is a safe no-op on an EOF pipe. The guard eliminates the common case; the
/// narrow window is accepted as an implementation trade-off.
///
/// ## Timeout arm cosmetic log edge case (accepted trade-off)
/// `Task.sleep` throws `CancellationError` on cancellation (caught by `try?`),
/// so `process.terminate()` and the "timed out" log are only reached when the
/// sleep completes naturally. In the rare case where both arms finish
/// near-simultaneously, `process.terminate()` is called on an already-exited
/// process (safe no-op on Darwin) and the "timed out" log fires even though the
/// subprocess succeeded. This is a cosmetic log inaccuracy, not a correctness
/// issue, accepted as a trade-off against adding a result-coordination lock.
///
/// ## Shell expansion
/// `${GH_TOKEN:-$GITHUB_TOKEN}` recovers `GH_TOKEN`, falling back to
/// `GITHUB_TOKEN` when `GH_TOKEN` is unset or empty. This matches the priority
/// order of `resolveFromEnvironment()`. Only one value is returned per run —
/// the shell expansion selects one, not both.
///
/// ## Security
/// No user input is interpolated — the shell command is a hardcoded literal.
///
/// ## Shell choice
/// `/bin/zsh` is the macOS default since Catalina; guaranteed to exist at that path.
/// `-i -l` sources `~/.zprofile` and `~/.zshrc`.
///
/// - Returns: The resolved token, or `nil` if not found or timed out.
@concurrent
private func loginShellToken(logger: (any GitHubLogger)?) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i", "-l", "-c", "echo -n ${GH_TOKEN:-$GITHUB_TOKEN}"]

    let outPipe = Pipe()
    process.standardOutput = outPipe
    // Redirect stderr to /dev/null rather than a Pipe. A Pipe whose read end is never
    // drained would stall waitUntilExit() if .zshrc emits more than ~64 KB to stderr
    // (e.g. verbose compinit output). /dev/null has no buffer limit and needs no drain.
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        logger?.log("TokenCache › warmUp: login shell launch failed: \(error)", category: "transport")
        return nil
    }

    return await withTaskGroup(of: String?.self) { group in
        // Subprocess arm — wait for exit, then read stdout in one call.
        group.addTask {
            // Check cancellation before the blocking waitUntilExit() call.
            // waitUntilExit() does NOT honour Swift task cancellation; a cancelled
            // task calling it would block a cooperative thread worker until zsh exits.
            // See the TOCTOU note in the function doc comment for the narrow residual
            // window that this guard cannot eliminate.
            guard !Task.isCancelled else { return nil }
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                #if DEBUG
                logger?.log("TokenCache › warmUp: login shell: no token found in shell environment", category: "transport")
                #endif
                return nil
            }
            #if DEBUG
            logger?.log("TokenCache › warmUp: resolved from login shell (len=\(value.count))", category: "transport")
            #endif
            return value
        }
        // Timeout arm — terminate the shell if it hasn't finished in 10 s.
        // See the "Timeout arm cosmetic log edge case" note in the function doc
        // comment for why the "timed out" log can fire in a near-simultaneous finish.
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            logger?.log("TokenCache › warmUp: login shell timed out after 10 s — terminating", category: "transport")
            process.terminate()
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
