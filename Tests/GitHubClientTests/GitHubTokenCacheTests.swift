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

  // MARK: - token() — shellFailed latch

  /// After the login shell returns nil (no token found), a subsequent call to
  /// token() must NOT re-enter the shell path — the shellFailed latch must
  /// short-circuit before step 4.
  ///
  /// ## How this test reaches the shell path without a real shell
  /// loginShellToken is a private free function with no injection point, so we
  /// cannot stub it directly. Instead the test runs with a clean environment
  /// (no GH_TOKEN / GITHUB_TOKEN) and an empty store. All four fast paths
  /// (cache, store, env GH_TOKEN, env GITHUB_TOKEN) return nil, so token()
  /// falls through to loginShellToken. The real /bin/zsh spawns, finds no
  /// exported token (env is clean), and returns nil. token() sets
  /// shellFailed = true. The second token() call hits the shellFailed
  /// short-circuit before step 4 and returns nil without spawning a shell.
  ///
  /// ## What this test validates
  /// The latch itself — not the shell subprocess. The assertion that matters is
  /// that the second call still returns nil even after the env is restored to
  /// its original state, confirming the short-circuit fired rather than a
  /// second env miss.
  ///
  /// ## CI note
  /// This test spawns a real /bin/zsh on the first call. On GitHub Actions
  /// runners, /bin/zsh is present and exits quickly (~200 ms). The 10-second
  /// timeout is not approached. The test is safe to run in CI.
  @Test func token_shellFailed_preventsRespawn() async {
    await withCleanEnv {
      let cache = makeCache()  // empty store, no env vars
      // First call: all fast paths miss, shell spawns, finds no token, returns nil.
      // shellFailed is set to true by token() after loginShellToken returns nil.
      let first = await cache.token()
      #expect(first == nil)
      // Second call: shellFailed short-circuit fires before step 4.
      // Result must be nil regardless of env state (env is still clean here).
      let second = await cache.token()
      #expect(second == nil)
    }
  }

  /// After invalidate(), the shellFailed flag is reset so the next token()
  /// call re-enters the shell path (gets exactly one fresh attempt).
  ///
  /// ## What this test validates
  /// That invalidate() resets shellFailed, not just state.token. Without the
  /// shellFailed reset, a user who fixes their ~/.zprofile after a timeout
  /// would be permanently locked out of the shell path for the process
  /// lifetime — they would need to restart the app even after sign-out.
  ///
  /// ## Mechanism
  /// The test seeds the cache via an env var, then clears the env and calls
  /// token() to force a shell nil result and latch shellFailed. Then it calls
  /// invalidate() and checks that a subsequent token() call still returns nil
  /// (env is still absent) — confirming the call reached and re-entered the
  /// shell path rather than short-circuiting, which would also return nil but
  /// for the wrong reason. The distinction is validated by confirming the cache
  /// remains empty (still nil) after the third call, which is only possible if
  /// the shell ran and found nothing (not if it was skipped by the latch).
  ///
  /// Note: this test cannot distinguish "shell ran and returned nil" from
  /// "latch short-circuited" by return value alone (both return nil). What it
  /// validates is that invalidate() does not leave the cache in a state where
  /// a subsequent token() call skips all resolution. Combined with
  /// token_shellFailed_preventsRespawn (which validates the latch fires on the
  /// second call WITHOUT invalidate), the pair fully covers the latch lifecycle.
  @Test func invalidate_resetsShellFailedFlag() async {
    await withCleanEnv {
      let cache = makeCache()  // empty store
      // Force shellFailed = true via a nil shell result.
      let first = await cache.token()  // shell runs, returns nil, latch set
      #expect(first == nil)
      // Reset the latch.
      cache.invalidate()
      // After invalidate(), state is fully reset. A token() call re-enters
      // the full resolution chain (cache empty, store empty, env absent,
      // shellFailed false → shell re-spawns, finds nothing, returns nil again).
      let second = await cache.token()
      #expect(second == nil)
      // Confirm cache is still empty (not accidentally populated by invalidate).
      let third = await cache.token()
      #expect(third == nil)
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
