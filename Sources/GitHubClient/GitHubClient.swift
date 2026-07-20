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
// Tests inject mocks via the secondary init:
//
//   let github = GitHubClient(
//       oauthService: MockOAuthService(),
//       transport: MockTransport()
//   )

/// A facade that owns and wires `OAuthService`, `GitHubTransport`, and
/// `TokenCache` under a single initialiser.
///
/// Use the production init for app targets; use the test init to inject
/// protocol mocks without touching the Keychain or network.
///
/// ## Isolation
/// `GitHubClient` is `@MainActor`-isolated at the type level because
/// `oauthService` stores `any OAuthServiceProtocol` whose protocol is
/// `@MainActor`-isolated.
@MainActor
public final class GitHubClient {

    /// The OAuth service — manages sign-in, sign-out, and token persistence.
    public let oauthService: any OAuthServiceProtocol

    /// The transport — handles all authenticated GitHub API requests.
    public let transport: any GitHubTransportProtocol

    /// The in-memory token cache shared between `oauthService` and `transport`.
    ///
    /// Exposed so that callers can read `cachedToken` synchronously to reflect
    /// the current resolved token state in UI without going `async`.
    /// Do not call `invalidate()` directly — that is handled automatically by
    /// the `onTokenSaved` / `onTokenDeleted` callbacks wired in `init`.
    public let tokenCache: TokenCache

    // MARK: - Production init

    /// Creates a fully wired `GitHubClient` backed by the macOS Keychain.
    ///
    /// Internally constructs one `KeychainTokenStore`, one `TokenCache`, one
    /// `OAuthService`, and one `GitHubTransport` — all sharing the same token
    /// path. `TokenCache.invalidate()` is called automatically after every
    /// successful sign-in and sign-out.
    ///
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - service: The keychain service name.
    ///   - account: The keychain account name.
    ///   - scopes: The OAuth scopes to request. Defaults to `GitHubScopes.default`.
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
            // Both callbacks call invalidate() so the next token() call re-resolves
            // from the store after any credential change. Side-effect: a user whose
            // shell is broken (.failed latch) will re-spawn /bin/zsh on the next
            // token() call after *both* sign-in and sign-out — not just sign-out.
            // Low-frequency and intentional; tracked in #68.
            onTokenSaved: { cache.invalidate() },
            onTokenDeleted: { cache.invalidate() }
        )
        let transport = GitHubTransport(
            tokenProvider: { await cache.token() },
            logger: logger
        )
        // ⚠️ NOT a dead assignment — this is load-bearing module wiring.
        // sharedTransportStorage is the backing var read by currentTransport
        // (GitHubTransportShims.swift). Every free-function shim in the module
        // (ghAPI, ghPost, cancelRun, deleteRunnerByID, etc.) resolves its
        // transport via `currentTransport`, which falls back to
        // sharedTransportStorage when no @TaskLocal override is in scope.
        // Without this write, every shim call in a production app would use
        // the default no-token GitHubTransport() constructed at module load —
        // all API calls would return 401 until the user re-launches.
        // Periphery / compiler "assigned but never read" warnings are false
        // positives here: the value IS read, just indirectly through
        // currentTransport in a different file.
        sharedTransportStorage = transport
        self.oauthService = oauth
        self.transport = transport
        self.tokenCache = cache
    }

    // MARK: - Test init

    /// Creates a `GitHubClient` with injected protocol mocks.
    ///
    /// Accepts `any OAuthServiceProtocol` and `any GitHubTransportProtocol`
    /// directly, so the caller controls all behaviour at mock-construction time.
    ///
    /// WHY NO `scopes:` PARAMETER:
    /// The production init accepts `scopes:` to pass them through to
    /// `OAuthService`. The test init bypasses `OAuthService` entirely — the
    /// caller passes a fully-constructed mock, which already encodes whatever
    /// scope behaviour the test requires. Adding `scopes:` here would be
    /// misleading: there is no `OAuthService` to forward them to, and a test
    /// author who adds scopes expecting OAuth behaviour would get a silent no-op.
    public init(
        oauthService: any OAuthServiceProtocol,
        transport: any GitHubTransportProtocol,
        tokenCache: TokenCache = TokenCache(tokenStore: NullTokenStore())
    ) {
        self.oauthService = oauthService
        self.transport = transport
        self.tokenCache = tokenCache
    }
}
