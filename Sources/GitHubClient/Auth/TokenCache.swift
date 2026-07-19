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
    /// for example, when a Keychain OAuth token exists or when the app is launched
    /// from a terminal that already has `GH_TOKEN` set.
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
    /// ## Performance
    /// The subprocess runs on a detached background thread via `Task.detached` and
    /// takes ~50–100 ms on first call. The result is cached on first resolution;
    /// subsequent `warmUp()` calls return immediately without spawning a subprocess.
    public func warmUp() async {
        // Fast path: cache already populated (Keychain OAuth, terminal launch, prior warmUp).
        guard cache.withLock({ $0 }) == nil else {
            logger?.log("TokenCache › warmUp — cache already populated, skipping login shell", category: "transport")
            return
        }
        // Also skip if ProcessInfo already has the token (e.g. CI or terminal launch
        // where the process env is populated). resolveFromEnvironment() will cache it.
        if resolveFromEnvironment() != nil {
            logger?.log("TokenCache › warmUp — resolved from process env, skipping login shell", category: "transport")
            return
        }
        logger?.log("TokenCache › warmUp — process env empty, attempting login shell resolution", category: "transport")
        await Task.detached(priority: .userInitiated) { [weak self] in
            self?.resolveFromLoginShell()
        }.value
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

    /// Spawns an interactive login shell to source the user's zsh profile files
    /// and read `GH_TOKEN` or `GITHUB_TOKEN`. Called only from `warmUp()` on a
    /// background thread — never called from `token()`.
    ///
    /// ## Why a login shell is needed
    /// macOS GUI apps are spawned by `launchd`, which does not source `~/.zprofile`
    /// or `~/.zshrc`. Running `/bin/zsh -i -l -c "echo -n $KEY"` sources the full
    /// zsh startup sequence and recovers any exported variable.
    ///
    /// ## Security
    /// The key name is hardcoded to one of two known strings — no user input is
    /// interpolated into the shell command, so there is no injection risk.
    /// stderr is redirected to a separate `Pipe()` to suppress zsh startup warnings
    /// (e.g. `compinit` insecure-directory warnings) from appearing in Console.app.
    ///
    /// ## Shell choice
    /// `/bin/zsh` is used because it is the macOS default interactive shell since
    /// Catalina and is guaranteed to exist at that path. If the user's login shell
    /// is bash or fish, their token export must also be in a file that zsh sources
    /// for this path to find it. A future improvement could inspect `$SHELL` and
    /// adapt, but zsh covers the overwhelming majority of macOS developer environments.
    private func resolveFromLoginShell() {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // -i (interactive) + -l (login) causes zsh to source ~/.zprofile and ~/.zshrc,
            // making any exported env vars available to the -c command.
            process.arguments = ["-i", "-l", "-c", "echo -n $\(key)"]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            // Suppress zsh startup warnings (compinit, etc.) from appearing in logs.
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                logger?.log("TokenCache › warmUp: login shell launch failed for \(key): \(error)", category: "transport")
                continue
            }
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                #if DEBUG
                logger?.log("TokenCache › warmUp: login shell: \(key) not found in shell environment", category: "transport")
                #endif
                continue
            }
            #if DEBUG
            logger?.log("TokenCache › warmUp: resolved from login shell env var \(key) (len=\(value.count)), populating cache", category: "transport")
            #endif
            cache.withLock { if $0 == nil { $0 = value } }
            return
        }
    }
}
