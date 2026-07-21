// StubShellResolver.swift
// GitHubClient
import Synchronization
@testable import EnvTokenKit

/// Returns a shell resolver closure that always returns `result` and
/// increments `counter` on each invocation.
///
/// ## Usage
///     let counter = Mutex<Int>(0)
///     let provider = EnvTokenProvider(
///         shellResolver: countingResolver(returning: .failed, counter: counter)
///     )
func countingResolver(
    returning result: ShellTokenResult,
    counter: Mutex<Int>
) -> @Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult {
    { _ in
        counter.withLock { $0 += 1 }
        return result
    }
}
