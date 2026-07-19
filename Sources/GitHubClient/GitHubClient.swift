// GitHubClient.swift
// GitHubClient
import Foundation

// MARK: - GitHubClient
//
// Top-level facade that owns and wires all GitHubClient components.
//
// Production consumers create a single instance and hold it for the
// app lifetime:
//
//   let github = GitHubClient(
//       clientID: "your-client-id",
//       clientSecret: "your-client-secret",
//       service: "com.example.myapp",
//       account: "github-oauth-token",
//       logger: MyLogger()
//   )
//
// Custom scopes (optional — defaults to GitHubScopes.default):
//
//   let github = GitHubClient(
//       clientID: "your-client-id",
//       clientSecret: "your-client-secret",
//       service: "com.example.myapp",
//       account: "github-oauth-token",
//       scopes: GitHubScopes.default + [GitHubScopes.readUser]
//   )
//
// Tests inject mocks via the secondary init:
//
//   let github = GitHubClient(
//       oauthService: MockOAuthService(),
//       transport: MockTransport()
//   )
//
// ## Why a facade?
//
// Without this type, `OAuthService`, `GitHubTransport`, and `TokenCache`
// are constructed independently with no shared token path:
//
// - `OAuthService` saves tokens to `KeychainTokenStore`.
// - `GitHubTransport` reads tokens via a separate closure.
// - `TokenCache` exists but is never wired into either.
//
// This facade is the single wiring point that closes all three gaps.

/// A facade that owns and wires `OAuthService`, `GitHubTransport`, and
/// `TokenCache` under a single initialiser.
///
/// Use the production init for app targets; use the test init to inject
/// protocol mocks without touching the Keychain or network.
///
/// ## Isolation
/// `GitHubClient` is `@MainActor`-isolated at the type level because
/// `oauthService` stores `any OAuthServiceProtocol` whose protocol is
/// `@MainActor`-isolated. This makes the isolation boundary compiler-enforced
/// rather than relying on call-site convention.
@MainActor
public final class GitHubClient {

    /// The OAuth service — manages sign-in, sign-out, and token persistence.
    public let oauthService: any OAuthServiceProtocol

    /// The transport — handles all authenticated GitHub API requests.
    public let transport: any GitHubTransportProtocol

    /// The token cache — held so `warmUp()` and `hasAnyToken` can delegate to it.
    /// `nil` when the test init is used (no real cache in that path).
    private let tokenCache: TokenCache?

    // MARK: - Production init

    /// Creates a fully wired `GitHubClient` backed by the macOS Keychain.
    ///
    /// Internally constructs one `KeychainTokenStore`, one `TokenCache`, one
    /// `OAuthService`, and one `GitHubTransport` — all sharing the same token
    /// path. `TokenCache.invalidate()` is called automatically after every
    /// successful sign-in and sign-out.
    ///
    /// Must be called on the main actor because `OAuthService.init` is
    /// `@MainActor`-isolated. `AppDelegate` — the only production call site —
    /// satisfies this requirement automatically.
    ///
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - service: The keychain service name (e.g. your app's bundle identifier).
    ///   - account: The keychain account name (e.g. `"github-oauth-token"`).
    ///   - scopes: The OAuth scopes to request during sign-in. Defaults to
    ///     `GitHubScopes.default`. Must not be empty. Use `GitHubScopes`
    ///     constants for type safety and discoverability.
    ///   - logger: Optional logger for diagnostic messages.
    @MainActor
    public init(
        clientID: String,
        clientSecret: String,
        service: String,
        account: String,
        scopes: [String] = GitHubScopes.default,
        logger: (any GitHubLogger)? = nil
    ) {
        let store = KeychainTokenStore(service: service, account: account, logger: logger)
        let cache = TokenCache(tokenStore: store, logger: logger)
        let oauth = OAuthService(
            clientID: clientID,
            clientSecret: clientSecret,
            tokenStore: store,
            scopes: scopes,
            logger: logger,
            session: URLSession.shared,
            onTokenSaved: { cache.invalidate() },
            onTokenDeleted: { cache.invalidate() }
        )
        let transport = GitHubTransport(
            tokenProvider: { cache.token() },
            logger: logger
        )
        // Write through the internal backing store to avoid triggering the
        // #DeprecatedDeclaration warning on the public `sharedGitHubTransport` alias.
        sharedTransportStorage = transport
        self.oauthService = oauth
        self.transport = transport
        self.tokenCache = cache
    }

    // MARK: - Test init

    /// Creates a `GitHubClient` with injected protocol mocks.
    ///
    /// Use in tests to avoid Keychain or network access. Inject a
    /// `MockOAuthService` and `MockTransport` at whatever granularity
    /// the test requires.
    ///
    /// Intentionally nonisolated — it only assigns protocol existentials
    /// and never calls any `@MainActor`-isolated code directly.
    ///
    /// - Note: Does **not** accept a `scopes:` parameter — it takes
    ///   `any OAuthServiceProtocol` directly, which already encapsulates
    ///   scope configuration. No changes needed here.
    ///
    /// - Parameters:
    ///   - oauthService: A mock or stub conforming to `OAuthServiceProtocol`.
    ///   - transport: A mock or stub conforming to `GitHubTransportProtocol`.
    public init(
        oauthService: any OAuthServiceProtocol,
        transport: any GitHubTransportProtocol
    ) {
        self.oauthService = oauthService
        self.transport = transport
        self.tokenCache = nil
    }

    // MARK: - Token warm-up

    /// Pre-populates the token cache by sourcing the user's login shell environment.
    ///
    /// Call this once during app startup **before** the first poll fires (e.g. as the
    /// first `await` in `AppState.start()`). This bridges the macOS GUI app limitation
    /// where `launchd`-spawned processes do not inherit the user's shell environment
    /// and `GH_TOKEN` / `GITHUB_TOKEN` are therefore absent from `ProcessInfo`.
    ///
    /// This is a no-op when:
    /// - The cache is already populated (Keychain OAuth token present)
    /// - The app was launched from a terminal (token already in `ProcessInfo`)
    /// - The test init was used (no `TokenCache` in that path)
    ///
    /// See `TokenCache.warmUp()` for full implementation details.
    public func warmUp() async {
        await tokenCache?.warmUp()
    }

    // MARK: - Token availability

    /// `true` when any usable GitHub token is available — OAuth token,
    /// `GH_TOKEN`, or `GITHUB_TOKEN` environment variable.
    ///
    /// Unlike `OAuthService.hasAnyToken`, this check goes through `TokenCache`
    /// and therefore reflects tokens recovered via `warmUp()` (login shell
    /// resolution). Call this after `warmUp()` has completed for accurate results
    /// in GUI app launch contexts where `ProcessInfo` does not contain the token.
    ///
    /// Falls back to `oauthService.hasAnyToken` when the test init is used
    /// (no `TokenCache` in that path).
    public var hasAnyToken: Bool {
        if let cache = tokenCache {
            return cache.token() != nil
        }
        return oauthService.hasAnyToken
    }
}
