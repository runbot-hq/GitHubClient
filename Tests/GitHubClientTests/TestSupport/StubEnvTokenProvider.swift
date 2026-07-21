// StubEnvTokenProvider.swift
// GitHubClientTests/TestSupport
import Foundation
import Synchronization

@testable import GitHubClient
import EnvTokenKit

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
    ///   - `.failed`: `token()` returns `nil` and latches (caller
    ///     must implement latch logic; `StubEnvTokenProvider` itself
    ///     does NOT latch — use `callCount` to verify the caller latches).
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

// MARK: - NullEnvTokenProvider

/// A no-op `EnvTokenProviding` stub that always returns `nil` and ignores
/// `invalidate()`. Injected by test helpers that only exercise steps 1–2
/// of the resolution chain (cache and store) and have no interest in
/// the env/shell path at all.
final class NullEnvTokenProvider: EnvTokenProviding, Sendable {
    func token() async -> String? { nil }
    func invalidate() {}
}
