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
// If the shell times out, produces no token, or fails to launch, shellFailed
// is set to true under the same Mutex. Subsequent token() calls short-circuit
// before step 4, returning nil immediately without re-spawning. invalidate()
// resets the flag so a sign-out / sign-in cycle gets exactly one fresh attempt.

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
    /// - `shellFailed`: set to `true` after a confirmed shell timeout, no-token
    ///   result, or launch failure, preventing further shell re-spawns until
    ///   `invalidate()` resets it.
    ///
    /// ## Why one Mutex for both fields
    /// `token` and `shellFailed` are always read and mutated as a pair:
    /// `token()` reads `shellFailed` then writes one or the other, and
    /// `invalidate()` resets both atomically. Two separate locks would require
    /// lock-ordering discipline to prevent deadlock, and would expose an
    /// inconsistent intermediate state where `token` is cleared but `shellFailed`
    /// is still `true` — permanently blocking the shell path after sign-out until
    /// the second lock was also cleared. One lock is simpler and eliminates that
    /// window entirely.
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
    /// ## Why `async` when steps 1–3 are synchronous
    /// Steps 1–3 are synchronous and return without ever suspending. The function
    /// is `async` solely because step 4 (`loginShellToken`) is unavoidably async —
    /// it uses `@concurrent` + `withTaskGroup` + `waitUntilExit()`. Swift does not
    /// allow a non-async function to call an async one. The cost of the `async`
    /// declaration on the warm path is a single actor-hop check — negligible
    /// compared to any Keychain or subprocess I/O.
    ///
    /// ## Why shell failure is permanent until `invalidate()`
    /// Retrying on every call would spawn a new `/bin/zsh` on every poll cycle
    /// (~30 s) for the process lifetime on any machine where the shell has no
    /// token — a persistent background thread burn and a guaranteed 10-second
    /// stall each cycle. A timed backoff would add a timestamp field and timer
    /// logic that exists solely for a condition the user must fix manually anyway.
    /// The chosen policy matches user mental model: act (fix `~/.zprofile`, set
    /// the env var, sign in via OAuth), then the next sign-out/sign-in cycle
    /// resets via `invalidate()`. Transient OS blips (`ENOMEM` at launch etc.)
    /// are the one accepted gap — tracked in issue #68.
    ///
    /// The shell (step 4) is spawned at most once per cache lifetime. On success
    /// the result is written to the in-memory cache so every subsequent call
    /// returns immediately from step 1. On timeout, no-token result, or launch
    /// failure, the `shellFailed` flag is set and all subsequent calls return `nil`
    /// immediately without re-spawning the shell. `invalidate()` resets both the
    /// cache and the flag, so a sign-out / sign-in cycle gets exactly one fresh attempt.
    ///
    /// For GUI app launches from Finder/Dock/login items, `launchd` does not source
    /// `~/.zprofile` or `~/.zshrc`, so `ProcessInfo` does not contain `GH_TOKEN`.
    /// Step 4 bridges that gap by spawning `/bin/zsh -i -l` which sources those files.
    ///
    /// Returns `nil` if no token is available from any source (user is signed out,
    /// no env var, no shell export, or shell previously timed out or failed to launch).
    ///
    /// - Warning: Concurrent callers that simultaneously miss all fast paths (steps 1–3)
    ///   will each spawn a separate `/bin/zsh` subprocess. The `shellFailed` guard and
    ///   the write-back to `state.token` are separate Mutex lock calls — there is no
    ///   atomic "check-and-enter" operation. This means that `shellFailed` is NOT set
    ///   until `loginShellToken` returns (which can take up to 10 s on timeout), so the
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
        // Short-circuit if the shell already failed on a prior call.
        // Prevents re-spawning /bin/zsh on every poll cycle after a confirmed
        // timeout, no-token result, or launch failure. Reset by invalidate().
        // See "Why shell failure is permanent until invalidate()" above.
        if state.withLock({ $0.shellFailed }) { return nil }
        // All fast paths missed — cold Finder/Dock/login-item launch.
        // Spawn the login shell to source ~/.zprofile and ~/.zshrc.
        // This suspends for ~50–200ms on the first call, then the result
        // is cached and all subsequent calls return from step 1 above.
        guard let value = await loginShellToken(logger: logger) else {
            state.withLock { $0.shellFailed = true }
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
/// ## Why stderr is not drained
/// `standardError` is redirected to `FileHandle.nullDevice` — the OS kernel
/// sink, not a `Pipe`. There is no pipe buffer; bytes are discarded immediately.
/// `readDataToEndOfFile()` is never called on stderr, so there is no second
/// drain to coordinate and no second deadlock window. If stderr is ever changed
/// to a `Pipe`, a matching `drainPipe()` call before `waitUntilExit()` becomes
/// required.
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
/// returns `nil`, and `token()` sets `shellFailed = true` — the user gets no
/// token with no obvious diagnostic. The entire `loginShellToken` path must be
/// removed before enabling the sandbox entitlement.
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
/// - Returns: The resolved token, or `nil` if not found, timed out, or launch failed.
@concurrent
private func loginShellToken(logger: (any GitHubLogger)?) async -> String? {
    let box = ProcessBox()
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
            // /dev/null is a kernel sink, not a Pipe — no buffer to fill, no drain needed.
            // See "Why stderr is not drained" in the loginShellToken doc comment above.
            process.standardError = FileHandle.nullDevice
            // Redirect stdin to /dev/null. /bin/zsh -i (interactive mode) reads
            // from stdin by default. For a Finder/Dock launch the inherited stdin
            // is already the null device, but redirecting explicitly prevents a
            // hang if this path is ever reached from a terminal-context caller
            // where stdin would otherwise be the user's terminal.
            process.standardInput = FileHandle.nullDevice
            // Store the process in the box before calling run() so the timeout arm
            // can always reach it via terminate(). The defer below clears it on a
            // run() throw so the timeout arm sees nil and skips terminate() cleanly.
            box.state.withLock { $0 = process }
            // processIdentifier is assigned by the OS only when run() succeeds.
            // A value of 0 means run() never succeeded — which is exactly the
            // throw path. On the success path processIdentifier is a real PID
            // (> 0) so the condition is false and box.state is left intact
            // for the timeout arm to call terminate() if needed.
            defer { if process.processIdentifier == 0 { box.state.withLock { $0 = nil } } }
            // ⚠️ App Sandbox: Process.run() throws a permission error in a sandboxed
            // app. loginShellToken must be removed before enabling the sandbox
            // entitlement. See the loginShellToken doc comment for details.
            do {
                try process.run()
            } catch {
                logger?.log(
                    "TokenCache › login shell failed to launch: \(error). "
                    + "Check that /bin/zsh is present and executable.",
                    category: "transport"
                )
                // shellFailed is set by the caller (token()) on nil return —
                // no need to set it here. The defer above clears box.state
                // so the timeout arm skips terminate() cleanly.
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
            // The timeout arm calls box.state.withLock { $0 }?.terminate() as the kill path.
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
            if trimmed.isEmpty {
                // The shell launched and ran successfully, but found no GH_TOKEN
                // or GITHUB_TOKEN export in ~/.zprofile / ~/.zshrc.
                // This is expected for OAuth-only users — not an error.
                logger?.log(
                    "TokenCache › login shell ran successfully but found no token export. "
                    + "This is normal for OAuth-only users. "
                    + "To use a PAT on Finder/Dock launches, export GH_TOKEN or GITHUB_TOKEN "
                    + "in ~/.zprofile or ~/.zshrc.",
                    category: "transport"
                )
                return nil
            }
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
            logger?.log(
                "TokenCache › login shell timed out after 10 s — terminating. "
                + "If your ~/.zshrc has expensive startup hooks (oh-my-zsh, nvm, compinit, etc.), "
                + "consider moving the GH_TOKEN export to ~/.zprofile instead, "
                + "which is sourced without -i and avoids the full interactive init.",
                category: "transport"
            )
            box.state.withLock { $0 }?.terminate()
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
/// `qos: .utility` signals background I/O intent — this is not interactive work.
/// Under memory pressure, `.utility` is deprioritised less aggressively than the
/// default global queue while still yielding to interactive QoS work.
///
/// On the timeout path: `terminate()` sends SIGTERM to the shell, which closes
/// the pipe write end, causing `readDataToEndOfFile()` to return immediately with
/// whatever was buffered. The continuation is resumed promptly — no hang.
private func drainPipe(_ pipe: Pipe) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: data)
        }
    }
}

/// Shares the `Process` reference between the subprocess arm and the timeout arm
/// behind a `Mutex` for formally safe cross-task access.
///
/// `Process` is not `Sendable` so it cannot be captured directly across task
/// boundaries. Wrapping it in a `Mutex<Process?>` gives us a properly `Sendable`
/// container with no `@unchecked` annotation required — all reads and writes
/// are synchronised by the lock.
///
/// A `defer` in the subprocess arm clears the box if `run()` throws, so the
/// timeout arm sees `nil` and skips `terminate()` on a process that never launched.
///
/// ## Process dealloc does not terminate
/// When `withTaskGroup` returns and `box` is released, ARC deallocates this
/// instance. `Process` deallocation does NOT send SIGTERM to the subprocess —
/// an orphaned shell will continue running until it exits naturally or is killed
/// by another means. For the `zsh -c printf` use case the shell exits in under
/// a second after SIGTERM (sent by the timeout arm) or after the command
/// completes (subprocess arm). Do NOT rely on `Process` dealloc as a cleanup
/// mechanism in any future adaptation of this pattern.
private final class ProcessBox: Sendable {
    /// The spawned `/bin/zsh` process, or `nil` if not yet started or launch failed.
    /// Guarded by a `Mutex` for safe cross-task read/write without `@unchecked Sendable`.
    let state = Mutex<Process?>(nil)
}
