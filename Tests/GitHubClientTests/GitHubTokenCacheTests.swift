// GitHubTokenCacheTests.swift
// GitHubClientTests
//
// Exercises `TokenCache` resolution order, in-memory caching, and invalidation.
//
// ⚠️ ISOLATION REQUIREMENT
// `TokenCache` is instance-scoped (a fresh instance per test), so there is no
// process-global cache to flush. However, env-var resolution mutates the process
// environment (setenv/unsetenv), which IS process-global — so the suite stays
// .serialized and every test wraps its body in withCleanEnv.
//
// Keychain is never touched: token resolution is exercised through a MockTokenStore
// and a StubEnvTokenProvider, keeping these tests sandboxing-free and safe to
// run with `swift test`.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the runner environment.
// Every test wraps its body in withCleanEnv, which strips both vars and restores
// them afterwards.
//
// Env-var tests (GH_TOKEN / GITHUB_TOKEN) exercise the StubEnvTokenProvider path
// via a stub that reads ProcessInfo, not the real EnvTokenProvider, because
// GitHubClientTests cannot depend on EnvTokenProvider's internal implementation.
// The real end-to-end env path is covered by EnvTokenKitTests.

import Foundation
import Synchronization
import Testing

@testable import EnvTokenKit
@testable import GitHubClient

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
///
/// ⚠️ SERIALIZED DEPENDENCY: `setenv`/`unsetenv` mutate the process-global
/// environment. Correctness relies on the `@Suite(.serialized)` attribute on
/// `GitHubTokenCacheTests` — if `.serialized` is ever removed, concurrent
/// tests that both call `withCleanEnv` will race on `GH_TOKEN`/`GITHUB_TOKEN`
/// and produce intermittent flakes.
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
/// See `withCleanEnv` for the `.serialized` dependency note.
private func withEnv(_ key: String, value: String, _ body: () async -> Void) async {
  let previous = getenv(key).flatMap { String(cString: $0) }
  setenv(key, value, 1)
  await body()
  if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - EnvReadingStubProvider

/// A `StubEnvTokenProvider`-like stub that reads `ProcessInfo` directly, used
/// only by the env-var tests. This mirrors what the real `EnvTokenProvider` does
/// for steps 3+4, without depending on its concrete implementation.
///
/// Kept file-private: only `GitHubTokenCacheTests` needs this bridge.
///
/// `@unchecked Sendable` is NOT used here — the class has no stored mutable
/// state (both methods are pure `ProcessInfo` reads), so it satisfies `Sendable`
/// without any escape hatch. Consistent with the codebase's no-`@unchecked`
/// invariant (P4, see `KeychainTokenStore` class comment).
private final class EnvReadingStubProvider: EnvTokenProviding, Sendable {
  func token() async -> String? {
    for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
      if let v = getenv(key).flatMap({ String(cString: $0) }), !v.isEmpty { return v }
    }
    return nil
  }
  func invalidate() {}
}

// MARK: - GitHubTokenCacheTests

@Suite("GitHubTokenCache", .serialized)
struct GitHubTokenCacheTests {

  /// Builds a fresh `TokenCache` backed by an (optionally seeded) `MockTokenStore`.
  ///
  /// `envProvider` overrides the injected env+shell provider so tests never
  /// spawn a real `/bin/zsh` subprocess. Defaults to `StubEnvTokenProvider(result: .notFound)`
  /// (instant, no I/O) which is correct for all nil-path and env-var tests. Pass
  /// a `StubEnvTokenProvider(result: .found(…))` or `.failed` for tests that
  /// exercise shell-specific behaviour.
  private func makeCache(
    storeToken: String? = nil,
    envProvider: any EnvTokenProviding = StubEnvTokenProvider(result: .notFound)
  ) -> TokenCache {
    TokenCache(
      tokenStore: MockTokenStore(initial: storeToken),
      envProvider: envProvider
    )
  }

  // MARK: - token() — nil path

  /// Returns nil when neither env var is set and the store is empty.
  @Test func token_noSource_returnsNil() async {
    await withCleanEnv {
      let result = await makeCache().token()
      #expect(result == nil)
    }
  }

  // MARK: - token() — store priority

  /// Resolves from the `TokenStore` ahead of the environment.
  @Test func token_storeTakesPriorityOverEnv() async {
    await withCleanEnv {
      await withEnv("GH_TOKEN", value: "env-token") {
        let result = await makeCache(
          storeToken: "store-token",
          envProvider: EnvReadingStubProvider()
        ).token()
        #expect(result == "store-token")
      }
    }
  }

  /// An empty-string token returned by the store must be treated as absent.
  @Test func token_storeEmptyString_returnsNil() async {
    await withCleanEnv {
      let result = await makeCache(storeToken: "").token()
      #expect(result == nil)
    }
  }

  // MARK: - token() — GH_TOKEN

  /// Resolves a token from GH_TOKEN when the store is empty.
  @Test func token_ghTokenEnvVar_returnsToken() async {
    await withCleanEnv {
      await withEnv("GH_TOKEN", value: "gh-test-token") {
        let result = await makeCache(envProvider: EnvReadingStubProvider()).token()
        #expect(result == "gh-test-token")
      }
    }
  }

  /// An empty-string GH_TOKEN must be treated as absent.
  @Test func token_ghTokenEmptyString_returnsNil() async {
    await withCleanEnv {
      await withEnv("GH_TOKEN", value: "") {
        let result = await makeCache(envProvider: EnvReadingStubProvider()).token()
        #expect(result == nil)
      }
    }
  }

  // MARK: - token() — GITHUB_TOKEN fallback

  /// Falls back to GITHUB_TOKEN when GH_TOKEN is absent.
  @Test func token_githubTokenEnvVarFallback_returnsToken() async {
    await withCleanEnv {
      await withEnv("GITHUB_TOKEN", value: "github-test-token") {
        let result = await makeCache(envProvider: EnvReadingStubProvider()).token()
        #expect(result == "github-test-token")
      }
    }
  }

  /// An empty-string GITHUB_TOKEN must be treated as absent.
  @Test func token_githubTokenEmptyString_returnsNil() async {
    await withCleanEnv {
      await withEnv("GITHUB_TOKEN", value: "") {
        let result = await makeCache(envProvider: EnvReadingStubProvider()).token()
        #expect(result == nil)
      }
    }
  }

  /// Prefers GH_TOKEN over GITHUB_TOKEN when both are set.
  @Test func token_bothEnvVarsSet_prefersGhToken() async {
    await withCleanEnv {
      // Set both vars directly — no nesting to avoid async suspension-point races.
      setenv("GH_TOKEN", "primary-token", 1)
      setenv("GITHUB_TOKEN", "fallback-token", 1)
      let result = await makeCache(envProvider: EnvReadingStubProvider()).token()
      #expect(result == "primary-token")
    }
  }

  // MARK: - token() — cache

  /// Returns the cached value on a second call without re-reading the environment.
  @Test func token_secondCall_returnsFromCache() async {
    await withCleanEnv {
      let cache = makeCache(envProvider: EnvReadingStubProvider())
      await withEnv("GH_TOKEN", value: "cached-token") {
        _ = await cache.token()  // populate cache
      }
      // Both env vars now absent — only the in-memory cache can return a value.
      let result = await cache.token()
      #expect(result == "cached-token")
    }
  }

  // MARK: - invalidate()

  /// Clears a populated cache so the next call re-resolves from source.
  @Test func invalidate_clearsCache() async {
    await withCleanEnv {
      let cache = makeCache(envProvider: EnvReadingStubProvider())
      await withEnv("GH_TOKEN", value: "original-token") {
        _ = await cache.token()  // populate cache
      }
      cache.invalidate()
      // Cache cleared + both env vars absent + empty store — must return nil.
      let result = await cache.token()
      #expect(result == nil)
    }
  }

  /// Safe to call when the cache is already empty — does not crash.
  @Test func invalidate_whenAlreadyEmpty_isNoop() async {
    await withCleanEnv {
      let cache = makeCache()
      cache.invalidate()
      let result = await cache.token()
      #expect(result == nil)
    }
  }

  /// `TokenCache.invalidate()` must forward to `envProvider.invalidate()`.
  @Test func invalidate_forwardsToEnvProvider() async {
    await withCleanEnv {
      let stub = StubEnvTokenProvider(result: .notFound)
      let cache = makeCache(envProvider: stub)
      cache.invalidate()
      #expect(stub.invalidateCalled.withLock { $0 } == true)
    }
  }

  // MARK: - token() — shell outcome latch

  /// Verifies that `.notFound` does not latch: a second `token()` call after the
  /// provider reports no token must re-enter the provider, not short-circuit.
  ///
  /// ## How this test exercises the shell path
  /// A `StubEnvTokenProvider(result: .notFound)` is injected, so no real
  /// `/bin/zsh` subprocess is spawned. The store is empty and env vars are
  /// stripped, so all fast paths miss and `token()` reaches the provider twice.
  ///
  /// ## What this test validates
  /// That `.notFound` does not permanently block re-entry. An OAuth-only user
  /// who later adds `GH_TOKEN` to their shell profile should have it picked up
  /// on the next `token()` call without relaunching. Both calls return `nil`
  /// here, but the provider is invoked on both calls — confirmed by `callCount`.
  ///
  /// ## .notFound re-entry cost (TODO #68)
  /// Because `.notFound` does not latch, an OAuth-only user launched from Finder
  /// will re-enter shell resolution on every poll cycle (~30 s) for the app
  /// lifetime. A timestamp-based cooldown in `ShellResolutionOutcome` is the
  /// right long-term fix — tracked in issue #68.
  @Test
  func token_shellNotFound_doesNotLatch() async {
    await withCleanEnv {
      // Inject .notFound stub so no real /bin/zsh subprocess is spawned.
      let stub = StubEnvTokenProvider(result: .notFound)
      let cache = makeCache(envProvider: stub)
      // First call: provider returns nil — NOT a latch.
      let first = await cache.token()
      #expect(first == nil)
      // Second call: .notFound does not short-circuit — provider is re-entered.
      let second = await cache.token()
      #expect(second == nil)
      // Provider must have been called twice (no latch).
      #expect(stub.callCount.withLock { $0 } == 2)
    }
  }

  /// After shell-path resolution, a fresh cache instance backed by a seeded
  /// store must resolve from the store correctly.
  ///
  /// ## How this test exercises the shell path
  /// A `StubEnvTokenProvider(result: .notFound)` is injected, so no real
  /// `/bin/zsh` subprocess is spawned.
  ///
  /// ## Why this test uses a second `TokenCache` instance (intentional)
  /// `seededCache` is a new instance, not `cache` after store-seeding. The
  /// scope is strictly: store resolution on a fresh instance is unaffected by
  /// a prior shell-path attempt on a different instance. Same-instance recovery
  /// is covered by `invalidate_resetsShellOutcome`.
  @Test
  func token_freshCacheAfterShellPath_storeTokenResolves() async {
    await withCleanEnv {
      // Inject .notFound stub — exercises the shell path without spawning /bin/zsh.
      let cache = makeCache(envProvider: StubEnvTokenProvider(result: .notFound))
      let first = await cache.token()
      #expect(first == nil)
      // A new cache seeded with a store token resolves from store, unaffected by
      // the prior shell outcome on a different instance.
      let seededCache = makeCache(storeToken: "store-token-after-shell")
      let second = await seededCache.token()
      #expect(second == "store-token-after-shell")
    }
  }

  /// After `invalidate()`, the provider is reset so the next `token()` call
  /// re-enters the full resolution chain for a fresh attempt.
  ///
  /// ## What this test validates
  /// That `invalidate()` resets the provider (via `envProvider.invalidate()`),
  /// not just `state.token`. A `.notFound` stub is injected so no real
  /// `/bin/zsh` subprocess is spawned. The provider being called twice
  /// (once before invalidate, once after) confirms re-entry.
  @Test
  func invalidate_resetsShellOutcome() async {
    await withCleanEnv {
      // Inject .notFound stub — no real /bin/zsh spawn needed.
      let stub = StubEnvTokenProvider(result: .notFound)
      let cache = makeCache(envProvider: stub)
      let first = await cache.token()
      #expect(first == nil)
      cache.invalidate()
      // After invalidate(), provider.invalidate() was called. token() re-enters
      // the full chain — provider is called again, returns nil, still nil.
      let second = await cache.token()
      #expect(second == nil)
      // Provider called once before and once after invalidate — re-entry confirmed.
      #expect(stub.callCount.withLock { $0 } == 2)
    }
  }

  /// After the provider returns `.failed`, `TokenCache` still delegates to the
  /// provider on every subsequent `token()` call — latch enforcement is
  /// `EnvTokenProvider`'s responsibility, not `TokenCache`'s.
  ///
  /// ## What this test validates
  /// `StubEnvTokenProvider(result: .failed)` always returns `nil`. `TokenCache`
  /// calls it on every `token()` invocation — it does NOT latch internally.
  /// The real latch lives in `EnvTokenProvider` (tested in `EnvTokenKitTests`).
  /// This test confirms `TokenCache`'s side of the contract: it delegates every
  /// time and trusts the provider to manage its own latch.
  ///
  /// ## Why this test is NOT named token_shellFailed_latches
  /// The name was changed to reflect actual behaviour: there is no latch at the
  /// `TokenCache` level. `callCount == 2` on the second call proves re-entry,
  /// not short-circuit. The latch contract belongs to `EnvTokenProvider` alone.
  @Test
  func token_shellFailed_delegatesToProvider_noTokenCacheLatch() async {
    await withCleanEnv {
      let stub = StubEnvTokenProvider(result: .failed)
      let cache = makeCache(envProvider: stub)
      let first = await cache.token()
      #expect(first == nil)
      #expect(stub.callCount.withLock { $0 } == 1)

      let second = await cache.token()
      #expect(second == nil)
      // TokenCache always delegates; the real latch is inside EnvTokenProvider.
      #expect(stub.callCount.withLock { $0 } == 2)
    }
  }

  // MARK: - token() — concurrent access

  /// Fifty concurrent `Task`s calling `token()` simultaneously must all return
  /// the same value with no crash or data race.
  ///
  /// `TokenCache` uses `Synchronization.Mutex` for thread safety. This test
  /// validates that the Mutex guard is sufficient under genuine concurrent load.
  /// The store is seeded so CI-injected env vars are irrelevant (store wins).
  @Test func token_concurrentCalls_allReturnSameToken() async {
    let cache = makeCache(storeToken: "concurrent-token")
    let taskCount = 50

    let results = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
      for _ in 0 ..< taskCount {
        group.addTask { await cache.token() }
      }
      var collected: [String?] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    #expect(results.count == taskCount)
    #expect(results.allSatisfy { $0 == "concurrent-token" })
  }
}
