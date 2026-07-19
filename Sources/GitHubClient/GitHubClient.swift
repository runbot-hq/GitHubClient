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

    /// The token cache — held as a strong reference so `warmUp()` can call into it.
    /// `nil` when created via the test init (mock transport owns its own token logic).
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

    // MARK: - Warm-up

    /// Eagerly resolves the GitHub token before the first API call is made.
    ///
    /// Call this once in `AppState.start()` (or equivalent), **before** starting
    /// the poll loop. It is a no-op when:
    /// - A Keychain OAuth token is already present.
    /// - The process environment already contains `GH_TOKEN` / `GITHUB_TOKEN`
    ///   (terminal launch, CI).
    ///
    /// For GUI apps launched from Finder or the Dock, this bridges the macOS
    /// launchd environment gap by spawning a login shell that sources `~/.zprofile`
    /// and `~/.zshrc`, reading the token the same way a terminal would.
    ///
    /// The underlying `Process.waitUntilExit()` call is dispatched onto a
    /// background thread via `withCheckedContinuation` so the main actor is
    /// never blocked.
    public func warmUp() async {
        guard let cache = tokenCache else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cache.warmUpFromLoginShell()
                continuation.resume()
            }
        }
    }
}
