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
import Testing

@testable import GitHubClient

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
private func withCleanEnv(_ body: () -> Void) {
  let prevGH = ProcessInfo.processInfo.environment["GH_TOKEN"]
  let prevGitHub = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
  unsetenv("GH_TOKEN")
  unsetenv("GITHUB_TOKEN")
  body()
  if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
  if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Sets one env var for the duration of body, then restores the previous value.
private func withEnv(_ key: String, value: String, _ body: () -> Void) {
  let previous = ProcessInfo.processInfo.environment[key]
  setenv(key, value, 1)
  body()
  if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - GitHubTokenCacheTests

@Suite("GitHubTokenCache", .serialized)
struct GitHubTokenCacheTests {

  /// Builds a fresh `TokenCache` backed by an (optionally seeded) `MockTokenStore`.
  private func makeCache(storeToken: String? = nil) -> TokenCache {
    TokenCache(tokenStore: MockTokenStore(initial: storeToken))
  }

  // MARK: - token() — nil path

  /// Returns nil when neither env var is set and the store is empty.
  @Test func token_noSource_returnsNil() {
    withCleanEnv {
      #expect(makeCache().token() == nil)
    }
  }

  // MARK: - token() — store priority

  /// Resolves from the `TokenStore` ahead of the environment.
  @Test func token_storeTakesPriorityOverEnv() {
    withCleanEnv {
      withEnv("GH_TOKEN", value: "env-token") {
        #expect(makeCache(storeToken: "store-token").token() == "store-token")
      }
    }
  }

  /// An empty-string token returned by the store must be treated as absent and
  /// return nil. A blank Bearer token would be sent on every API request, causing
  /// immediate 401s — empty strings are not valid credentials.
  ///
  /// Regression guard for the missing isEmpty check in resolveFromStore().
  /// resolveFromEnvironment() already had this guard; the store path was
  /// asymmetrically unprotected before this test was added.
  @Test func token_storeEmptyString_returnsNil() {
    withCleanEnv {
      #expect(makeCache(storeToken: "").token() == nil)
    }
  }

  // MARK: - token() — GH_TOKEN

  /// Resolves a token from GH_TOKEN when the store is empty.
  @Test func token_ghTokenEnvVar_returnsToken() {
    withCleanEnv {
      withEnv("GH_TOKEN", value: "gh-test-token") {
        #expect(makeCache().token() == "gh-test-token")
      }
    }
  }

  /// An empty-string GH_TOKEN must be treated as absent and return nil.
  /// A blank Bearer token would be sent on every API request, causing
  /// immediate 401s — empty strings are not valid credentials.
  @Test func token_ghTokenEmptyString_returnsNil() {
    withCleanEnv {
      withEnv("GH_TOKEN", value: "") {
        #expect(makeCache().token() == nil)
      }
    }
  }

  // MARK: - token() — GITHUB_TOKEN fallback

  /// Falls back to GITHUB_TOKEN when GH_TOKEN is absent.
  @Test func token_githubTokenEnvVarFallback_returnsToken() {
    withCleanEnv {
      withEnv("GITHUB_TOKEN", value: "github-test-token") {
        #expect(makeCache().token() == "github-test-token")
      }
    }
  }

  /// An empty-string GITHUB_TOKEN must be treated as absent and return nil.
  /// GH_TOKEN is kept absent so only the fallback branch is exercised.
  @Test func token_githubTokenEmptyString_returnsNil() {
    withCleanEnv {
      withEnv("GITHUB_TOKEN", value: "") {
        #expect(makeCache().token() == nil)
      }
    }
  }

  /// Prefers GH_TOKEN over GITHUB_TOKEN when both are set.
  @Test func token_bothEnvVarsSet_prefersGhToken() {
    withCleanEnv {
      withEnv("GH_TOKEN", value: "primary-token") {
        withEnv("GITHUB_TOKEN", value: "fallback-token") {
          #expect(makeCache().token() == "primary-token")
        }
      }
    }
  }

  // MARK: - token() — cache

  /// Returns the cached value on a second call without re-reading the environment.
  @Test func token_secondCall_returnsFromCache() {
    withCleanEnv {
      let cache = makeCache()
      withEnv("GH_TOKEN", value: "cached-token") {
        _ = cache.token()  // populate cache; result discarded intentionally
      }
      // Both env vars now absent — only the in-memory cache can return a value.
      #expect(cache.token() == "cached-token")
    }
  }

  // MARK: - invalidate()

  /// Clears a populated cache so the next call re-resolves from source.
  @Test func invalidate_clearsCache() {
    withCleanEnv {
      let cache = makeCache()
      withEnv("GH_TOKEN", value: "original-token") {
        _ = cache.token()  // populate cache
      }
      cache.invalidate()
      // Cache cleared + both env vars absent + empty store — must return nil.
      #expect(cache.token() == nil)
    }
  }

  /// Safe to call when the cache is already empty — does not crash.
  @Test func invalidate_whenAlreadyEmpty_isNoop() {
    withCleanEnv {
      let cache = makeCache()
      cache.invalidate()  // must not crash on empty cache
      #expect(cache.token() == nil)
    }
  }

  // MARK: - token() — concurrent access

  /// Fifty concurrent `Task`s calling `token()` simultaneously must all return
  /// the same value with no crash or data race.
  ///
  /// `TokenCache` is not an actor — it uses `Synchronization.Mutex` for thread
  /// safety. This test validates that the Mutex guard is sufficient under
  /// genuine concurrent load: every caller must see the expected token regardless
  /// of which Task wins the first write to the cache.
  ///
  /// Mechanism:
  /// - A fresh `TokenCache` backed by a `MockTokenStore` seeded with
  ///   `"concurrent-token"` is created. The cache is initially empty.
  /// - `resolveFromStore()` has priority 2 — it is always consulted before the
  ///   env-var path. Because the store is seeded, any CI-injected GITHUB_TOKEN
  ///   or GH_TOKEN is irrelevant: the store result wins regardless of what env
  ///   vars are present. No env manipulation is needed or performed.
  /// - 50 Tasks are spawned concurrently. All of them race to call `token()`
  ///   on the same instance. Because the cache is empty on the first call,
  ///   multiple Tasks may enter `resolveFromStore()` concurrently — exactly
  ///   the thundering-herd window documented in `TokenCache.resolveFromStore()`.
  /// - `withTaskGroup` collects all 50 results.
  /// - Every result is asserted to equal `"concurrent-token"` — no nil, no
  ///   divergence, no crash.
  ///
  /// If the Mutex guard were absent (or broken), the Swift runtime's TSan
  /// instrumentation would report a data race here.
  ///
  /// - Note: The suite is `.serialized`, which prevents this test from running
  ///   concurrently with *other tests in the same suite*. That is orthogonal to
  ///   the 50 Tasks spawned inside this test body — those Tasks are intentional
  ///   intra-test concurrency exercising `TokenCache`'s thread-safety. There is
  ///   no contradiction: `.serialized` controls inter-test scheduling only.
  @Test func token_concurrentCalls_allReturnSameToken() async {
    let cache = makeCache(storeToken: "concurrent-token")
    let taskCount = 50

    let results = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
      for _ in 0 ..< taskCount {
        group.addTask { cache.token() }
      }
      var collected: [String?] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    // Every concurrent caller must receive the expected token — no nil, no divergence.
    #expect(results.count == taskCount)
    #expect(results.allSatisfy { $0 == "concurrent-token" })
  }
}
