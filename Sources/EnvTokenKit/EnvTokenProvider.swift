// EnvTokenProvider.swift
// EnvTokenKit
import Foundation
import Synchronization

// MARK: - ShellResolutionOutcome

/// Records the outcome of the most recent login-shell resolution attempt.
///
/// Stored inside `EnvTokenProvider.state` alongside the shell outcome so
/// reads and writes are always consistent under the same `Mutex`.
///
/// ## Why an enum instead of a Bool
/// The previous `shellFailed: Bool` flag collapsed two semantically distinct
/// outcomes — “shell ran but found no export” and “shell failed to launch or
/// timed out” — into a single latch. Both set the flag to `true`, permanently
/// blocking re-entry for the process lifetime. That is correct for `.failed`
/// (retrying a broken shell every 30 s is wasteful) but wrong for `.notFound`
/// (an OAuth-only user who later adds `GH_TOKEN` to their profile should not
/// need a relaunch to pick it up). The enum makes the policy explicit:
/// only `.failed` latches; `.notFound` allows re-entry on the next call.
enum ShellResolutionOutcome {
    /// No shell attempt has been made yet this provider lifetime.
    case notAttempted
    /// The shell launched and ran successfully but found no `GH_TOKEN` or
    /// `GITHUB_TOKEN` export. The shell path is NOT latched — `token()` will
    /// re-enter it on the next call, allowing the user to add an export
    /// without relaunching the app.
    ///
    /// ## Why not collapse this into `.notAttempted`
    /// Observable behaviour is identical today: both cases allow re-entry.
    /// The distinction is preserved for two reasons:
    /// 1. Diagnostics — logging and future telemetry can distinguish “never
    ///    tried” from “tried and found nothing”, which helps triage user
    ///    reports without needing a separate flag.
    /// 2. Future policy — a `.notFound`-specific cooldown (e.g. re-enter at
    ///    most once per 60 s rather than on every poll cycle) could be added
    ///    here without a schema change. Collapsing to `.notAttempted` would
    ///    require a new case or a separate field at that point.
    ///
    /// ## Poll cost for Finder-launch users with no token export
    /// Any Finder-launch user with no `GH_TOKEN` export — OAuth-only users
    /// included — reaches this path on every poll cycle (~30 s) and re-spawns
    /// `/bin/zsh`. This is a known accepted cost: the shell exits quickly
    /// (~50–200 ms on a light config) and the user is unblocked the moment
    /// they add an export without relaunching. The cooldown described in
    /// point 2 above is the right long-term fix and is a schema-free addition
    /// when the cost proves unacceptable in practice.
    ///
    /// ## Why .notFound is NOT latched like .failed
    /// Any Finder-launch user with no `GH_TOKEN` export — OAuth-only users
    /// included — reaches this path on every poll cycle. The decision not to
    /// latch is deliberate: latching `.notFound` like `.failed` would prevent
    /// a user who later adds an export from picking it up without a
    /// sign-out/sign-in cycle, defeating the feature’s core promise.
    /// OAuth users launched from a terminal do NOT reach step 4 (step 3
    /// resolves from `ProcessInfo`), but OAuth users launched from Finder
    /// with no export DO. The per-cycle shell cost is real and acknowledged;
    /// the cooldown in issue #68 is the right bounded mitigation — not a
    /// session latch that silently breaks the UX for the users this feature
    /// is designed to help.
    case notFound  // TODO: #68 — add a timestamp-based cooldown so .notFound does not re-spawn /bin/zsh on every poll cycle (~30 s) for Finder-launch users with no token export
    /// The shell timed out, failed to launch, or was blocked by the App Sandbox.
    /// The shell path IS latched — `token()` short-circuits before the shell
    /// on every subsequent call until `invalidate()` resets the outcome.
    /// Retrying a broken or sandbox-blocked shell every poll cycle (~30 s)
    /// would be a persistent background thread burn with no benefit; the user
    /// must take explicit action (fix `~/.zprofile`, remove the sandbox
    /// entitlement, or sign in via OAuth) before a retry is useful.
    case failed
}

/// Resolves `GH_TOKEN` / `GITHUB_TOKEN` from the process environment or a
/// login-shell subprocess, and exposes the result via `EnvTokenProviding`.
///
/// Injected into `TokenCache` in `GitHubClient`. `TokenCache` never names
/// this type — it only knows `any EnvTokenProviding`. The concrete type is
/// constructed exclusively in `GitHubClient.swift` at wiring time.
///
/// All mutable state is guarded by a `Mutex` for thread safety.
public final class EnvTokenProvider: EnvTokenProviding, Sendable {

    /// Optional log closure bridged from `GitHubLogger` by `GitHubClient.swift`.
    /// `EnvTokenKit` never depends on `GitHubLogger` directly — the closure
    /// bridge keeps the kit self-contained.
    private let log: (@Sendable (String, String) -> Void)?

    /// Resolves a token via the login shell.
    ///
    /// Defaults to the real `loginShellToken` free function. Overridable in
    /// tests via the `shellResolver` init parameter so test suites never spawn
    /// a real `/bin/zsh` subprocess — avoiding the 10-second timeout on
    /// nil-path tests and keeping the suite fast on both local and CI runners.
    private let shellResolver: @Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult

    /// Reads a single environment variable by key.
    ///
    /// Defaults to `ProcessInfo.processInfo.environment[key]` in production.
    /// Overridable in tests via the `envLookup` init parameter so tests that
    /// exercise the shell-fallback path never touch the live process environment
    /// — eliminating the cross-suite `setenv`/`unsetenv` race on CI where
    /// `GITHUB_TOKEN` is always present in the runner environment.
    private let envLookup: @Sendable (String) -> String?

    /// Shell outcome state guarded by a `Mutex`.
    ///
    /// Tracks the result of the last login-shell attempt.
    /// See `ShellResolutionOutcome` for the per-case latch policy.
    private let state = Mutex<ShellResolutionOutcome>(.notAttempted)

    /// Production init. `log` is bridged from `GitHubLogger` by `GitHubClient.swift`.
    public convenience init(log: (@Sendable (String, String) -> Void)? = nil) {
        self.init(log: log, shellResolver: nil, envLookup: nil)
    }

    /// Test init — exposes `shellResolver` and `envLookup` seams so tests never
    /// spawn real `/bin/zsh` and never touch the live process environment.
    ///
    /// - Parameters:
    ///   - log: Optional log closure.
    ///   - shellResolver: Overrides login-shell resolution. Defaults to the real
    ///     `loginShellToken` free function.
    ///   - envLookup: Overrides environment variable lookup. Defaults to
    ///     `ProcessInfo.processInfo.environment[key]`. Pass `{ _ in nil }` in
    ///     tests that exercise the shell-fallback path to avoid any dependency
    ///     on the live process environment.
    init(
        log: (@Sendable (String, String) -> Void)? = nil,
        shellResolver: (@Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult)? = nil,
        envLookup: (@Sendable (String) -> String?)? = nil
    ) {
        self.log = log
        self.shellResolver = shellResolver ?? { log in await loginShellToken(log: log) }
        self.envLookup = envLookup ?? { key in ProcessInfo.processInfo.environment[key] }
    }

    // MARK: - EnvTokenProviding

    /// Resolves a token from `ProcessInfo` or a login-shell subprocess.
    ///
    /// Resolution order:
    /// 1. `GH_TOKEN` in `ProcessInfo.processInfo.environment`
    /// 2. `GITHUB_TOKEN` in `ProcessInfo.processInfo.environment`
    /// 3. Login-shell subprocess (`/bin/zsh -i -l`) — Finder/Dock launches only
    ///
    /// ## Shell latch policy
    /// - `.notAttempted`: shell is spawned normally.
    /// - `.notFound`: shell ran but found no export — NOT latched. Re-entry
    ///   allowed so the user can add an export without relaunching.
    /// - `.failed`: shell timed out or failed to launch — IS latched until
    ///   `invalidate()` resets the outcome.
    ///
    /// - Warning: Concurrent callers that simultaneously miss the ProcessInfo
    ///   fast path will each spawn a separate `/bin/zsh` subprocess. The latch
    ///   is not set until `loginShellToken` returns (up to 10 s), so the window
    ///   spans the full shell execution time, not just a scheduling instant.
    ///   Correctness is preserved — the Mutex guard in `token()` prevents a
    ///   double-write. Safe in practice: `RunnerPoller` is a single serial actor.
    public func token() async -> String? {
        if let envToken = resolveFromEnvironment() { return envToken }
        if case .failed = state.withLock({ $0 }) { return nil }
        // All fast paths missed — cold Finder/Dock/login-item launch.
        // Spawn the login shell to source ~/.zprofile and ~/.zshrc.
        // ⚠️ No atomic entry claim: concurrent callers each spawn a separate
        // /bin/zsh — the latch is not set until loginShellToken returns.
        // Safe today (RunnerPoller is serial); see -Warning: above.
        let shellResult = await shellResolver(log)
        switch shellResult {
        case .found(let value):
            return value
        case .notFound:
            // Shell ran fine but no token was exported.
            // Do NOT latch — allow re-entry. See ShellResolutionOutcome.notFound.
            state.withLock { $0 = .notFound }
            return nil
        case .failed:
            // Shell timed out, failed to launch, or was blocked by the sandbox.
            // Latch to prevent re-spawning on every poll cycle. See .failed.
            state.withLock { $0 = .failed }
            return nil
        }
    }

    /// Resets the shell outcome latch to `.notAttempted` so the next `token()`
    /// call re-enters the full resolution chain.
    ///
    /// Called by `TokenCache.invalidate()` after sign-out so a sign-in cycle
    /// gets a fresh shell attempt even if the previous one timed out.
    ///
    /// Resetting `shellOutcome` here is intentional: a sign-out / sign-in cycle
    /// should get exactly one fresh shell attempt on the next `token()` call,
    /// even if the previous attempt timed out. Without this reset the user would
    /// be permanently locked out of the shell path for the process lifetime after
    /// a single `.failed` outcome, regardless of whether they subsequently fix
    /// their `~/.zshrc` or reduce its startup cost.
    public func invalidate() {
        state.withLock { $0 = .notAttempted }
        log?("EnvTokenProvider › invalidate — shell outcome reset", "transport")
    }

    // MARK: - Private helpers

    /// Reads `GH_TOKEN` or `GITHUB_TOKEN` via the injected `envLookup` closure.
    ///
    /// In production `envLookup` reads `ProcessInfo.processInfo.environment`.
    /// In tests it can be stubbed to return a fixed value or nil, eliminating
    /// any dependency on the live process environment.
    ///
    /// ## Why GH_TOKEN is checked before GITHUB_TOKEN
    /// Both variables resolve the same credential. `GH_TOKEN` is the shorter,
    /// preferred form documented in the README. Checking it first means a user
    /// who sets both gets the expected one without any silent override.
    private func resolveFromEnvironment() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let value = envLookup(key), !value.isEmpty {
                #if DEBUG
                log?("EnvTokenProvider › resolved from env var \(key) (len=\(value.count))", "transport")
                #endif
                return value
            }
            #if DEBUG
            log?("EnvTokenProvider › env var \(key): nil/empty", "transport")
            #endif
        }
        return nil
    }
}
