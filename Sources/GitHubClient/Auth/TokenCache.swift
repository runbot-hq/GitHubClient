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
    /// concurrent callers bail early. Reset is intentionally omitted — warmUp() is
    /// designed to run the subprocess at most once per app lifetime.
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
        logger?.log("TokenCache › token() — returning nil (no token from any source)", category: "transport")
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
    /// ## Concurrency
    /// Concurrent calls that all pass the fast-paths are serialised by a
    /// `warmUpInFlight` sentinel: only the first caller proceeds to spawn the
    /// subprocess; all others return immediately. The `cache` write at the end
    /// is independently guarded by its own `Mutex`.
    ///
    /// ## Blocking I/O isolation (Principle 18)
    /// The subprocess is run inside `loginShellToken(logger:)`, a `@concurrent`
    /// async free function. `@concurrent` runs off any actor’s serial executor,
    /// so `waitUntilExit()` blocks one cooperative thread pool worker without
    /// stalling the caller. No `DispatchQueue` or `DispatchSemaphore` bridges
    /// are used — the timeout is a structured `withTaskGroup` race and the pipe
    /// is drained via `FileHandle.AsyncBytes`.
    ///
    /// ## Performance
    /// The subprocess takes ~50–100 ms on first call with a 10-second timeout.
    /// A single `/bin/zsh -i -l` invocation recovers both `GH_TOKEN` and
    /// `GITHUB_TOKEN` in one shell run. The result is cached on first resolution;
    /// subsequent `warmUp()` calls return immediately.
    public func warmUp() async {
        // Fast-path 1: in-memory cache already populated.
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
        // In-flight guard: if another concurrent warmUp() call already passed all
        // fast-paths and is about to spawn (or is running) the subprocess, bail here.
        // The first caller sets the sentinel to true inside the lock; all later callers
        // see true and return. The sentinel is never reset — warmUp() spawns at most
        // one subprocess per TokenCache lifetime.
        let shouldProceed = warmUpInFlight.withLock { inFlight -> Bool in
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard shouldProceed else {
            logger?.log("TokenCache › warmUp — login shell already in flight, skipping", category: "transport")
            return
        }
        logger?.log("TokenCache › warmUp — all fast-paths missed, attempting login shell resolution", category: "transport")
        // loginShellToken is @concurrent — it runs off any actor's serial executor
        // so waitUntilExit() inside it does not stall the caller. No Task.detached
        // wrapper is needed; the direct await is sufficient and clearer.
        guard let value = await loginShellToken(logger: logger) else { return }
        cache.withLock { if $0 == nil { $0 = value } }
    }

    /// Clears the in-memory token cache. Call after saving a new token or after sign-out.
    public func invalidate() {
        cache.withLock { $0 = nil }
        logger?.log("TokenCache › invalidate — cache cleared", category: "transport")
    }

    // MARK: - Private helpers

    /// Reads the in-memory cache. Returns `nil` if not set.
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
    /// Keychain entry) is treated identically to `nil`. This mirrors the empty-string
    /// guard in `resolveFromEnvironment()` and prevents a blank Bearer header from
    /// being cached and sent on every subsequent request.
    ///
    /// - Note: Thundering-herd window is intentional. Two concurrent callers that
    ///   both miss `resolveFromCache()` will both call `tokenStore.load()` and both
    ///   attempt to set the cache. The `if $0 == nil { $0 = token }` check-before-write
    ///   inside the `Mutex` lock ensures only one write lands and both callers return
    ///   the same token. The double Keychain read is idempotent and cheaper than
    ///   adding a separate initialisation lock.
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

    /// Reads the `GH_TOKEN` or `GITHUB_TOKEN` environment variable from the process
    /// environment. Populates the cache on success.
    ///
    /// This path succeeds when the app is launched from a terminal that already has
    /// the variable set (e.g. `export GH_TOKEN=...` in the current shell session or
    /// inherited from a CI environment). It returns `nil` for GUI app launches from
    /// Finder/Dock/login items — use `warmUp()` during startup to bridge that gap.
    ///
    /// ## Caching trade-off
    /// Env-var tokens are written into the shared cache (same as store-backed tokens). This
    /// mirrors the behaviour of the original `GitHubTokenCache` in `RunBotCore` and keeps
    /// the hot path consistent: once any token is resolved, every subsequent call returns
    /// immediately from `resolveFromCache()` without re-reading the env dictionary.
    ///
    /// The theoretical downside is that an env-var token is frozen for the process lifetime.
    /// In practice this is fine — `ProcessInfo.processInfo.environment` is itself immutable
    /// after launch, so there is nothing to re-read. A more conservative design would skip
    /// the cache write here and reserve the cache exclusively for store-backed tokens, but
    /// that adds complexity with no real benefit given the immutability guarantee. `invalidate()`
    /// remains the correct escape hatch if a token-rotation scenario ever arises.
    ///
    /// - Note: Same intentional thundering-herd window as `resolveFromStore()` — the
    ///   `if $0 == nil` guard inside the lock is the correct protection. The env var
    ///   read is an in-process dictionary lookup and is safe to call concurrently.
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

/// Spawns a single interactive login shell to recover the first available GitHub
/// token from `GH_TOKEN` or `GITHUB_TOKEN`.
///
/// Marked `@concurrent` so that `waitUntilExit()` — a blocking call — occupies
/// one Swift cooperative thread pool worker without binding to any actor's serial
/// executor. This is the pattern mandated by Principle 18 of principles.md:
/// blocking I/O uses `@concurrent` free functions, not `DispatchQueue` bridges.
///
/// ## Pipe drain (deadlock prevention)
/// stdout is read via `FileHandle.AsyncBytes` (`outPipe.fileHandleForReading.bytes`),
/// an `AsyncSequence` that yields chunks as they arrive. This drains the pipe
/// concurrently with the running shell without any `DispatchQueue`. A `.zshrc`
/// emitting more than the OS pipe buffer (~64 KB) to stdout can no longer cause
/// a deadlock — the async reader keeps the buffer empty regardless of output volume.
///
/// ## Timeout (hang prevention)
/// A `withTaskGroup` race pits the subprocess task against a
/// `Task.sleep(for: .seconds(10))` timeout arm. Whichever finishes first wins;
/// `group.cancelAll()` cancels the loser. If the timeout arm wins it calls
/// `process.terminate()` before returning `nil`, ensuring the shell is always
/// cleaned up. This replaces the previous `DispatchSemaphore` + `terminationHandler`
/// pattern with fully structured concurrency.
///
/// ## Security
/// No user input is interpolated into the shell command — the command is a
/// hardcoded literal. There is no injection risk.
/// stderr is redirected to a separate `Pipe()` to suppress zsh startup warnings
/// (e.g. `compinit` insecure-directory warnings) from appearing in Console.app.
///
/// ## Shell choice
/// `/bin/zsh` is the macOS default interactive shell since Catalina and is
/// guaranteed to exist at that path. `-i -l` causes zsh to source `~/.zprofile`
/// and `~/.zshrc`, recovering any exported token.
///
/// - Parameter logger: Optional logger for diagnostic messages.
/// - Returns: The resolved token string, or `nil` if not found or timed out.
@concurrent
private func loginShellToken(logger: (any GitHubLogger)?) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // -i (interactive) + -l (login) causes zsh to source ~/.zprofile and ~/.zshrc.
    // ${GH_TOKEN:-$GITHUB_TOKEN} expands to GH_TOKEN if set and non-empty,
    // otherwise falls back to GITHUB_TOKEN. echo -n suppresses the trailing newline.
    process.arguments = ["-i", "-l", "-c", "echo -n ${GH_TOKEN:-$GITHUB_TOKEN}"]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    // Suppress zsh startup warnings (compinit, etc.) from appearing in Console.app.
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        logger?.log("TokenCache › warmUp: login shell launch failed: \(error)", category: "transport")
        return nil
    }

    // Race the subprocess against a 10-second timeout using structured concurrency.
    // The subprocess arm drains stdout via AsyncBytes (no pipe-buffer deadlock risk)
    // and then calls waitUntilExit(). The timeout arm terminates the process if it
    // wins. group.cancelAll() cancels the losing arm in both cases.
    return await withTaskGroup(of: String?.self) { group in
        // Subprocess arm: drain stdout as an AsyncSequence, then wait for exit.
        group.addTask {
            var data = Data()
            // FileHandle.AsyncBytes yields chunks as the shell writes them,
            // keeping the pipe buffer empty regardless of .zshrc output volume.
            if let asyncBytes = try? outPipe.fileHandleForReading.bytes {
                for try await byte in asyncBytes {
                    data.append(byte)
                }
            }
            process.waitUntilExit()
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                #if DEBUG
                logger?.log("TokenCache › warmUp: login shell: neither GH_TOKEN nor GITHUB_TOKEN found in shell environment", category: "transport")
                #endif
                return nil
            }
            #if DEBUG
            logger?.log("TokenCache › warmUp: resolved from login shell (len=\(value.count))", category: "transport")
            #endif
            return value
        }
        // Timeout arm: if the shell hasn’t finished in 10 seconds, terminate it.
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            // Only reach here if not cancelled (i.e. we won the race).
            logger?.log("TokenCache › warmUp: login shell timed out after 10 s — terminating", category: "transport")
            process.terminate()
            return nil
        }
        // Take the first result (whichever arm finishes first) and cancel the other.
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
