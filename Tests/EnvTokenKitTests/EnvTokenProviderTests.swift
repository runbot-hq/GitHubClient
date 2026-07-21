// EnvTokenProviderTests.swift
// EnvTokenKitTests
//
// Exercises `EnvTokenProvider` resolution order, shell latch policy, and
// invalidation.
//
// ⚠️ ISOLATION REQUIREMENT
// `setenv`/`unsetenv` mutate the process-global environment. Correctness
// relies on the `@Suite(.serialized)` attribute — if `.serialized` is ever
// removed, concurrent tests that both call `withCleanEnv` will race on
// `GH_TOKEN`/`GITHUB_TOKEN` and produce intermittent flakes.
//
// No real `/bin/zsh` subprocess is ever spawned. All tests inject a
// `shellResolver` closure that returns a fixed `ShellTokenResult` immediately.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the runner environment.
// Every test wraps its body in `withCleanEnv`, which strips both vars and
// restores them afterwards.

import Foundation
import Synchronization
import Testing

@testable import EnvTokenKit

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
///
/// ⚠️ SERIALIZED DEPENDENCY: `setenv`/`unsetenv` mutate the process-global
/// environment. Correctness relies on the `@Suite(.serialized)` attribute on
/// `EnvTokenProviderTests` — if `.serialized` is ever removed, concurrent
/// tests that both call `withCleanEnv` will race on `GH_TOKEN`/`GITHUB_TOKEN`
/// and produce intermittent flakes.
private func withCleanEnv(_ body: () async -> Void) async {
    let prevGH = ProcessInfo.processInfo.environment["GH_TOKEN"]
    let prevGitHub = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
    unsetenv("GH_TOKEN")
    unsetenv("GITHUB_TOKEN")
    await body()
    if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
    if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Sets one env var for the duration of body, then restores the previous value.
/// See `withCleanEnv` for the `.serialized` dependency note.
private func withEnv(_ key: String, value: String, _ body: () async -> Void) async {
    let previous = ProcessInfo.processInfo.environment[key]
    setenv(key, value, 1)
    await body()
    if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - EnvTokenProviderTests

@Suite("EnvTokenProvider", .serialized)
struct EnvTokenProviderTests {

    /// Builds a fresh `EnvTokenProvider` with an injected shell resolver so no
    /// real `/bin/zsh` subprocess is ever spawned.
    ///
    /// - Parameter shellResult: The `ShellTokenResult` the resolver will return.
    ///   Defaults to `.notFound` (instant, no I/O) — correct for all nil-path
    ///   and env-var tests. Pass `.found("token")` or `.failed` to exercise the
    ///   shell-specific behaviour.
    private func makeProvider(
        shellResult: ShellTokenResult = .notFound
    ) -> EnvTokenProvider {
        EnvTokenProvider(
            shellResolver: { _ in shellResult }
        )
    }

    // MARK: - token() — ProcessInfo hit (terminal / install launch path)

    /// Resolves from `GH_TOKEN` in `ProcessInfo` without entering the shell path.
    ///
    /// This covers the terminal/install launch path: the token is present in the
    /// process environment because the user launched from a shell that inherited
    /// the export. The shell resolver must NOT be called.
    ///
    /// ## How this test validates the shell is not spawned
    /// The injected `shellResolver` increments a counter. If `token()` returns
    /// the ProcessInfo value before reaching the shell path, the counter stays 0.
    @Test func envProvider_processInfo_hit() async {
        await withCleanEnv {
            let shellCallCount = Mutex<Int>(0)
            let provider = EnvTokenProvider(
                shellResolver: { _ in
                    shellCallCount.withLock { $0 += 1 }
                    return .notFound
                }
            )
            await withEnv("GH_TOKEN", value: "terminal-token") {
                let result = await provider.token()
                #expect(result == "terminal-token")
            }
            // ProcessInfo fast path must short-circuit before the shell resolver.
            #expect(shellCallCount.withLock { $0 } == 0)
        }
    }

    /// Falls back to the shell resolver when `ProcessInfo` has no token export.
    ///
    /// This covers the Finder/Dock/login-item launch path: `launchd` does not
    /// inherit shell exports, so `ProcessInfo` misses and `EnvTokenProvider`
    /// must spawn `/bin/zsh -i -l`. The injected resolver returns `.found("token")`
    /// so no real subprocess is spawned.
    @Test func envProvider_processInfo_miss_shellHit() async {
        await withCleanEnv {
            // Both env vars stripped by withCleanEnv — ProcessInfo will miss.
            let provider = makeProvider(shellResult: .found("shell-token"))
            let result = await provider.token()
            #expect(result == "shell-token")
        }
    }

    // MARK: - token() — priority order

    /// `GH_TOKEN` is preferred over `GITHUB_TOKEN` when both are set.
    ///
    /// Both variables resolve the same credential. `GH_TOKEN` is the shorter,
    /// preferred form documented in the README — it must win without any silent
    /// override from `GITHUB_TOKEN`.
    @Test func envProvider_ghToken_preferredOver_githubToken() async {
        await withCleanEnv {
            await withEnv("GH_TOKEN", value: "primary-token") {
                await withEnv("GITHUB_TOKEN", value: "fallback-token") {
                    let result = await makeProvider().token()
                    #expect(result == "primary-token")
                }
            }
        }
    }

    // MARK: - token() — shell latch: .failed

    /// After the shell returns `.failed`, subsequent `token()` calls must short-circuit
    /// without re-entering the resolver.
    ///
    /// `.failed` latches because retrying a broken or sandbox-blocked shell on every
    /// poll cycle (~30 s) would be a persistent background thread burn with no benefit.
    /// The latch is cleared only by an explicit `invalidate()` call (e.g. sign-out).
    @Test func envProvider_shellFailed_latches() async {
        await withCleanEnv {
            let resolverCallCount = Mutex<Int>(0)
            let provider = EnvTokenProvider(
                shellResolver: { _ in
                    resolverCallCount.withLock { $0 += 1 }
                    return .failed
                }
            )
            // First call — resolver fires, outcome set to .failed.
            let first = await provider.token()
            #expect(first == nil)
            #expect(resolverCallCount.withLock { $0 } == 1)
            // Second call — .failed latch short-circuits, resolver NOT called again.
            let second = await provider.token()
            #expect(second == nil)
            #expect(resolverCallCount.withLock { $0 } == 1)
        }
    }

    /// After `invalidate()`, the `.failed` latch is cleared so the next `token()`
    /// call re-enters the shell resolver for a fresh attempt.
    ///
    /// A sign-out / sign-in cycle must get exactly one fresh shell attempt, even
    /// if the previous one timed out. Without this reset the user would be
    /// permanently locked out of the shell path for the process lifetime after a
    /// single failure, regardless of whether they subsequently fix `~/.zshrc`.
    @Test func envProvider_invalidate_resetsFailedLatch() async {
        await withCleanEnv {
            let resolverCallCount = Mutex<Int>(0)
            let provider = EnvTokenProvider(
                shellResolver: { _ in
                    resolverCallCount.withLock { $0 += 1 }
                    return .failed
                }
            )
            // First call — resolver fires, .failed latch set.
            _ = await provider.token()
            #expect(resolverCallCount.withLock { $0 } == 1)
            // invalidate() resets the latch to .notAttempted.
            provider.invalidate()
            // Second call — latch cleared, resolver fires again.
            _ = await provider.token()
            #expect(resolverCallCount.withLock { $0 } == 2)
        }
    }

    // MARK: - token() — shell latch: .notFound

    /// `.notFound` does NOT latch — the resolver is re-entered on the next call.
    ///
    /// An OAuth-only user who later adds `GH_TOKEN` to their shell profile should
    /// have it picked up on the next `token()` call without relaunching. This is the
    /// deliberate asymmetry with `.failed`. See `ShellResolutionOutcome.notFound`
    /// for the full rationale.
    ///
    /// ## .notFound re-entry cost (TODO #68)
    /// Because `.notFound` does not latch, a Finder-launch user with no token export
    /// re-enters shell resolution on every poll cycle (~30 s). A timestamp-based
    /// cooldown is the right long-term fix — tracked in issue #68.
    @Test func envProvider_shellNotFound_doesNotLatch() async {
        await withCleanEnv {
            let resolverCallCount = Mutex<Int>(0)
            let provider = EnvTokenProvider(
                shellResolver: { _ in
                    resolverCallCount.withLock { $0 += 1 }
                    return .notFound
                }
            )
            let first = await provider.token()
            #expect(first == nil)
            let second = await provider.token()
            #expect(second == nil)
            // .notFound does not latch — resolver called on both invocations.
            #expect(resolverCallCount.withLock { $0 } == 2)
        }
    }

    // MARK: - token() — nil path

    /// Returns nil when both env vars are absent and the shell finds nothing.
    @Test func envProvider_noSource_returnsNil() async {
        await withCleanEnv {
            let result = await makeProvider(shellResult: .notFound).token()
            #expect(result == nil)
        }
    }

    /// Returns nil when `GH_TOKEN` is an empty string.
    @Test func envProvider_ghTokenEmptyString_returnsNil() async {
        await withCleanEnv {
            await withEnv("GH_TOKEN", value: "") {
                let result = await makeProvider().token()
                #expect(result == nil)
            }
        }
    }

    /// Returns nil when `GITHUB_TOKEN` is an empty string.
    @Test func envProvider_githubTokenEmptyString_returnsNil() async {
        await withCleanEnv {
            await withEnv("GITHUB_TOKEN", value: "") {
                let result = await makeProvider().token()
                #expect(result == nil)
            }
        }
    }

    // MARK: - invalidate()

    /// Safe to call when no shell attempt has been made — does not crash.
    @Test func envProvider_invalidate_whenNotAttempted_isNoop() async {
        await withCleanEnv {
            let provider = makeProvider()
            provider.invalidate()  // must not crash
            let result = await provider.token()
            #expect(result == nil)
        }
    }
}
