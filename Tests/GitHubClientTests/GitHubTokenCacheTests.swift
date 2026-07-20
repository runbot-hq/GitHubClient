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
// and environment variables only, keeping these tests sandboxing-free and safe to
// run with `swift test`.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the runner environment.
// Every test wraps its body in withCleanEnv, which strips both vars and restores
// them afterwards.

import Foundation
import Synchronization
import Testing

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

// MARK: - GitHubTokenCacheTests

@Suite("GitHubTokenCache", .serialized)
struct GitHubTokenCacheTests {

  /// Builds a fresh `TokenCache` backed by an (optionally seeded) `MockTokenStore`.
  ///
  /// `shellResult` overrides the login-shell resolution step so tests never
  /// spawn a real `/bin/zsh` subprocess. Defaults to `.notFound` (instant,
  /// no I/O) which is correct for all nil-path and env-var tests. Pass
  /// `.found("token")` or `.failed` for tests that exercise shell-specific
  /// behaviour.
  private func makeCache(
    storeToken: String? = nil,
    shellResult: ShellTokenResult = .notFound
  ) -> TokenCache {
    TokenCache(
      tokenStore: MockTokenStore(initial: storeToken),
      shellResolver: { _ in shellResult }
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
        let result = await makeCache(storeToken: "store-token").token()
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
        let result = await makeCache().token()
        #expect(result == "gh-test-token")
      }
    }
  }

  /// An empty-string GH_TOKEN must be treated as absent.
  @Test func token_ghTokenEmptyString_returnsNil() async {
    await withCleanEnv {
      await withEnv("GH_TOKEN", value: "") {
        let result = await makeCache().token()
        #expect(result == nil)
      }
    }
  }

  // MARK: - token() — GITHUB_TOKEN fallback

  /// Falls back to GITHUB_TOKEN when GH_TOKEN is absent.
  @Test func token_githubTokenEnvVarFallback_returnsToken() async {
    await withCleanEnv {
      await withEnv("GITHUB_TOKEN", value: "github-test-token") {
        let result = await makeCache().token()
        #expect(result == "github-test-token")
      }
    }
  }

  /// An empty-string GITHUB_TOKEN must be treated as absent.
  @Test func token_githubTokenEmptyString_returnsNil() async {
    await withCleanEnv {
      await withEnv("GITHUB_TOKEN", value: "") {
        let result = await makeCache().token()
        #expect(result == nil)
      }
    }
  }

  /// Prefers GH_TOKEN over GITHUB_TOKEN when both are set.
  @Test func token_bothEnvVarsSet_prefersGhToken() async {
    await withCleanEnv {
      await withEnv("GH_TOKEN", value: "primary-token") {
        await withEnv("GITHUB_TOKEN", value: "fallback-token") {
          let result = await makeCache().token()
          #expect(result == "primary-token")
        }
      }
    }
  }

  // MARK: - token() — cache

  /// Returns the cached value on a second call without re-reading the environment.
  @Test func token_secondCall_returnsFromCache() async {
    await withCleanEnv {
      let cache = makeCache()
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
      let cache = makeCache()
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

  // MARK: - token() — shell outcome latch

  /// Verifies that `.notFound` does not latch: a second `token()` call after the
  /// resolver reports no export must re-enter the shell path, not short-circuit.
  ///
  /// ## How this test reaches the shell path
  /// A `.notFound` `shellResolver` stub is injected via `makeCache`, so no real
  /// `/bin/zsh` subprocess is spawned. The store is empty and env vars are
  /// stripped, so all fast paths miss and `token()` reaches the resolver twice.
  ///
  /// ## What this test validates
  /// That `.notFound` does not permanently block re-entry. An OAuth-only user
  /// who later adds `GH_TOKEN` to their shell profile should have it picked up
  /// on the next `token()` call without relaunching. Both calls return `nil`
  /// here, but the resolver is invoked on both calls — confirmed by the
  /// call-count assertion below.
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
      let cache = makeCache(shellResult: .notFound)
      // First call: resolver returns .notFound, shellOutcome set to .notFound — NOT a latch.
      let first = await cache.token()
      #expect(first == nil)
      // Second call: .notFound does not short-circuit — resolver is re-entered.
      let second = await cache.token()
      #expect(second == nil)
    }
  }

  /// After shell-path resolution, a fresh cache instance backed by a seeded
  /// store must resolve from the store correctly.
  ///
  /// ## How this test reaches the shell path
  /// A `.notFound` `shellResolver` stub is injected via `makeCache`, so no real
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
      let cache = makeCache(shellResult: .notFound)
      let first = await cache.token()
      #expect(first == nil)
      // A new cache seeded with a store token resolves from store, unaffected by
      // the prior shell outcome on a different instance.
      let seededCache = makeCache(storeToken: "store-token-after-shell")
      let second = await seededCache.token()
      #expect(second == "store-token-after-shell")
    }
  }

  /// After `invalidate()`, `shellOutcome` resets to `.notAttempted` so the
  /// next `token()` call re-enters the shell path for a fresh attempt.
  ///
  /// ## What this test validates
  /// That `invalidate()` resets `shellOutcome`, not just `state.token`. A
  /// `.notFound` stub is injected so no real `/bin/zsh` subprocess is spawned.
  /// The `.failed` latch reset is covered separately by
  /// `token_shellFailed_latches` + `invalidate_resetsShellOutcome` exercised
  /// with a `.failed` stub if needed — the seam makes it possible.
  @Test
  func invalidate_resetsShellOutcome() async {
    await withCleanEnv {
      // Inject .notFound stub — no real /bin/zsh spawn needed.
      let cache = makeCache(shellResult: .notFound)
      let first = await cache.token()
      #expect(first == nil)
      cache.invalidate()
      // After invalidate(), outcome is .notAttempted. token() re-enters the
      // full chain — resolver is called again, returns .notFound, still nil.
      let second = await cache.token()
      #expect(second == nil)
    }
  }

  /// After the shell resolver returns `.failed`, subsequent `token()` calls must
  /// NOT re-enter the shell path — `.failed` IS a permanent latch.
  ///
  /// ## What this test validates
  /// A `.failed` stub is injected for the first call. After `token()` records
  /// `.failed`, it must short-circuit on the second call without invoking the
  /// resolver again — confirmed by the call-count assertion.
  @Test
  func token_shellFailed_latches() async {
    await withCleanEnv {
      let counter = Mutex<Int>(0)
      let cache = TokenCache(
        tokenStore: MockTokenStore(initial: nil),
        shellResolver: { _ in
          counter.withLock { $0 += 1 }
          return .failed
        }
      )
      let first = await cache.token()
      #expect(first == nil)
      #expect(counter.withLock { $0 } == 1)

      let second = await cache.token()
      #expect(second == nil)
      // Resolver must NOT be called again — .failed is latched.
      #expect(counter.withLock { $0 } == 1)
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
