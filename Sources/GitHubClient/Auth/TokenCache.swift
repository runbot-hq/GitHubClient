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
// The shell is spawned at most once per cache lifetime (cleared by invalidate()).
// After a successful resolution the result is written to the in-memory cache
// and all subsequent calls return immediately from step 1.
//
// If the shell times out or produces no token, loginShellFailed is set to true
// under the same Mutex. Subsequent token() calls short-circuit before step 4,
// returning nil immediately without re-spawning. invalidate() resets the flag
// so a sign-out / sign-in cycle gets exactly one fresh attempt.

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
    /// - `shellFailed`: set to `true` after a confirmed shell timeout or no-token
    ///   result, preventing further shell re-spawns until `invalidate()` resets it.
    private let state = Mutex<(token: String?, shellFailed: Bool)>((token: nil, shellFailed: false))

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
    /// returns immediately from step 1. On timeout or no-token result, the
    /// `shellFailed` flag is set and all subsequent calls return `nil` immediately
    /// without re-spawning the shell. `invalidate()` resets both the cache and the
    /// flag, so a sign-out / sign-in cycle gets exactly one fresh attempt.
    ///
    /// For GUI app launches from Finder/Dock/login items, `launchd` does not source
    /// `~/.zprofile` or `~/.zshrc`, so `ProcessInfo` does not contain `GH_TOKEN`.
    /// Step 4 bridges that gap by spawning `/bin/zsh -i -l` which sources those files.
    ///
    /// Returns `nil` if no token is available from any source (user is signed out,
    /// no env var, no shell export, or shell previously timed out).
    public func token() async -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = resolveFromEnvironment() { return envToken }
        // Short-circuit if the shell already failed on a prior call.
        // Prevents re-spawning /bin/zsh on every poll cycle after a confirmed
        // timeout or no-token result. Reset by invalidate().
        if state.withLock({ $0.shellFailed }) { return nil }
        // All fast paths missed — cold Finder/Dock/login-item launch.
        // Spawn the login shell to source ~/.zprofile and ~/.zshrc.
        // This suspends for ~50–200ms on the first call, then the result
        // is cached and all subsequent calls return from step 1 above.
        guard let value = await loginShellToken(logger: logger) else {
            // Shell timed out or produced no token. Set the failed flag so
            // subsequent poll cycles don't re-spawn the shell indefinitely.
            state.withLock { $0.shellFailed = true }
            logger?.log(
                "TokenCache › token() — login shell found no token. "
                + "If this is a Finder/Dock launch, check that GH_TOKEN or GITHUB_TOKEN "
                + "is exported in ~/.zprofile or ~/.zshrc, or sign in via OAuth.",
                category: "transport"
            )
            return nil
        }
        state.withLock { if $0.token == nil { $0.token = value } }
        return value
    }

    /// Clears the in-memory token cache and resets the shell-failed flag.
    ///
    /// Call after saving a new token or after sign-out so the next `token()`
    /// call re-resolves from the store or shell.
    ///
    /// Resetting `shellFailed` here is intentional: a sign-out / sign-in cycle
    /// should get exactly one fresh shell attempt on the next `token()` call,
    /// even if the previous attempt timed out. Without this reset the user would
    /// be permanently locked out of the shell path for the process lifetime after
    /// a single timeout, regardless of whether they subsequently fix their
    /// `~/.zshrc` or reduce its startup cost.
    ///
    /// Note the latency cost: the re-spawned shell adds ~50–200 ms to the first
    /// poll cycle after sign-out on an affected launch configuration. This cost
    /// recurs on every sign-out cycle (each `invalidate()` resets the flag), not
    /// just once per process lifetime. It is cached immediately on success, so
    /// only the first `token()` call after each `invalidate()` pays the penalty.
    public func invalidate() {
        state.withLock { $0 = (token: nil, shellFailed: false) }
        logger?.log("TokenCache › invalidate — cache and shell-failed flag cleared", category: "transport")
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
    /// ## Thundering-herd window (intentional)
    /// Two concurrent callers that both miss the in-memory cache may both call
    /// `tokenStore.load()`. The `if $0.token == nil` Mutex guard prevents a
    /// double-write; the double Keychain read is idempotent and cheaper than
    /// an extra init lock.
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

// MARK: - Login shell resolution (@concurrent for blocking I/O)

/// The sentinel prefix written by the shell before the token value.
/// Long enough that it cannot appear in `.zshrc` output by coincidence.
/// The subprocess arm extracts only the sentinel-prefixed line, discarding
/// all other stdout — immune to any `.zshrc` noise regardless of content.
///
/// Sentinel collision: a token that itself begins with `GH_TOKEN_VALUE:` would
/// have those leading characters stripped, producing a truncated invalid token.
/// This is not a practical risk — all real GitHub PAT formats (`ghp_`,
/// `github_pat_`, `ghs_`, etc.) are defined by GitHub and none begin with this
/// sentinel. If GitHub ever issues a token format that starts with `GH_TOKEN_VALUE:`
/// this assumption must be revisited.
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
/// ## -i flag and interactive zsh startup latency
/// Interactive mode triggers full zsh initialisation: PS1 setup, `compinit`,
/// and any user hooks (oh-my-zsh, nvm, rvm, pyenv, etc.). On a minimally
/// configured machine this is ~50–200ms. On a heavily configured machine with
/// a cold `compinit` cache, startup can reach 1–3 seconds. The 10-second
/// timeout budget includes process-launch time — on a slow machine where
/// `process.run()` itself takes a moment, the effective shell-resolution
/// window is shorter than 10 s. The timeout is generous for the common case
/// but may feel tight for users with expensive `~/.zshrc` setups. Correctness
/// is unaffected — the sentinel strategy isolates the token from all stdout
/// noise regardless of init duration. If the timeout proves too tight in
/// practice, increase it or add a user-facing note in the README.
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
/// ## group.next() first-result semantics — timeout-path token discard (intentional)
/// `group.next()` returns whichever arm completes first. If the subprocess arm
/// finishes before 10 s it wins and the token is returned. If the timeout arm
/// fires first, `group.next()` returns `nil` and `cancelAll()` is called —
/// any token the shell was about to produce is intentionally discarded.
/// This is a deliberate fail-safe: returning `nil` after a timeout is safer
/// than returning a token whose resolution time exceeded the budget. The caller
/// (`token()`) sets `shellFailed = true` on nil return, preventing re-spawns.
///
/// ## Pipe buffer deadlock prevention (withCheckedContinuation drain)
/// `waitUntilExit()` blocks until the child exits. If the child writes enough
/// data to fill the pipe kernel buffer (~64 KB on macOS) before exiting —
/// plausible with a verbose `.zshrc` running neofetch, nvm, or oh-my-zsh —
/// the child blocks on the write side waiting for the buffer to drain while
/// this code blocks on `waitUntilExit()` waiting for the child to exit:
/// deadlock. The fix is to drain the pipe concurrently on a `DispatchQueue`
/// worker thread using `withCheckedContinuation`, suspending the async task
/// until the drain completes. `waitUntilExit()` is then called after
/// `await drainPipe(outPipe)` returns, by which point all stdout has been
/// read and the child has already exited naturally.
///
/// ## Why withCheckedContinuation instead of DispatchSemaphore
/// Swift 6 strict concurrency (SE-0296) marks `DispatchSemaphore.wait()` as
/// unavailable from async contexts — including inside `@concurrent` task
/// closures, which are still typed `async`. `withCheckedContinuation` is the
/// correct Swift 6 idiom for bridging a blocking call that must run off the
/// async executor. It also eliminates the `#SendableClosureCaptures` warning
/// from a captured `var` because data flows through the continuation's resume
/// value rather than a mutated capture.
///
/// ## On the timeout path: does drainPipe hang?
/// If the timeout arm fires and calls `terminate()` while the drain is still
/// running, `terminate()` sends SIGTERM to the shell, which causes the shell
/// to exit and close the write end of the pipe. A closed write end causes
/// `readDataToEndOfFile()` to return immediately with whatever was buffered,
/// the continuation is resumed, and `await drainPipe(outPipe)` returns
/// promptly. No hang.
///
/// ## Thread leak on the timeout path (known, bounded)
/// After `group.next()` + `group.cancelAll()`, this function returns before
/// the subprocess arm's `waitUntilExit()` call has necessarily unblocked.
/// `Process.waitUntilExit()` does not honour Swift task cancellation, so the
/// cooperative pool thread running the subprocess arm is held until zsh
/// responds to `terminate()` and exits. For this `zsh -c printf` use case
/// the shell exits in under a second after receiving SIGTERM, so the leaked
/// thread window is brief. If `loginShellToken` is ever adapted for longer-
/// running subprocesses, this must be revisited.
///
/// ## App Sandbox (not currently applicable — known cliff)
/// `Process` is unavailable in a sandboxed Mac app. If the app is ever
/// sandboxed, `process.run()` will throw a permission error, `loginShellToken`
/// returns `nil`, and the user gets no token with no obvious diagnostic.
/// The entire `loginShellToken` path must be removed before enabling the
/// sandbox entitlement.
///
/// ## Thundering-herd on concurrent callers
/// `loginShellToken` has no guard against concurrent callers — two `token()`
/// calls that simultaneously miss all fast paths will each spawn a separate
/// `/bin/zsh` process. Both will ultimately write the same value to the cache
/// (the `if $0.token == nil` Mutex guard in `token()` prevents a double-write),
/// so correctness is preserved. In practice this cannot happen: `RunnerPoller`
/// is a single serial actor and is the only caller of `token()` in the app, so
/// at most one cold-launch shell is ever spawned. A future public API consumer
/// that calls `token()` concurrently from multiple tasks should be aware of this.
///
/// - Returns: The resolved token, or `nil` if not found or timed out.
@concurrent
private func loginShellToken(logger: (any GitHubLogger)?) async -> String? {
    let box = UncheckedProcessBox()
    return await withTaskGroup(of: String?.self) { group in
        // Subprocess arm — spawn, drain stdout, wait, read.
        group.addTask {
            // Cheap early-exit if the task group was cancelled before this arm
            // was scheduled (e.g. loginShellToken itself was cancelled before
            // any work started). This is a best-effort check only — it does not
            // protect against cancellation racing with process.run() below.
            // That window is intentionally unguarded: if the task is cancelled
            // after run() succeeds, the timeout arm's terminate() is the kill
            // path, or the shell runs to fast natural completion. Correctness
            // is unaffected either way.
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
            // Redirect stdin to /dev/null. /bin/zsh -i (interactive mode) reads
            // from stdin by default. For a Finder/Dock launch the inherited stdin
            // is already the null device, but redirecting explicitly prevents a
            // hang if this path is ever reached from a terminal-context caller
            // where stdin would otherwise be the user's terminal.
            process.standardInput = FileHandle.nullDevice
            // Assign box.process BEFORE calling run() so the timeout arm can
            // always call terminate() on a non-nil process. If run() throws,
            // processIdentifier is 0 (never launched) and the defer clears the
            // box so the timeout arm sees nil and skips terminate() cleanly.
            box.process = process
            defer { if process.processIdentifier == 0 { box.process = nil } }
            // ⚠️ App Sandbox: Process.run() throws a permission error in a sandboxed
            // app. loginShellToken must be removed before enabling the sandbox
            // entitlement. See the loginShellToken doc comment for details.
            do {
                try process.run()
            } catch {
                logger?.log("TokenCache › login shell launch failed: \(error)", category: "transport")
                return nil
            }
            // Drain stdout via withCheckedContinuation BEFORE calling waitUntilExit().
            // If the pipe kernel buffer (~64 KB on macOS) fills before the child exits,
            // calling waitUntilExit() first would deadlock: child blocks on write(),
            // this task blocks on waitUntilExit(). drainPipe() runs readDataToEndOfFile()
            // on a DispatchQueue worker thread and suspends this async task until the
            // drain completes; by the time we reach waitUntilExit() the pipe is fully
            // drained and the child has exited naturally. See doc comment for details.
            let data = await drainPipe(outPipe)
            // waitUntilExit() does not honour Swift task cancellation.
            // The timeout arm calls box.process?.terminate() as the kill path.
            // The drain above ensures this never deadlocks on a pipe-full condition.
            // Note: on the common fast path the shell has already exited by the time
            // drainPipe() returns (readDataToEndOfFile() unblocks when the write end
            // closes, which happens on shell exit). waitUntilExit() on an already-
            // exited process checks isRunning internally and returns immediately —
            // it is not a hang risk even when called after the child is gone.
            process.waitUntilExit()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            let value = raw
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    guard line.hasPrefix(shellTokenSentinel) else { return nil }
                    return String(line.dropFirst(shellTokenSentinel.count))
                }
                .first ?? ""
            // Trim whitespace and carriage returns. Some terminal emulators write
            // CRLF line endings; a trailing \r would produce Bearer <token>\r and
            // every API call would return 401 silently.
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            #if DEBUG
            logger?.log("TokenCache › resolved from login shell (len=\(trimmed.count))", category: "transport")
            #endif
            return trimmed
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
        // group.next() returns the result of whichever arm completes first.
        // If the timeout arm wins, the shell's token (if any) is intentionally
        // discarded — fail-safe over fail-open. See doc comment for full rationale.
        // The caller (token()) sets shellFailed = true on nil return.
        //
        // String?? → String?: the ?? nil collapses the outer Optional (group.next()
        // returns nil only when all tasks have already been collected). That path is
        // structurally unreachable here — two tasks were added and only one
        // group.next() call is made — so ?? nil exists solely to satisfy the type
        // system, not as a real fallback.
        let result: String? = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Drains `pipe` by calling `readDataToEndOfFile()` on a `DispatchQueue` worker
/// thread and bridging the result back to the async caller via `withCheckedContinuation`.
///
/// `readDataToEndOfFile()` blocks until the write end of the pipe is closed (i.e.
/// the child process exits or is terminated). Running it on a `DispatchQueue` thread
/// keeps the blocking I/O off the Swift concurrency cooperative pool.
///
/// On the timeout path: `terminate()` sends SIGTERM to the shell, which closes
/// the pipe write end, causing `readDataToEndOfFile()` to return immediately with
/// whatever was buffered. The continuation is resumed promptly — no hang.
private func drainPipe(_ pipe: Pipe) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: data)
        }
    }
}

/// Shares the `Process` reference between the subprocess arm and the timeout arm.
///
/// `Process` is not `Sendable` so it cannot be captured directly across task
/// boundaries. This box is `@unchecked Sendable` because the two arms access
/// `process` without any synchronisation primitive — see the data race note below.
/// A `defer` in the subprocess arm clears the box if `run()` throws, so the
/// timeout arm sees `nil` and skips `terminate()` on a process that never launched.
///
/// ## Accepted data race (hardware-ordering-dependent, not formally safe)
/// The write (`box.process = process`, before `run()`) and the read
/// (`box.process?.terminate()`, after 10 s of sleep) are on two different Swift
/// concurrency tasks with no lock, barrier, or `Mutex` between them. TSan will
/// correctly flag this as an unsynchronised read/write. This is an accepted
/// data race, not a false positive.
///
/// Safety in practice relies on hardware memory ordering, not on any guarantee
/// from the Swift memory model. The Swift memory model does not promise that an
/// unsynchronised write from Task A is visible to a read from Task B at any
/// particular point — only properly synchronised accesses carry that guarantee.
/// The argument below holds on Apple Silicon and x86 due to their strong
/// memory models, but it is not formally provable from Swift semantics alone.
/// Do NOT adapt this pattern assuming it is formally safe.
///
/// Why it holds in practice:
/// - The write precedes `waitUntilExit()`, which blocks the subprocess arm's
///   thread for the entire duration of the shell's life — effectively pinning
///   the write well before the timeout arm could ever fire.
/// - The read happens after 10 s of sleep — orders of magnitude after the write.
/// - `Process.terminate()` is thread-safe (documented by Apple).
/// - Window A: timeout fires between task creation and `box.process = process`
///   → `nil?.terminate()`, a no-op; the shell runs to natural completion.
/// - Window B: timeout fires between `box.process = process` and `process.run()`
///   → `terminate()` on an unlaunched Process. Per Apple docs, `terminate()`
///   checks `isRunning` and is a no-op. Both windows are bounded and harmless.
///
/// Accepted as bounded and harmless in practice.
///
/// ## Process dealloc does not terminate
/// When `withTaskGroup` returns and `box` is released, ARC deallocates this
/// instance. `Process` deallocation does NOT send SIGTERM to the subprocess —
/// an orphaned shell will continue running until it exits naturally or is killed
/// by another means. For the `zsh -c printf` use case the shell exits in under
/// a second after SIGTERM (sent by the timeout arm) or after the command
/// completes (subprocess arm). Do NOT rely on `Process` dealloc as a cleanup
/// mechanism in any future adaptation of this pattern.
private final class UncheckedProcessBox: @unchecked Sendable {
    /// The spawned `/bin/zsh` process, or `nil` if not yet started or launch failed.
    var process: Process?
}
