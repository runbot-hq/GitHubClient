// GitHubClient.swift
// GitHubClient
internal import EnvTokenKit
import Foundation
internal import OAuthTokenKit

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
// Custom redirect URI (optional — defaults to OAuthService.defaultRedirectURI):
//
//   let github = GitHubClient(
//       clientID: "your-client-id",
//       clientSecret: "your-client-secret",
//       service: "com.example.myapp",
//       account: "github-oauth-token",
//       redirectURI: "myapp-staging://oauth/callback"
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
    /// Kept private to prevent callers from invoking `invalidate()` or `token()`
    /// directly — both operations are managed internally via the
    /// `onTokenSaved` / `onTokenDeleted` callbacks wired in `init`.
    /// Use `cachedToken` for read-only UI status checks.
    private let _tokenCache: TokenCache

    /// The token that the in-memory cache has already resolved, or `nil` if no
    /// `token()` call has completed yet during this process lifetime.
    ///
    /// This is a **synchronous, zero-I/O** read — it never spawns a login shell,
    /// reads the Keychain, or checks environment variables. It reflects only what
    /// a prior `token()` call has already resolved.
    ///
    /// ## Typical use
    /// UI code that needs to show an auth-status indicator without going `async`
    /// can read this property after at least one `token()` call has completed
    /// (e.g. from a `.task` modifier that awaits `token()` on appear).
    public var cachedToken: String? { _tokenCache.cachedToken }

    /// Resolves and returns the current token, running the full resolution chain
    /// if needed (Keychain → environment → login-shell fallback).
    ///
    /// This is the same path used by every authenticated API call. Call it from
    /// a `.task` modifier or other async context to warm the cache and then read
    /// `cachedToken` synchronously for UI status checks.
    public func token() async -> String? {
        await _tokenCache.token()
    }

    // MARK: - Production init

    /// Creates a fully wired `GitHubClient` backed by the macOS Keychain.
    ///
    /// Internally constructs one `KeychainTokenStore`, one `EnvTokenProvider`,
    /// one `TokenCache`, one `OAuthService`, and one `GitHubTransport` — all
    /// sharing the same token path. `TokenCache.invalidate()` is called
    /// automatically after every successful sign-in and sign-out, which resets
    /// both the in-memory token cache and `EnvTokenProvider`'s shell outcome latch.
    ///
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - service: The keychain service name (e.g. your app's bundle identifier).
    ///   - account: The keychain account name (e.g. `"github-oauth-token"`).
    ///   - scopes: The OAuth scopes to request during sign-in. Defaults to
    ///     `GitHubScopes.default`. Must not be empty. Use `GitHubScopes`
    ///     constants for type safety and discoverability.
    ///   - redirectURI: The OAuth redirect URI sent to GitHub during authorisation.
    ///     Defaults to `OAuthService.defaultRedirectURI` (`runbot://oauth/callback`).
    ///     Override for staging environments, white-label builds, or a second OAuth app.
    ///     Existing call sites are unaffected — omitting this parameter preserves current behaviour.
    ///   - logger: Optional logger for diagnostic messages.
    @MainActor
    public init(
        clientID: String,
        clientSecret: String,
        service: String,
        account: String,
        scopes: [String] = GitHubScopes.default,
        redirectURI: String = OAuthService.defaultRedirectURI,
        logger: (any GitHubLogger)? = nil
    ) {
        let log: (@Sendable (String, String) -> Void)? = logger.map { lg in
            { message, category in lg.log(message, category: category) }
        }
        let store = KeychainTokenStore(service: service, account: account, log: log)
        let envProvider = EnvTokenProvider(log: log)
        let cache = TokenCache(tokenStore: store, logger: logger, envProvider: envProvider)
        let oauth = OAuthService(
            clientID: clientID,
            clientSecret: clientSecret,
            tokenStore: store,
            scopes: scopes,
            redirectURI: redirectURI,
            logger: logger,
            session: URLSession.shared,
            onTokenSaved: { cache.invalidate() },
            onTokenDeleted: { cache.invalidate() }
        )
        let transport = GitHubTransport(
            tokenProvider: { await cache.token() },
            logger: logger
        )
        sharedTransportStorage = transport
        self.oauthService = oauth
        self.transport = transport
        self._tokenCache = cache
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
    ///
    /// ## `tokenCache` and `invalidate()` in tests
    /// The test init does **not** wire `onTokenSaved` / `onTokenDeleted` callbacks
    /// — there is no `OAuthService` to fire them. Tests that exercise sign-out or
    /// credential rotation and need `cachedToken` to reflect the new state must
    /// call `tokenCache.invalidate()` manually, or pass a pre-populated
    /// `TokenCache` instance via the `tokenCache` parameter.
    ///
    /// - Note: Does **not** accept a `scopes:` or `redirectURI:` parameter —
    ///   it takes `any OAuthServiceProtocol` directly, which already encapsulates
    ///   both scope and redirect URI configuration. No changes needed here.
    ///
    /// - Parameters:
    ///   - oauthService: A mock or stub conforming to `OAuthServiceProtocol`.
    ///   - transport: A mock or stub conforming to `GitHubTransportProtocol`.
    ///   - tokenCache: An optional pre-configured `TokenCache`. When `nil` a
    ///     `NullTokenStore`-backed cache is constructed automatically — suitable
    ///     for tests that do not exercise the token-resolution path.
    public init(
        oauthService: any OAuthServiceProtocol,
        transport: any GitHubTransportProtocol,
        tokenCache: TokenCache? = nil
    ) {
        self.oauthService = oauthService
        self.transport = transport
        self._tokenCache = tokenCache ?? TokenCache(tokenStore: NullTokenStore())
    }
}
