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
//
// token() is now async — all call sites use `await`. withCleanEnv has both a
// sync overload (for non-async tests that only mutate env, not call token()) and
// an async overload (for tests that call token()). The async overload is used by
// all tests that call token() or invalidate().

import Foundation
import Testing

@testable import GitHubClient

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
/// Sync overload — used when body does not call token().
private func withCleanEnv(_ body: () -> Void) {
  let prevGH = ProcessInfo.processInfo.environment["GH_TOKEN"]
  let prevGitHub = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
  unsetenv("GH_TOKEN")
  unsetenv("GITHUB_TOKEN")
  body()
  if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
  if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Async overload — used when body calls token() or other async cache methods.
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
/// Sync overload.
private func withEnv(_ key: String, value: String, _ body: () -> Void) {
  let previous = ProcessInfo.processInfo.environment[key]
  setenv(key, value, 1)
  body()
  if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

/// Sets one env var for the duration of body, then restores the previous value.
/// Async overload — used when body calls token().
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
  private func makeCache(storeToken: String? = nil) -> TokenCache {
    TokenCache(tokenStore: MockTokenStore(initial: storeToken))
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
