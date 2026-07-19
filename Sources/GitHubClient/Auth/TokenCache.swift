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
// The shell is spawned at most once per cache lifetime. After a successful
// resolution the result is written to the in-memory cache and all
// subsequent calls return immediately from step 1.

/// A token cache that resolves from an injected `TokenStore` and/or environment variables,
/// falling back to a login shell subprocess on a cold GUI-app launch.
/// All cache reads and writes are guarded by a `Mutex` for thread safety.
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
    /// Resolution order:
    /// 1. In-memory cache — zero I/O, returns immediately on warm cache
    /// 2. `TokenStore.load()` — synchronous Keychain read
    /// 3. `GH_TOKEN` / `GITHUB_TOKEN` process environment — covers terminal / CI launches
    /// 4. Login shell subprocess — cold Finder/Dock/login-item launch only
    ///
    /// The shell (step 4) is spawned at most once per cache lifetime. On success
    /// the result is written to the in-memory cache so every subsequent call
    /// returns immediately from step 1.
    ///
    /// For GUI app launches from Finder/Dock/login items, `launchd` does not source
    /// `~/.zprofile` or `~/.zshrc`, so `ProcessInfo` does not contain `GH_TOKEN`.
    /// Step 4 bridges that gap by spawning `/bin/zsh -i -l` which sources those files.
    ///
    /// Returns `nil` if no token is available from any source (user is signed out,
    /// no env var, no shell export).
    public func token() async -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = resolveFromEnvironment() { return envToken }
        // All fast paths missed — cold Finder/Dock/login-item launch.
        // Spawn the login shell to source ~/.zprofile and ~/.zshrc.
        // This suspends for ~50-200ms on the first call, then the result
        // is cached and all subsequent calls return from step 1 above.
        guard let value = await loginShellToken(logger: logger) else {
            logger?.log(
                "TokenCache › token() — login shell found no token. "
                + "If this is a Finder/Dock launch, check that GH_TOKEN or GITHUB_TOKEN "
                + "is exported in ~/.zprofile or ~/.zshrc, or sign in via OAuth.",
                category: "transport"
            )
            return nil
        }
        cache.withLock { if $0 == nil { $0 = value } }
        return value
    }

    /// Clears the in-memory token cache.
    /// Call after saving a new token or after sign-out so the next `token()`
    /// call re-resolves from the store or shell.
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

    /// Loads the token from the `TokenStore` and populates the cache on success.
    /// Empty strings are treated as absent (e.g. corrupted Keychain entry).
    ///
    /// ## Cache-write side effect (not a pure read)
    /// Writes to `cache` on success. Named `resolveFrom…` to signal the
    /// resolve-and-cache pattern; the `@discardableResult` hides a cache mutation.
    ///
    /// ## Thundering-herd window (intentional)
    /// Two concurrent callers that both miss the in-memory cache may both call
    /// `tokenStore.load()`. The `if $0 == nil` Mutex guard prevents a double-write;
    /// the double Keychain read is idempotent and cheaper than an extra init lock.
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

    /// Reads `GH_TOKEN` or `GITHUB_TOKEN` from the process environment and
    /// populates the cache on success.
    ///
    /// Returns `nil` for Finder/Dock/login-item launches — `launchd` does not
    /// source shell profiles, so the token is absent from `ProcessInfo`.
    /// `token()` falls through to the login shell (step 4) in that case.
    ///
    /// ## Cache-write side effect (not a pure read)
    /// Same resolve-and-cache pattern as `resolveFromStore()`.
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

// MARK: - Login shell resolution (@concurrent for blocking I/O)

/// The sentinel prefix written by the shell before the token value.
/// Long enough that it cannot appear in `.zshrc` output by coincidence.
/// The subprocess arm extracts only the sentinel-prefixed line, discarding
/// all other stdout — immune to any `.zshrc` noise regardless of content.
private let shellTokenSentinel = "GH_TOKEN_VALUE:"

/// Spawns `/bin/zsh -i -l` to recover `GH_TOKEN` or `GITHUB_TOKEN` from the
/// user's shell profile and returns the token, or `nil` on failure or timeout.
///
/// ## @concurrent — blocking I/O off the main actor
/// `waitUntilExit()` blocks a thread. `@concurrent` keeps that off any
/// actor's serial executor. Free function (not a method) because `@concurrent`
/// cannot be applied to instance methods on a `Sendable` class.
///
/// ## -i flag (intentional)
/// Sources `~/.zshrc`, where most users export `GH_TOKEN`. Without it,
/// `-l` alone only sources `~/.zprofile` and misses tokens set in `.zshrc`.
/// Stdout noise from interactive mode is neutralised by the sentinel strategy.
///
/// ## Shell choice: /bin/zsh (not $SHELL)
/// Guaranteed on every supported macOS since Catalina. `$SHELL` would require
/// per-shell flag negotiation with no benefit for the macOS-only target.
///
/// ## Timeout arm uses do/catch (not try?)
/// `try? Task.sleep` silently swallows `CancellationError`. When the subprocess
/// arm succeeds in under 10s, `group.cancelAll()` cancels the timeout task.
/// `try?` would eat the error and fall through to the log + terminate() call,
/// emitting a false "timed out" log on every successful resolution.
/// `do { try … } catch { return nil }` exits cleanly on cancellation.
///
/// - Returns: The resolved token, or `nil` if not found or timed out.
@concurrent
private func loginShellToken(logger: (any GitHubLogger)?) async -> String? {
    let box = UncheckedProcessBox()
    return await withTaskGroup(of: String?.self) { group in
        // Subprocess arm — spawn, wait, read stdout.
        group.addTask {
            guard !Task.isCancelled else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-i", "-l", "-c",
                "printf '\(shellTokenSentinel)%s\\n' \"${GH_TOKEN:-${GITHUB_TOKEN:-}}\""
            ]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                logger?.log("TokenCache › login shell launch failed: \(error)", category: "transport")
                return nil
            }
            box.process = process
            // waitUntilExit() does not honour Swift task cancellation.
            // The timeout arm calls box.process?.terminate() as the kill path.
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            let value = raw
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    guard line.hasPrefix(shellTokenSentinel) else { return nil }
                    return String(line.dropFirst(shellTokenSentinel.count))
                }
                .first ?? ""
            guard !value.isEmpty else { return nil }
            #if DEBUG
            logger?.log("TokenCache › resolved from login shell (len=\(value.count))", category: "transport")
            #endif
            return value
        }
        // Timeout arm — kill the shell after 10s.
        // do/catch exits cleanly on cancellation without logging. See doc comment.
        group.addTask {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return nil
            }
            logger?.log("TokenCache › login shell timed out — terminating", category: "transport")
            box.process?.terminate()
            return nil
        }
        // group.next() returns String??; ?? nil collapses outer-nil (empty group) to inner-nil.
        let result: String? = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Shares the `Process` reference between the subprocess arm and the timeout arm.
///
/// `Process` is not `Sendable` so it cannot be captured directly across task
/// boundaries. This box is `@unchecked Sendable` because the access pattern is
/// safe by construction: written once (subprocess arm, before waitUntilExit),
/// read at most once (timeout arm, after 10s sleep). The narrow TOCTOU window
/// where both arms overlap is accepted — see loginShellToken doc comment.
private final class UncheckedProcessBox: @unchecked Sendable {
    var process: Process?
}
