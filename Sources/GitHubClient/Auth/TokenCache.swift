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

    /// Concurrency gate for the login shell subprocess.
    ///
    /// Set optimistically to `true` before the shell is spawned to prevent
    /// concurrent `warmUp()` calls each launching their own `/bin/zsh`.
    /// Reset to `false` if the shell returns nil (timeout or absent token),
    /// so a future `warmUp()` call can retry. Never reset by `invalidate()`.
    ///
    /// ## Why this is NOT a simple one-shot latch
    /// The latch is **set before** the shell runs and **reset after** a failed
    /// attempt. This means:
    /// - Success: latch stays true — no further shell spawns needed.
    /// - Failure (timeout / absent token): latch resets to false — next
    ///   `warmUp()` call can retry. A machine that was slow at launch can
    ///   recover; a user who installs their token mid-session can pick it up.
    /// - Concurrent callers: both pass the latch check and both may spawn,
    ///   but the `if $0 == nil` cache guard prevents a double-write.
    ///   This thundering-herd window is accepted (same trade-off as the
    ///   Keychain read path).
    ///
    /// ## Why it is read in token() — a synchronous function
    /// `token()` never touches the shell. It reads `warmUpInFlight` solely to
    /// decide which diagnostic log message to emit when all three fast-paths
    /// return nil. `warmUpInFlight == true` means "a shell ran and found
    /// nothing" — actionable (check ~/.zprofile / ~/.zshrc). `false` means
    /// "warmUp() was never called or not yet" — different message. The read
    /// is diagnostic-only and has no effect on the return value of `token()`.
    ///
    /// ## Why it is NOT reset by invalidate()
    /// Sign-out calls `invalidate()` then never calls `warmUp()` again in the
    /// current flow. Resetting the latch in `invalidate()` would be a no-op
    /// in practice and would only matter if `warmUp()` were ever called after
    /// `invalidate()`. If that call flow is ever added, the caller must also
    /// reset this latch, or `warmUp()` will silently no-op with the cache
    /// empty. See `invalidate()` doc comment.
    ///
    /// ## Naming: warmUpInFlight vs warmUpAttempted
    /// The name reads as "currently running" but the semantics are broader:
    /// "currently in progress OR previously succeeded". The name is kept
    /// because renaming would churn all internal call sites with no behaviour
    /// change. The semantics are fully documented here and at every read site.
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
    /// `TokenStore` (step 2) is checked before environment variables (step 3)
    /// because a Keychain-persisted OAuth token represents an explicit sign-in
    /// and should not be silently shadowed by an ambient CI/shell env var.
    ///
    /// Returns `nil` if no token is available from any source.
    public func token() -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = resolveFromEnvironment() { return envToken }
        // All sources returned nil. Read warmUpInFlight to pick the right
        // diagnostic log. This read has no effect on the return value —
        // token() never touches the shell. See warmUpInFlight declaration
        // comment ("Why it is read in token()") for the full rationale.
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
    /// the first poll fires. This is a no-op if the cache is already populated.
    ///
    /// ## Why this is needed
    /// macOS GUI apps launched from Finder, the Dock, or as a login item are spawned
    /// by `launchd`, which does not source `~/.zprofile` or `~/.zshrc`. As a result,
    /// `ProcessInfo.processInfo.environment` does not contain `GH_TOKEN` even when
    /// the token is correctly exported in the user's shell profile. This method
    /// bridges that gap by spawning a login shell subprocess that sources those files.
    ///
    /// ## Why async (not lazy inside token())
    /// `token()` is synchronous and may be called on the `@MainActor`. Blocking
    /// the main thread with `process.waitUntilExit()` for ~50–100 ms would freeze
    /// the UI on every cold Finder launch. `warmUp()` runs eagerly before the first
    /// poll so the cache is ready by the time `token()` is first called.
    ///
    /// ## Fast-path priority
    /// Checked in order before spawning a shell:
    /// 1. In-memory cache
    /// 2. `TokenStore` (Keychain) — prevents an env token from beating a valid
    ///    Keychain token into cache on a fresh launch where `token()` hasn’t run yet.
    /// 3. Process environment (`ProcessInfo`) — covers terminal launches and CI.
    ///
    /// ## Latch semantics on failure (retry is allowed)
    /// `warmUpInFlight` is set optimistically before the shell runs (to block
    /// concurrent spawns), then reset to `false` if the shell returns nil.
    /// A timeout or absent token does NOT permanently block future retries.
    /// See `warmUpInFlight` declaration comment for the full design.
    ///
    /// ## Blocking I/O isolation (Principle 18)
    /// The subprocess runs inside `loginShellToken(logger:)`, a `@concurrent`
    /// free function. `@concurrent` keeps `waitUntilExit()` off the main actor.
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
        // Optimistically gate concurrent spawns. Reset to false on failure below
        // so future warmUp() calls can retry. See warmUpInFlight declaration comment.
        let shouldProceed = warmUpInFlight.withLock { inFlight -> Bool in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard shouldProceed else {
            // Another caller is in-flight or already succeeded. Log which case
            // applies so the outcome is visible in diagnostics.
            if cache.withLock({ $0 }) == nil {
                logger?.log("TokenCache › warmUp — login shell already in flight or failed; cache still nil", category: "transport")
            } else {
                logger?.log("TokenCache › warmUp — login shell completed; cache now populated", category: "transport")
            }
            return
        }
        logger?.log("TokenCache › warmUp — all fast-paths missed, attempting login shell resolution", category: "transport")
        guard let value = await loginShellToken(logger: logger) else {
            // Shell returned nil (timeout or absent token). Reset the latch so a
            // future warmUp() call can retry. This is intentional — the latch is
            // not a one-shot permanent gate. See warmUpInFlight declaration comment.
            warmUpInFlight.withLock { $0 = false }
            return
        }
        cache.withLock { if $0 == nil { $0 = value } }
        // Latch stays true after success — no further shell spawns needed.
    }

    /// Clears the in-memory token cache. Call after saving a new token or after sign-out.
    ///
    /// ## What this does NOT reset (intentional)
    /// `invalidate()` clears `cache` but does **not** reset `warmUpInFlight`.
    /// This is correct for the current call flow: sign-out calls `invalidate()`
    /// and never calls `warmUp()` again. The next `token()` call falls through
    /// to `resolveFromStore()` / `resolveFromEnvironment()` as usual.
    ///
    /// ## ⚠️ If warmUp() is ever called after invalidate()
    /// `warmUp()` will fast-path out on `warmUpInFlight` and silently no-op,
    /// leaving the cache empty with no shell retry. If that call flow is ever
    /// added (e.g. post-sign-out re-warm), `warmUpInFlight` must also be reset
    /// here, or the app will launch unauthenticated with no diagnostic.
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
    /// Empty strings are treated as absent (e.g. corrupted Keychain entry).
    ///
    /// ## Thundering-herd window (intentional)
    /// Two concurrent callers that both miss the in-memory cache may both call
    /// `tokenStore.load()`. The `if $0 == nil` Mutex guard prevents a double-
    /// write; the double Keychain read is idempotent and cheaper than an extra
    /// init lock. This is an accepted trade-off, not a concurrency bug.
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
    ///
    /// Same thundering-herd window as `resolveFromStore()` — accepted trade-off.
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

/// Shares the `Process` reference between the subprocess arm and the timeout
/// arm of the `withTaskGroup` in `loginShellToken`.
///
/// `Process` is not `Sendable` so it cannot be captured directly across task
/// boundaries. This box is `@unchecked Sendable` because the access pattern
/// is safe by construction:
/// - Written exactly once: subprocess arm writes `box.process = process`
///   immediately after `process.run()` succeeds, before `waitUntilExit()`.
/// - Read at most once: timeout arm reads `box.process` only after
///   `Task.sleep` completes (i.e. 10 s after both arms started).
/// - TOCTOU between write and read: if the timeout arm fires in the narrow
///   window after `process.run()` but before `box.process = process`, it
///   reads `nil` and skips `terminate()`. The subprocess arm then calls
///   `waitUntilExit()` and the process exits naturally — not a leak, just
///   a missed early-termination. This window is accepted as a cosmetic
///   trade-off; adding a lock would add complexity with no correctness gain.
private final class UncheckedProcessBox: @unchecked Sendable {
    /// The spawned process, or `nil` if not yet started or launch failed.
    var process: Process?
}

/// The sentinel prefix written by the shell before the token value.
/// Long enough that it cannot appear in `.zshrc` output by coincidence.
/// The subprocess arm extracts only the sentinel-prefixed line, discarding
/// all other stdout — immune to any `.zshrc` noise regardless of content.
private let shellTokenSentinel = "GH_TOKEN_VALUE:"

/// Spawns `/bin/zsh -i -l` to recover `GH_TOKEN` or `GITHUB_TOKEN` from
/// the user’s shell profile and returns the token, or `nil` on failure.
///
/// ## @concurrent — blocking I/O off the main actor (Principle 18)
/// `waitUntilExit()` blocks a thread. `@concurrent` keeps that off any
/// actor’s serial executor. This is a free function (not a method on
/// `TokenCache`) because `@concurrent` cannot be applied to instance
/// methods on a `Sendable` class without additional actor gymnastics.
/// **Do not move this into a method on `TokenCache`.**
///
/// ## -i flag (intentional, not an oversight)
/// `-i` sources `~/.zshrc`, where most users export `GH_TOKEN`. Without it
/// `-l` alone sources only `~/.zprofile` / `/etc/zprofile` and silently
/// misses tokens set in `.zshrc`. Stdout noise from interactive mode is
/// neutralised by the sentinel prefix strategy — not by removing `-i`.
///
/// ## Shell choice: /bin/zsh, not $SHELL (intentional)
/// `/bin/zsh` is guaranteed on every supported macOS since Catalina.
/// `$SHELL` would require per-shell flag negotiation (bash: `--login`,
/// fish: `--login --init-command`, nushell: no login-shell concept) with
/// no benefit for the macOS-only target audience.
///
/// ## stdout sentinel isolation (not echo -n + trim)
/// `printf 'GH_TOKEN_VALUE:%s\n'` writes the token on a prefixed line.
/// The subprocess arm scans stdout line-by-line and extracts only that
/// line, discarding everything else. This is immune to non-whitespace
/// `.zshrc` noise (mise, nvm, oh-my-zsh, starship…). Plain `echo -n`
/// with whitespace trim would silently cache `<noise><token>` and cause
/// 401s for the process lifetime with no diagnostic.
///
/// ## stderr → /dev/null (not a Pipe)
/// A `Pipe()` for stderr whose read end is never drained stalls
/// `waitUntilExit()` once `.zshrc` exceeds ~64 KB of stderr output.
/// `/dev/null` has no buffer limit and needs no draining.
///
/// ## process.terminate() on timeout (not group.cancelAll() alone)
/// `group.cancelAll()` cancels the Swift task, but `waitUntilExit()` does
/// not honour Swift task cancellation (documented inline below). The
/// timeout arm explicitly calls `box.process?.terminate()` so the shell
/// is killed rather than orphaned. `terminate()` on a nil box (pre-launch
/// cancellation window) or an already-exited process is a no-op on Darwin.
///
/// ## group.next() ?? nil — double-optional (not a mistake)
/// `group.next()` returns `String??`. `?? nil` collapses outer-nil
/// (group empty) to inner-nil (no token). The `let result: String?`
/// annotation makes the intent explicit.
///
/// ## Security
/// No user input is interpolated — shell command is a hardcoded literal.
///
/// - Returns: The resolved token, or `nil` if not found or timed out.
@concurrent
private func loginShellToken(logger: (any GitHubLogger)?) async -> String? {
    let box = UncheckedProcessBox()
    return await withTaskGroup(of: String?.self) { group in
        // Subprocess arm — spawn, wait, read stdout.
        group.addTask {
            // Guard before spawning. If the task is already cancelled here
            // (e.g. timeout fired before this arm was scheduled), skip the
            // subprocess entirely. See UncheckedProcessBox comment for the
            // narrow TOCTOU window that this guard cannot fully eliminate.
            guard !Task.isCancelled else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // -i/-l: source ~/.zshrc and ~/.zprofile. See "-i flag" above.
            // printf + sentinel: immune to .zshrc stdout noise. See above.
            // Nested ${GITHUB_TOKEN:-}: guard against setopt nounset / set -u.
            process.arguments = [
                "-i", "-l", "-c",
                "printf '\(shellTokenSentinel)%s\\n' \"${GH_TOKEN:-${GITHUB_TOKEN:-}}\""
            ]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice // see "stderr → /dev/null" above
            do {
                try process.run()
            } catch {
                logger?.log("TokenCache › warmUp: login shell launch failed: \(error)", category: "transport")
                return nil
            }
            // Share the reference so the timeout arm can call terminate().
            // Written before waitUntilExit() so the timeout arm sees it if
            // it fires after the process is running. See UncheckedProcessBox.
            box.process = process
            // waitUntilExit() does NOT honour Swift task cancellation.
            // The timeout arm calls box.process?.terminate() as the kill path.
            // See "process.terminate() on timeout" in the function doc comment.
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else {
                #if DEBUG
                logger?.log("TokenCache › warmUp: login shell stdout was not valid UTF-8", category: "transport")
                #endif
                return nil
            }
            // Extract only the sentinel-prefixed line; discard all other output.
            // See "stdout sentinel isolation" in the function doc comment.
            let value = raw
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    guard line.hasPrefix(shellTokenSentinel) else { return nil }
                    return String(line.dropFirst(shellTokenSentinel.count))
                }
                .first ?? ""
            guard !value.isEmpty else {
                #if DEBUG
                logger?.log("TokenCache › warmUp: no token found in shell environment", category: "transport")
                #endif
                return nil
            }
            #if DEBUG
            logger?.log("TokenCache › warmUp: resolved from login shell (len=\(value.count))", category: "transport")
            #endif
            return value
        }
        // Timeout arm — kill the shell after 10 s and return nil.
        // box.process is nil if the subprocess arm hasn’t reached process.run()
        // yet; terminate() on nil is a no-op. See UncheckedProcessBox comment
        // for the accepted TOCTOU window.
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            logger?.log("TokenCache › warmUp: login shell timed out — terminating", category: "transport")
            box.process?.terminate() // explicit kill — group.cancelAll() alone is not enough
            return nil
        }
        // See "group.next() ?? nil" in the function doc comment.
        let result: String? = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
