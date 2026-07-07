// OAuthService.swift
// GitHubClient
import Foundation

// MARK: - OAuthService
//
// Implements the GitHub OAuth Authorization Code flow.
//
// @MainActor ensures all access to `pendingState` and continuation registries
// is serialised on the main thread. This matches how AppKit delivers
// application(_:open:) callbacks and how SwiftUI reads `isSignedIn`.
//
// Flow:
// 1. makeSignInURL() generates a random state nonce, stores it, and returns
//    the GitHub authorization URL. The caller is responsible for opening it
//    (e.g. NSWorkspace.shared.open(url) in SettingsView / AppDelegate).
// 2. The user clicks "Authorize" on GitHub's consent screen.
// 3. GitHub redirects to runbot://oauth/callback?code=...&state=...
// 4. AppDelegate.application(_:open:) catches the URL and calls handleCallback(_:).
// 5. handleCallback verifies the state param matches pendingState (CSRF guard),
//    then exchanges the code for an access token via POST to GitHub.
// 6. Token is saved to tokenStore. fireSignIn(_:) yields the result to all
//    registered makeSignInStream() consumers.

/// Manages OAuth state and behaviour. No AppKit dependency.
@MainActor
public final class OAuthService: OAuthServiceProtocol {
    /// Shared `JSONDecoder` — reused across token-exchange decode calls.
    private let decoder = JSONDecoder()
    /// Shared `JSONEncoder` — reused across token-exchange encode calls.
    private let encoder = JSONEncoder()
    /// The OAuth redirect URI. Must match the value registered in the GitHub OAuth app settings.
    private let redirectURI = GitHubConstants.oauthRedirectURI
    /// OAuth scopes requested during sign-in. Set at init time via the `scopes` parameter.
    private let scopes: [String]
    /// GitHub OAuth authorisation URL.
    private let authorizeURL = "\(GitHubConstants.base)/login/oauth/authorize"
    /// GitHub OAuth token-exchange URL.
    private let accessTokenURL = "\(GitHubConstants.base)/login/oauth/access_token"
    /// CSRF nonce generated in makeSignInURL(), verified in handleCallback(). Cleared after use.
    private var pendingState: String?

    /// The GitHub OAuth app client ID.
    private let clientID: String
    /// The GitHub OAuth app client secret.
    ///
    /// Held in process memory for the app lifetime — intentional for compile-time
    /// baked constants (e.g. `OAuthSecrets.clientSecret`). Dynamic secret managers
    /// are not supported at this call site; tracked as a follow-up for the
    /// standalone `swift-github-client` release (step 14).
    private let clientSecret: String
    /// The backing store used to save/delete/load the OAuth token.
    private let tokenStore: any TokenStore
    /// Optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?
    /// The `URLSession` used for token-exchange network calls. Defaults to `.shared`.
    /// Injected at init time so tests can supply a mock session without swizzling.
    private let session: URLSession
    /// Called after a successful `tokenStore.save()` — e.g. to invalidate a `TokenCache`.
    private let onTokenSaved: (() -> Void)?
    /// Called on every `signOut()` — e.g. to invalidate a `TokenCache`. Invoked regardless of
    /// whether `tokenStore.delete()` succeeded, so the in-memory cache is always cleared.
    private let onTokenDeleted: (() -> Void)?

    /// Creates a new `OAuthService`.
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - tokenStore: The backing store used to save/delete/load the OAuth token.
    ///   - scopes: The OAuth scopes to request during sign-in. Defaults to `GitHubScopes.default`.
    ///     Must not be empty — a `precondition` failure is raised at init time if an empty array
    ///     is passed (fires in both debug and release builds — this is intentional; an empty
    ///     scopes array is a programming error, not a runtime condition).
    ///     Use `GitHubScopes` constants for type safety and discoverability.
    ///   - logger: Optional logger for diagnostic messages.
    ///   - session: The `URLSession` used for token-exchange requests. Defaults to `.shared`.
    ///     Inject a custom session in tests to avoid real network calls.
    ///   - onTokenSaved: Optional callback invoked after a successful token save.
    ///     Use this to invalidate an external cache (e.g. `TokenCache.invalidate()`).
    ///     Defaults to `nil` — existing call sites are unaffected.
    ///   - onTokenDeleted: Optional callback invoked on every `signOut()`, regardless of
    ///     whether the Keychain delete succeeded. Use this to invalidate a `TokenCache`.
    ///     Defaults to `nil` — existing call sites are unaffected.
    public init(
        clientID: String,
        clientSecret: String,
        tokenStore: any TokenStore,
        scopes: [String] = GitHubScopes.default,
        logger: (any GitHubLogger)? = nil,
        session: URLSession = .shared,
        onTokenSaved: (() -> Void)? = nil,
        onTokenDeleted: (() -> Void)? = nil
    ) {
        precondition(!scopes.isEmpty, "OAuthService: scopes must not be empty — pass at least one GitHubScopes constant")
        self.scopes = scopes
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenStore = tokenStore
        self.logger = logger
        self.session = session
        self.onTokenSaved = onTokenSaved
        self.onTokenDeleted = onTokenDeleted
    }

    // MARK: - OAuthServiceProtocol — Auth state

    /// `true` when a valid OAuth token is present in the token store (e.g. Keychain).
    ///
    /// Each call performs one synchronous `SecItemCopyMatching` read. This is
    /// intentional: the Keychain is the source of truth and caching here would
    /// mask external token revocation. The read is fast (≥10 µs on macOS) and
    /// safe on the main thread at current call sites (settings appear on user
    /// interaction, not in animation/layout loops). If this is ever used in a
    /// tight render loop, cache the result at the call site instead.
    public var isAuthenticated: Bool { tokenStore.load() != nil }

    /// `true` when any usable GitHub token is available — OAuth token,
    /// `GH_TOKEN`, or `GITHUB_TOKEN` environment variable.
    ///
    /// Delegates to `isAuthenticated` for the Keychain check to avoid a
    /// duplicate `tokenStore.load()` call when both properties are evaluated
    /// back-to-back (e.g. `SettingsView.onAppearAction`).
    public var hasAnyToken: Bool {
        if isAuthenticated { return true }
        let env = ProcessInfo.processInfo.environment
        return env["GH_TOKEN"] != nil || env["GITHUB_TOKEN"] != nil
    }

    // MARK: - Sign-out multicast

    /// Registered sign-out continuations keyed by UUID — one per active consumer.
    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Returns a new `AsyncStream` that fires once per `signOut()` call.
    public func makeSignOutStream() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Void>.makeStream()
        signOutContinuations[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.signOutContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    // MARK: - Sign-in multicast

    /// Registered sign-in continuations keyed by UUID — one per active consumer.
    private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Returns a new `AsyncStream` that fires once per sign-in attempt (`true` = success).
    public func makeSignInStream() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        signInContinuations[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.signInContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    /// Yields `success` to every registered sign-in continuation.
    private func fireSignIn(_ success: Bool) {
        logger?.log("OAuthService › fireSignIn — success=\(success), consumers=\(signInContinuations.count)", category: "transport")
        signInContinuations.values.forEach { $0.yield(success) }
    }

    // MARK: - Sign In

    /// Builds a GitHub OAuth authorize URL with a CSRF state nonce.
    public func makeSignInURL() -> URL? {
        logger?.log("OAuthService › makeSignInURL — building OAuth URL", category: "transport")
        let state = UUID().uuidString
        pendingState = state
        guard var comps = URLComponents(string: authorizeURL) else {
            logger?.log("OAuthService › makeSignInURL: malformed authorizeURL — aborting", category: "transport")
            pendingState = nil
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = comps.url else {
            logger?.log("OAuthService › makeSignInURL: failed to build URL — aborting", category: "transport")
            pendingState = nil
            return nil
        }
        logger?.log("OAuthService › makeSignInURL — URL built, returning to caller", category: "transport")
        return url
    }

    // MARK: - Sign Out

    /// Clears the pending state, deletes the stored token, and emits a sign-out event.
    ///
    /// Token deletion is best-effort: if `tokenStore.delete()` fails (e.g.
    /// `errSecInteractionNotAllowed` when the screen is locked), the cache is
    /// still invalidated and the sign-out stream is still emitted. The app UI
    /// reflects signed-out state immediately. A stale Keychain entry is benign
    /// on next launch because `isAuthenticated` checks for a *valid* token; an
    /// orphaned entry will simply be overwritten or ignored on next sign-in.
    /// Permanent UI lock-out is a worse failure mode than a recoverable ghost
    /// entry, so we always proceed.
    public func signOut() {
        logger?.log("OAuthService › signOut — called, pendingState=\(pendingState != nil ? "set" : "nil")", category: "transport")
        pendingState = nil
        let deleted = tokenStore.delete()
        logger?.log("OAuthService › signOut — tokenStore.delete result=\(deleted)", category: "transport")
        if !deleted {
            logger?.log("OAuthService › signOut — tokenStore.delete failed (best-effort); proceeding with cache clear and sign-out event", category: "transport")
        }
        onTokenDeleted?()
        logger?.log("OAuthService › signOut — emitting didSignOut to \(signOutContinuations.count) consumer(s)", category: "transport")
        signOutContinuations.values.forEach { $0.yield(()) }
    }

    // MARK: - Callback Handler

    /// Processes the OAuth redirect URL from GitHub.
    ///
    /// Extracts the `code` and `state` query parameters, validates the CSRF
    /// state nonce, then kicks off the token-exchange flow.
    public func handleCallback(_ url: URL) {
        // Log scheme+host only — the full URL contains the one-time `code` query
        // parameter which is sensitive for a short window. Never log url.absoluteString
        // or url.query here; doing so would leak the live credential into unified logs.
        let safeURL = "\(url.scheme ?? "")://\(url.host ?? "")"
        logger?.log("OAuthService › handleCallback — url=\(safeURL)", category: "transport")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
            logger?.log("OAuthService › handleCallback — missing code param, calling fireSignIn(false)", category: "transport")
            fireSignIn(false)
            return
        }
        guard let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value else {
            logger?.log("OAuthService › handleCallback: no state param in redirect URL", category: "transport")
            pendingState = nil
            fireSignIn(false)
            return
        }
        guard returnedState == pendingState else {
            logger?.log("OAuthService › handleCallback: state mismatch — possible CSRF attempt, rejecting", category: "transport")
            pendingState = nil
            fireSignIn(false)
            return
        }
        logger?.log("OAuthService › handleCallback — state OK, exchanging code", category: "transport")
        pendingState = nil
        Task { await exchangeCode(code) }
    }

    // MARK: - Token Exchange

    /// Exchanges the one-time authorization code for an access token.
    ///
    /// 1. Builds and sends the token-exchange request.
    /// 2. Decodes the response.
    /// 3. Validates the response and extracts the token.
    /// 4. Saves the token via `tokenStore`.
    /// 5. Calls `onTokenSaved` to allow callers to invalidate external caches.
    /// 6. Notifies sign-in consumers of the result.
    private func exchangeCode(_ code: String) async {
        logger?.log("OAuthService › exchangeCode — POST to GitHub", category: "transport")
        let req: URLRequest
        do {
            req = try makeTokenRequest(code: code)
        } catch {
            logger?.log("OAuthService › exchangeCode: failed to encode request body — aborting", category: "transport")
            fireSignIn(false)
            return
        }
        let data: Data
        do {
            data = try await fetchTokenData(request: req)
        } catch {
            logger?.log("OAuthService › exchangeCode: network error — \(error.localizedDescription), calling fireSignIn(false)", category: "transport")
            fireSignIn(false)
            return
        }
        let response: OAuthTokenResponse
        do {
            response = try decoder.decode(OAuthTokenResponse.self, from: data)
        } catch {
            logger?.log("OAuthService › exchangeCode: decode error — \(error.localizedDescription), calling fireSignIn(false)", category: "transport")
            fireSignIn(false)
            return
        }
        guard let token = handleTokenResponse(response) else {
            fireSignIn(false)
            return
        }
        logger?.log("OAuthService › exchangeCode — got access_token (len=\(token.count)), saving to store", category: "transport")
        let saved = tokenStore.save(token)
        logger?.log("OAuthService › exchangeCode — tokenStore.save result=\(saved), calling fireSignIn(\(saved))", category: "transport")
        if saved {
            onTokenSaved?()
        } else {
            logger?.log("OAuthService › exchangeCode: tokenStore.save failed", category: "transport")
        }
        fireSignIn(saved)
    }

    /// Builds the token-exchange `URLRequest`.
    private func makeTokenRequest(code: String) throws -> URLRequest {
        guard let url = URL(string: accessTokenURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OAuthTokenRequest(clientID: clientID, clientSecret: clientSecret, code: code)
        req.httpBody = try encoder.encode(body)
        return req
    }

    /// Performs the network call for the token exchange.
    @concurrent
    private func fetchTokenData(request: URLRequest) async throws -> Data {
        let (data, _) = try await session.data(for: request)
        return data
    }

    /// Validates the GitHub-level token response and extracts the access token.
    private func handleTokenResponse(_ response: OAuthTokenResponse) -> String? {
        if let errorCode = response.error {
            let desc = response.errorDescription ?? ""
            logger?.log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)", category: "transport")
            return nil
        }
        guard let token = response.accessToken, !token.isEmpty else {
            logger?.log("OAuthService › exchangeCode: no access_token in response — keys=\(response.debugKeys)", category: "transport")
            return nil
        }
        return token
    }
}

// MARK: - OAuthTokenResponse

/// Response body from the GitHub OAuth token exchange.
/// GitHub returns HTTP 200 even on failure, so both `accessToken` and `error` are optional.
private struct OAuthTokenResponse: Decodable {
    // swiftlint:disable:next missing_docs
    let accessToken: String?
    // swiftlint:disable:next missing_docs
    let error: String?
    // swiftlint:disable:next missing_docs
    let errorDescription: String?

            // swiftlint:disable missing_docs
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token" // skipcq: SCT-A000
        case error
        case errorDescription = "error_description"
    }
    // swiftlint:enable missing_docs

    // swiftlint:disable:next missing_docs
    var debugKeys: [String] {
        var keys: [String] = []
        if accessToken != nil { keys.append("access_token") } // skipcq: SCT-A000
        if error != nil { keys.append("error") }
        if errorDescription != nil { keys.append("error_description") }
        return keys
    }
}

// MARK: - OAuthTokenRequest

// periphery:ignore
/// OAuth token-exchange request body for the GitHub API.
private struct OAuthTokenRequest: Encodable {
    // swiftlint:disable:next missing_docs
    let clientID: String
    // swiftlint:disable:next missing_docs
    let clientSecret: String
    // swiftlint:disable:next missing_docs
    let code: String

            // swiftlint:disable missing_docs
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id" // skipcq: SCT-A000
        case clientSecret = "client_secret" // skipcq: SCT-A000
        case code
    }
    // swiftlint:enable missing_docs
}
