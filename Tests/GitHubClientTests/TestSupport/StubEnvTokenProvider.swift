// StubEnvTokenProvider.swift
// GitHubClientTests/TestSupport
import Foundation
import Synchronization

@testable import GitHubClient
@testable import EnvTokenKit

// MARK: - StubEnvTokenProvider

/// A test double for `EnvTokenProviding` that returns a fixed `ShellTokenResult`
/// and never spawns a real `/bin/zsh` subprocess.
///
/// ## Why a stub rather than keeping shellResolver:
/// `TokenCache` no longer owns the shell path — it delegates steps 3+4 entirely
/// to the injected `any EnvTokenProviding`. Tests that need to control the
/// env/shell path inject a `StubEnvTokenProvider` via `TokenCache(tokenStore:, envProvider:)`.
///
/// ## callCount
/// The `callCount` Mutex lets latch tests assert exactly how many times `token()`
/// was called — matching what the old `counter` locals in `token_shellFailed_latches`
/// did with the direct `shellResolver:` closure.
///
/// ## invalidateCalled
/// Tracks whether `invalidate()` was forwarded by `TokenCache.invalidate()`, so
/// tests that verify the reset path can assert the delegation happened.
///
/// ## @testable coupling note
/// The `result` parameter is typed as `ShellTokenResult`, which is `internal` to
/// `EnvTokenKit`. This stub is only accessible because `GitHubClientTests` uses
/// `@testable import EnvTokenKit`. If `ShellTokenResult` is ever renamed or made
/// truly private, every `StubEnvTokenProvider(result:)` call site in this target
/// will break. This coupling is intentional — the stub mirrors the real
/// `EnvTokenProvider`'s outcome vocabulary exactly — but it is fragile. If the
/// coupling becomes a problem, replace `ShellTokenResult` here with a local
/// `enum StubResult { case found(String), notFound, failed }` owned by this target.
final class StubEnvTokenProvider: EnvTokenProviding, Sendable {

    /// The result returned by `token()` on every call.
    private let result: ShellTokenResult

    /// Number of times `token()` has been called.
    let callCount = Mutex<Int>(0)

    /// Whether `invalidate()` has been called at least once.
    let invalidateCalled = Mutex<Bool>(false)

    /// - Parameter result: The `ShellTokenResult` to simulate.
    ///   - `.found(value)`: `token()` returns `value`.
    ///   - `.notFound`: `token()` returns `nil` without latching.
    ///   - `.failed`: `token()` returns `nil`. The latch for `.failed` outcomes
    ///     lives entirely inside `EnvTokenProvider` — `TokenCache` does NOT latch
    ///     on any outcome. Use `callCount` to verify that `TokenCache` delegates
    ///     on every call (expected count = 2 for a two-call test, not 1).
    init(result: ShellTokenResult = .notFound) {
        self.result = result
    }

    func token() async -> String? {
        callCount.withLock { $0 += 1 }
        switch result {
        case .found(let value): return value
        case .notFound:         return nil
        case .failed:           return nil
        }
    }

    func invalidate() {
        invalidateCalled.withLock { $0 = true }
    }
}

