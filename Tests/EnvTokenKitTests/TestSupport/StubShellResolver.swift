// StubShellResolver.swift
// EnvTokenKitTests
import Synchronization
@testable import EnvTokenKit

/// Returns a shell resolver closure that always returns `result` and
/// increments `counter` on each invocation.
///
/// `counter` is consumed into a local `let` before the closure is formed so
/// the `@Sendable` closure captures the local binding, not the parameter.
/// `Mutex` is `Sendable`, so the capture is safe across concurrency domains.
///
/// ## Usage
///     let counter = Mutex<Int>(0)
///     let provider = EnvTokenProvider(
///         shellResolver: countingResolver(returning: .failed, counter: counter)
///     )
func countingResolver(
    returning result: ShellTokenResult,
    counter: consuming Mutex<Int>
) -> @Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult {
    let _counter = consume counter
    return { _ in
        _counter.withLock { $0 += 1 }
        return result
    }
}
