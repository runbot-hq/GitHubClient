// GitHubClient.swift
// GitHubClient

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
// Custom scopes (optional — defaults to OAuthService.defaultScopes):
//
//   let github = GitHubClient(
//       clientID: "your-client-id",
//       clientSecret: "your-client-secret",
//       service: "com.example.myapp",
//       account: "github-oauth-token",
//       scopes: [GitHubScopes.repo, GitHubScopes.readUser]
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

    // MARK: - Production init

    /// Creates a fully wired `GitHubClient` backed by the macOS Keychain.
    ///
    /// Internally constructs one `KeychainTokenStore`, one `TokenCache`, one
    /// `OAuthService`, and one `GitHubTransport` — all sharing the same token
    /// path. `TokenCache.invalidate()` is called automatically after every
    /// successful sign-in and sign-out.
    ///
    /// Currently wires the transport via the deprecated `sharedGitHubTransport`
    /// alias. There is no `didSet` — the write-through is implicit: `currentTransport`
    /// is a computed property that reads `_taskLocalTransport ?? sharedGitHubTransport`
    /// at call time, so assigning `sharedGitHubTransport` here is immediately
    /// visible at every subsequent `currentTransport` access.
    ///
    /// The final migration step — replacing this assignment with
    /// `withTransport(transport) { ... }` scoping in `AppDelegate` — is
    /// tracked in #25 and requires a coordinated change in `RunBotCore`.
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
    ///     `OAuthService.defaultScopes`. Must not be empty. Use `GitHubScopes`
    ///     constants for type safety and discoverability.
    ///   - logger: Optional logger for diagnostic messages.
    @MainActor
    public init(
        clientID: String,
        clientSecret: String,
        service: String,
        account: String,
        scopes: [String] = OAuthService.defaultScopes,
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
            session: .shared,
            onTokenSaved: { cache.invalidate() },
            onTokenDeleted: { cache.invalidate() }
        )
        let transport = GitHubTransport(
            tokenProvider: { cache.token() },
            logger: logger
        )
        // Temporarily writes via the deprecated sharedGitHubTransport alias.
        // There is no didSet on sharedGitHubTransport — write-through is implicit.
        // currentTransport is a computed property: `_taskLocalTransport ?? sharedGitHubTransport`.
        // Assigning here makes the new transport immediately visible at the next
        // currentTransport access, with no observer or side-effect involved.
        // Replace with withTransport(transport) { ... } in AppDelegate
        // once RunBotCore is ready (see #25).
        sharedGitHubTransport = transport
        self.oauthService = oauth
        self.transport = transport
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
    /// ⚠️ Callers must pass a `@MainActor`-isolated mock for `oauthService`
    /// to satisfy `OAuthServiceProtocol`'s `@MainActor` constraint. A mock
    /// that is not `@MainActor`-isolated will not compile.
    ///
    /// - Note: Does **not** touch `sharedGitHubTransport`. Test call sites
    ///   always pass `transport:` explicitly at the API function call site
    ///   and must never rely on the global.
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
    }
}
