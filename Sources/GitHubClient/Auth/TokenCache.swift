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
    /// Set to `true` by the first caller that passes all fast-paths **and only after
    /// a successful shell resolution**; all subsequent concurrent callers bail early.
    ///
    /// ## One-shot-per-successful-resolution design
    /// The latch is set **only on success** (after `loginShellToken` returns a non-nil
    /// value). A failed attempt — timeout, absent token, or shell launch error — leaves
    /// the latch `false` so the next `warmUp()` call can retry. This means:
    /// - A machine that was slow at startup (timeout) can recover on the next warmUp.
    /// - A user who installs their token and the app re-warms (e.g. via re-sign-in) will
    ///   pick it up without needing a full restart.
    ///
    /// The "at most one concurrent shell" guarantee is still enforced: the latch is
    /// checked (and set optimistically to `true`) before the shell is spawned. If the
    /// shell fails, the latch is reset to `false` inside `warmUp()` after the `guard
    /// let value` check. Two concurrent callers that both pass the latch check will both
    /// try to spawn — but the second will hit the `if $0 == nil` cache guard and be a
    /// no-op if the first succeeded. This is the same thundering-herd trade-off as the
    /// Keychain read path and is accepted.
    ///
    /// ## Naming: warmUpInFlight vs warmUpAttempted
    /// The name reads as "currently running" but the semantics are "currently in
    /// progress or previously succeeded" — it is a concurrency gate, not a simple
    /// one-shot latch. The name is kept as-is because renaming would churn all call
    /// sites with no behaviour change; the semantics are fully documented here.
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
    ///    run yet.
    /// 3. Process environment (`ProcessInfo`) — covers terminal launches and CI.
    /// Only if all three return nil does the shell subprocess run.
    ///
    /// ## Latch semantics on failure (retry is allowed)
    /// `warmUpInFlight` is set optimistically before the shell runs to prevent
    /// concurrent spawns, but is **reset to false** if the shell returns nil
    /// (timeout or absent token). This allows a future `warmUp()` call to retry
    /// rather than being permanently blocked. See `warmUpInFlight` declaration
    /// comment for the full rationale.
    ///
    /// ## Blocking I/O isolation (Principle 18)
    /// The subprocess is run inside `loginShellToken(logger:)`, a `@concurrent`
    /// async free function. `@concurrent` runs off any actor's serial executor,
    /// so `waitUntilExit()` blocks one cooperative thread pool worker without
    /// stalling the caller.
    public func warmUp() async {
        guard cache.withLock({ $0 }) == nil else {
            logger?.log("TokenCache › warmUp — cache already populated, skipping login shell", category: "transport")
            return
        }
        if resolveFromStore() != nil {
            logger?.log("TokenCache › warmUp — resolved from token store, skipping login shell", category: "transport")
            return
        }
        if resolveFromEnvironment() != nil {
            logger?.log("TokenCache › warmUp — resolved from process env, skipping login shell", category: "transport")
            return
        }
        // Optimistically set the latch to prevent concurrent spawns. Reset below
        // if the shell returns nil so future warmUp() calls can retry.
        let shouldProceed = warmUpInFlight.withLock { inFlight -> Bool in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard shouldProceed else {
            if cache.withLock({ $0 }) == nil {
                logger?.log("TokenCache › warmUp — login shell already ran or is in flight; cache still nil", category: "transport")
            } else {
                logger?.log("TokenCache › warmUp — login shell completed; cache now populated", category: "transport")
            }
            return
        }
        logger?.log("TokenCache › warmUp — all fast-paths missed, attempting login shell resolution", category: "transport")
        guard let value = await loginShellToken(logger: logger) else {
            // Shell returned nil (timeout or absent token). Reset the latch so a
            // future warmUp() call can retry rather than being permanently blocked.
            warmUpInFlight.withLock { $0 = false }
            return
        }
        cache.withLock { if $0 == nil { $0 = value } }
    }

    /// Clears the in-memory token cache. Call after saving a new token or after sign-out.
    ///
    /// ## warmUpInFlight asymmetry (intentional, not an oversight)
    /// `invalidate()` clears the token `cache` but does **not** reset `warmUpInFlight`
    /// if it was set by a successful shell resolution. This is correct for the current
    /// call flow: sign-out calls `invalidate()` and then never calls `warmUp()` again.
    /// If `warmUp()` is ever called after `invalidate()`, it will fast-path out on the
    /// `warmUpInFlight` sentinel. See the `warmUpInFlight` declaration comment.
    public func invalidate() {
        cache.withLock { $0 = nil }
        logger?.log("TokenCache › invalidate — cache cleared", category: "transport")
    }

    // MARK: - Private helpers

    /// Returns the token from the in-memory cache, or `nil` if not yet populated.
    /// Fast path — no I/O, no subprocess.
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
    /// Empty strings are treated as absent.
    @discardableResult
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
        cache.withLock { if $0 == nil { $0 = token } }
        return token
    }

    /// Reads `GH_TOKEN` or `GITHUB_TOKEN` from the process environment.
    /// Populates the cache on success. Returns `nil` for Finder/Dock/login-item
    /// launches — use `warmUp()` at startup to bridge that gap.
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

/// A minimal Sendable box used to share the `Process` reference between the
/// subprocess arm and the timeout arm of the `withTaskGroup` in `loginShellToken`.
/// `Process` is not `Sendable`, so it cannot be captured directly across task
/// boundaries. This box is safe because:
/// - The process reference is written exactly once (by the subprocess arm, before
///   `waitUntilExit()`) and read at most once (by the timeout arm, to call
///   `terminate()`).
/// - Both reads/writes are coordinated by task group lifetime: the timeout arm
///   only reads after its `Task.sleep` completes, by which point the subprocess
///   arm has either already set the value (normal case) or not yet started
///   (pre-cancellation case, where `process` remains nil and `terminate()` is
///   a no-op).
private final class UncheckedProcessBox: @unchecked Sendable {
    /// The spawned process, or `nil` if not yet started or already finished.
    var process: Process?
}

/// The sentinel prefix written by the shell command before the token value.
/// Chosen to be long and app-specific enough that it cannot appear in .zshrc
/// output by coincidence. The subprocess arm scans stdout line-by-line and
/// extracts only the line carrying this prefix, discarding everything else.
private let shellTokenSentinel = "GH_TOKEN_VALUE:"

/// Spawns a single interactive login shell (`/bin/zsh -i -l`) to recover
/// `GH_TOKEN` or `GITHUB_TOKEN` from the user's shell profile.
///
/// Marked `@concurrent` so `waitUntilExit()` occupies one cooperative thread
/// pool worker without binding to any actor's serial executor (Principle 18).
///
/// ## Why a free function, not a method on TokenCache
/// `@concurrent` cannot be applied to instance methods on a `Sendable` class
/// without additional actor-annotation gymnastics. Do not move this into a
/// method on `TokenCache`.
///
/// ## Process lifetime / cancellation safety
/// The `Process` is constructed inside the subprocess arm after the
/// `Task.isCancelled` guard, and its reference is shared with the timeout arm
/// via `UncheckedProcessBox`. This ensures:
/// - No process is spawned if the task is already cancelled before the arm runs.
/// - The timeout arm can always call `process.terminate()` to kill an orphaned
///   shell, even though `Process` is constructed inside the subprocess arm.
/// - `waitUntilExit()` does not honour Swift task cancellation, so explicit
///   `terminate()` from the timeout arm is the only reliable kill path.
///
/// ## stdout pipe drain strategy — sentinel prefix isolation
/// The shell command uses `printf 'GH_TOKEN_VALUE:%s\n'` rather than `echo -n`.
/// The subprocess arm extracts only the sentinel-prefixed line, discarding all
/// other stdout. This is immune to .zshrc stdout noise (mise, nvm, oh-my-zsh,
/// starship, etc.) regardless of content — non-whitespace noise included.
///
/// ## stderr drain strategy
/// stderr is redirected to `FileHandle.nullDevice` (/dev/null) to avoid a
/// pipe-buffer deadlock if .zshrc emits more than ~64 KB to stderr.
///
/// ## Timeout / withTaskGroup race
/// Two arms race inside `withTaskGroup`:
/// - **Subprocess arm**: spawns the process, waits for exit, reads stdout.
/// - **Timeout arm**: sleeps 10 s, calls `process.terminate()`, returns nil.
/// `group.next()` returns whichever arm finishes first; `group.cancelAll()`
/// cancels the loser.
///
/// ## group.next() ?? nil — double-optional collapse
/// `group.next()` returns `String??`. `?? nil` collapses outer-nil to inner-nil.
/// The explicit `let result: String?` annotation makes the intent clear.
///
/// ## Shell expansion
/// `${GH_TOKEN:-${GITHUB_TOKEN:-}}` uses nested `:-` to guard against
/// `setopt nounset` / `set -u` aborting when both vars are unset.
///
/// ## -i flag (intentional)
/// Required to source `~/.zshrc`. Stdout noise from interactive mode is
/// handled by the sentinel prefix, not by avoiding `-i`.
///
/// ## Shell choice: why /bin/zsh
/// Guaranteed on every supported macOS since Catalina. Multi-shell support
/// would require per-shell flag negotiation with no payoff for the target
/// user base.
///
/// ## Security
/// No user input is interpolated — the shell command is a hardcoded literal.
///
/// - Returns: The resolved token, or `nil` if not found or timed out.
@concurrent
private func loginShellToken(logger: (any GitHubLogger)?) async -> String? {
    let box = UncheckedProcessBox()
    return await withTaskGroup(of: String?.self) { group in
        // Subprocess arm — construct, run, wait, read stdout.
        group.addTask {
            guard !Task.isCancelled else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // -i/-l: source ~/.zshrc and ~/.zprofile.
            // printf + sentinel: isolate token from .zshrc stdout noise.
            // Nested ${GITHUB_TOKEN:-}: guard against setopt nounset.
            process.arguments = [
                "-i", "-l", "-c",
                "printf '\(shellTokenSentinel)%s\\n' \"${GH_TOKEN:-${GITHUB_TOKEN:-}}\""
            ]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            // /dev/null: avoids pipe-buffer deadlock on heavy stderr output.
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                logger?.log("TokenCache › warmUp: login shell launch failed: \(error)", category: "transport")
                return nil
            }
            // Share the process reference so the timeout arm can terminate it.
            box.process = process
            // waitUntilExit() does not honour Swift task cancellation.
            // The timeout arm calls process.terminate() as the kill path.
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else {
                #if DEBUG
                logger?.log("TokenCache › warmUp: login shell stdout was not valid UTF-8", category: "transport")
                #endif
                return nil
            }
            let value = raw
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    guard line.hasPrefix(shellTokenSentinel) else { return nil }
                    return String(line.dropFirst(shellTokenSentinel.count))
                }
                .first ?? ""
            guard !value.isEmpty else {
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
        // Timeout arm — terminate the shell after 10 s.
        // box.process may be nil if the subprocess arm hasn't called process.run()
        // yet (pre-cancellation window); terminate() on nil is a no-op.
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            logger?.log("TokenCache › warmUp: login shell timed out after 10 s — terminating", category: "transport")
            box.process?.terminate()
            return nil
        }
        let result: String? = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
