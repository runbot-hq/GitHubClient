// EnvTokenProviding.swift
// EnvTokenKit

// MARK: - EnvTokenProviding
//
// Abstraction over the env-var + login-shell token resolution path.
// The protocol lives permanently in EnvTokenKit; TokenCache in GitHubClient
// depends on it via the EnvTokenKit product dependency in Package.swift.

/// Abstraction over a token provider that resolves `GH_TOKEN` / `GITHUB_TOKEN`
/// from the process environment or a login-shell subprocess.
///
/// ## Why a protocol and not a closure?
/// A single `() async -> String?` closure would be sufficient for the
/// `token()` direction, but `invalidate()` needs a paired reset signal so
/// `TokenCache` can propagate sign-in / sign-out events down to the shell
/// outcome latch in `EnvTokenProvider`. Two closures would work but require
/// more bookkeeping at the call site and make the relationship between the
/// two operations less explicit. A named protocol groups them, documents their
/// contract, and gives test authors a single type to stub.
///
/// ## Sendable requirement
/// `TokenCache` is `Sendable` (it wraps all mutable state in a `Mutex`).
/// Any `EnvTokenProviding` stored inside it must therefore also be `Sendable`.
/// `EnvTokenProvider` satisfies this via its own `Mutex`-guarded state.
/// Test stubs satisfy it by using only immutable (`let`) stored properties
/// or actor-isolated state.
///
/// ## Adopted by
/// - `EnvTokenProvider` (production, lives in `EnvTokenKit`)
/// - Test stubs in `EnvTokenKitTests` and `GitHubClientTests`
public protocol EnvTokenProviding: Sendable {

    /// Resolves a token from the process environment or login shell.
    ///
    /// Resolution order:
    /// 1. `GH_TOKEN` in `ProcessInfo.processInfo.environment`
    /// 2. `GITHUB_TOKEN` in `ProcessInfo.processInfo.environment`
    /// 3. Login-shell subprocess (`/bin/zsh -i -l`) for Finder/Dock launches
    ///    where the process environment does not inherit shell exports.
    ///
    /// Returns `nil` if no token is available from any source, or if the
    /// login-shell path has latched to `.failed` after a prior timeout or
    /// launch error. See `ShellResolutionOutcome` in `EnvTokenProvider` for
    /// the full latch policy.
    ///
    /// ## Caching behaviour
    /// `EnvTokenProvider` caches a successful shell result internally.
    /// When `token()` resolves a value via the login-shell path, it writes
    /// that value to the `ShellResolutionOutcome.found` state under a `Mutex`.
    /// Subsequent calls short-circuit at that latch and return the cached value
    /// without re-spawning `/bin/zsh`. Calling `invalidate()` clears the latch
    /// so the next `token()` call re-runs the full resolution chain.
    ///
    /// This means `EnvTokenProvider` is **not** stateless — it is designed to
    /// be used directly or wrapped in `TokenCache`. In the production wiring,
    /// `TokenCache` provides an additional `String?` layer that short-circuits
    /// before even reaching `EnvTokenProvider.token()`. If you are consuming
    /// `EnvTokenKit` as a standalone library product, `EnvTokenProvider` will
    /// cache the first resolved shell token automatically; call `invalidate()`
    /// after a sign-out or credential rotation to force re-resolution.
    ///
    /// - Warning: Concurrent callers can each spawn a separate `/bin/zsh`
    ///   subprocess during the window before the first shell result is cached
    ///   (up to 10 s). The concrete `EnvTokenProvider` is safe today because
    ///   `RunnerPoller` calls it serially, but any conformer or caller that
    ///   invokes `token()` concurrently from multiple tasks should be aware of
    ///   this window. See `EnvTokenProvider.token()` for the full rationale.
    func token() async -> String?

    /// Resets all internal state so the next `token()` call re-runs the full
    /// resolution chain from scratch.
    ///
    /// Called by `TokenCache` after every successful sign-in and sign-out so
    /// that a credential change is reflected immediately on the next `token()`
    /// call rather than served from a stale latch.
    ///
    /// `nonisolated` is intentional: `TokenCache.invalidate()` is itself
    /// `nonisolated` and must call this synchronously without an `await`.
    /// Conforming types on a `@MainActor` class must explicitly add
    /// `nonisolated` to their implementation; omitting it produces a silent
    /// actor hop and breaks the synchronous call chain at runtime.
    nonisolated func invalidate()
}
