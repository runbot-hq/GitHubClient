// EnvTokenProviding.swift
// EnvTokenKit

// MARK: - EnvTokenProviding
//
// Abstraction over the env-var + login-shell token resolution path.
//
// Introduced as part of the EnvTokenKit extraction (see #73 / #74).
// Adding the protocol here first (Step 1) means TokenCache can grow
// the injection seam (Step 2) before the concrete EnvTokenProvider
// type exists in its own target (Step 3). This keeps each step
// independently buildable with no dangling references.

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
    func invalidate()
}
