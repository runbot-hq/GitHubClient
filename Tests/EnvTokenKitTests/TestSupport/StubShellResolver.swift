// StubShellResolver.swift
// EnvTokenKitTests
import Synchronization
@testable import EnvTokenKit

/// Returns a shell resolver closure that always returns `result` and
/// increments `counter` on each invocation.
///
/// `counter` is taken by value (not `borrowing`) so the returned
/// `@Sendable` closure can capture it. `Mutex` is `Sendable` and
/// non-copyable; passing by value transfers ownership into the closure.
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
    { _ in
        counter.withLock { $0 += 1 }
        return result
    }
}
