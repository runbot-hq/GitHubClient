// EnvTokenProviderTests.swift
// EnvTokenKitTests
//
// Exercises `EnvTokenProvider` resolution order, shell latch policy, and
// invalidation.
//
// ⚠️ ISOLATION STRATEGY
// All test targets run in the same process. `setenv`/`unsetenv` mutate the
// process-global environment, so concurrent suites can race on GH_TOKEN /
// GITHUB_TOKEN. The strategy to prevent flakes is two-layered:
//
// 1. Tests that exercise the ProcessInfo fast path use `withEnv` / `withCleanEnv`
//    AND stub `envLookup` so `EnvTokenProvider` never consults the real process
//    environment. The env helpers exist only to verify that the production
//    `envLookup` default (ProcessInfo) reads the right key — not as a general
//    isolation mechanism.
//
// 2. Tests that exercise the shell path inject both `shellResolver` (stub, no
//    real /bin/zsh) and `envLookup: { _ in nil }` (stub, no real ProcessInfo)
//    so they are fully deterministic regardless of what other suites do to the
//    process environment concurrently.
//
// `@Suite(.serialized)` is kept as a belt-and-suspenders guard for the small
// number of tests that still use `withEnv` on the real environment, but it is
// NOT relied upon for cross-suite isolation.

import Foundation
import Synchronization
import Testing

@testable import EnvTokenKit

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
///
/// ⚠️ Only safe within a single serialized suite. Cross-suite races are
/// eliminated by stubbing `envLookup` instead — see the file-level isolation
/// strategy note above.
private func withCleanEnv(_ body: () async -> Void) async {
    let prevGH = getenv("GH_TOKEN").flatMap { String(cString: $0) }
    let prevGitHub = getenv("GITHUB_TOKEN").flatMap { String(cString: $0) }
    unsetenv("GH_TOKEN")
    unsetenv("GITHUB_TOKEN")
    await body()
    if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
    if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Sets one env var for the duration of body, then restores the previous value.
private func withEnv(_ key: String, value: String, _ body: () async -> Void) async {
    let previous = getenv(key).flatMap { String(cString: $0) }
    setenv(key, value, 1)
    await body()
    if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - EnvTokenProviderTests

@Suite("EnvTokenProvider", .serialized)
struct EnvTokenProviderTests {

    /// Builds a provider with all I/O stubbed out.
    ///
    /// - Parameters:
    ///   - shellResult: What the shell resolver returns. Defaults to `.notFound`.
    ///   - envLookup: What the env lookup returns for a given key.
    ///     Defaults to `nil` (empty environment) so tests are immune to whatever
    ///     `GH_TOKEN`/`GITHUB_TOKEN` the CI runner or concurrent suite has set.
    private func makeProvider(
        shellResult: ShellTokenResult = .notFound,
        envLookup: (@Sendable (String) -> String?)? = nil
    ) -> EnvTokenProvider {
        EnvTokenProvider(
            shellResolver: { _ in shellResult },
            envLookup: envLookup ?? { _ in nil }
        )
    }

    // MARK: - token() — ProcessInfo hit (terminal / install launch path)

    /// Resolves the token from the `GH_TOKEN` env var without entering the shell path.
    ///
    /// Uses a stubbed `envLookup` so this test is immune to cross-suite env races.
    /// The injected `shellResolver` counter must remain 0 — the env fast path must
    /// short-circuit before the shell resolver is reached.
    @Test func envProvider_processInfo_hit() async {
        let shellCallCount = Mutex<Int>(0)
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                shellCallCount.withLock { $0 += 1 }
                return .notFound
            },
            envLookup: { key in key == "GH_TOKEN" ? "terminal-token" : nil }
        )
        let result = await provider.token()
        #expect(result == "terminal-token")
        #expect(shellCallCount.withLock { $0 } == 0)
    }

    /// Falls back to the shell resolver when the env lookup returns nil for both keys.
    ///
    /// `envLookup: { _ in nil }` simulates a Finder/Dock launch where `launchd`
    /// provides no shell exports. The injected resolver returns `.found("shell-token")`
    /// so no real subprocess is spawned and no real process env is consulted.
    @Test func envProvider_processInfo_miss_shellHit() async {
        let provider = makeProvider(shellResult: .found("shell-token"))
        let result = await provider.token()
        #expect(result == "shell-token")
    }

    // MARK: - token() — priority order

    /// `GH_TOKEN` is preferred over `GITHUB_TOKEN` when both are set.
    @Test func envProvider_ghToken_preferredOver_githubToken() async {
        let provider = makeProvider(
            envLookup: { key in
                switch key {
                case "GH_TOKEN":     return "primary-token"
                case "GITHUB_TOKEN": return "fallback-token"
                default:             return nil
                }
            }
        )
        let result = await provider.token()
        #expect(result == "primary-token")
    }

    // MARK: - token() — shell latch: .failed

    /// After the shell returns `.failed`, subsequent `token()` calls must
    /// short-circuit without re-entering the resolver.
    ///
    /// `.failed` latches because retrying a broken or sandbox-blocked shell on
    /// every poll cycle (~30 s) would be a persistent background thread burn
    /// with no benefit. The latch is cleared only by an explicit `invalidate()`.
    ///
    /// ## Why this asserts call count, not return value (issue #78)
    /// `second == nil` is an unreliable proxy: a concurrent suite running in
    /// the same process can set `GH_TOKEN` between `withCleanEnv`'s `unsetenv`
    /// and `token()`'s first suspension point, causing `resolveFromEnvironment()`
    /// to return a non-nil value even when the latch is working correctly.
    /// Asserting `resolverCallCount == 1` on both calls is immune to that race:
    /// `envLookup` is stubbed to `{ _ in nil }` so the env fast path never fires,
    /// and the stub resolver counter can only be incremented by this test.
    @Test func envProvider_shellFailed_latches() async {
        let resolverCallCount = Mutex<Int>(0)
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .failed
            },
            envLookup: { _ in nil }
        )
        // First call — resolver fires, outcome set to .failed.
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 1)
        // Second call — .failed latch short-circuits, resolver NOT called again.
        _ = await provider.token()
        #expect(
            resolverCallCount.withLock { $0 } == 1,
            "resolver must not be called again after .failed latch"
        )
    }

    /// After `invalidate()`, the `.failed` latch is cleared so the next `token()`
    /// call re-enters the shell resolver for a fresh attempt.
    @Test func envProvider_invalidate_resetsFailedLatch() async {
        let resolverCallCount = Mutex<Int>(0)
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .failed
            },
            envLookup: { _ in nil }
        )
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 1)
        provider.invalidate()
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 2)
    }

    // MARK: - token() — shell latch: .notFound

    /// `.notFound` does NOT latch — the resolver is re-entered on the next call.
    ///
    /// An OAuth-only user who later adds `GH_TOKEN` to their shell profile should
    /// have it picked up on the next `token()` call without relaunching.
    @Test func envProvider_shellNotFound_doesNotLatch() async {
        let resolverCallCount = Mutex<Int>(0)
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .notFound
            },
            envLookup: { _ in nil }
        )
        _ = await provider.token()
        _ = await provider.token()
        // .notFound does not latch — resolver called on both invocations.
        #expect(resolverCallCount.withLock { $0 } == 2)
    }

    // MARK: - token() — nil path

    /// Returns nil when both env vars are absent and the shell finds nothing.
    @Test func envProvider_noSource_returnsNil() async {
        let result = await makeProvider(shellResult: .notFound).token()
        #expect(result == nil)
    }

    /// Returns nil when `GH_TOKEN` is an empty string.
    @Test func envProvider_ghTokenEmptyString_returnsNil() async {
        let provider = makeProvider(
            envLookup: { key in key == "GH_TOKEN" ? "" : nil }
        )
        let result = await provider.token()
        #expect(result == nil)
    }

    /// Returns nil when `GITHUB_TOKEN` is an empty string.
    @Test func envProvider_githubTokenEmptyString_returnsNil() async {
        let provider = makeProvider(
            envLookup: { key in key == "GITHUB_TOKEN" ? "" : nil }
        )
        let result = await provider.token()
        #expect(result == nil)
    }

    // MARK: - invalidate()

    /// Safe to call when no shell attempt has been made — does not crash.
    @Test func envProvider_invalidate_whenNotAttempted_isNoop() async {
        let provider = makeProvider()
        provider.invalidate()  // must not crash
        let result = await provider.token()
        #expect(result == nil)
    }
}
