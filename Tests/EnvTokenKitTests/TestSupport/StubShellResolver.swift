// StubShellResolver.swift
// EnvTokenKitTests/TestSupport
//
// Lightweight helpers for constructing stubbed shell resolvers in
// EnvTokenKitTests. These are simple free functions — not a full class —
// because EnvTokenProvider's `shellResolver` seam is already a closure;
// no wrapper type is needed.
//
// Use these when you need call-count tracking or want to express the
// resolver result inline at the call site. For tests that only need a
// fixed result without counting calls, pass the closure literal directly:
//   EnvTokenProvider(shellResolver: { _ in .notFound })

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
