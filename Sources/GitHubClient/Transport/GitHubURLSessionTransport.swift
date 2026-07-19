// GitHubURLSessionTransport.swift
// GitHubClient

import Foundation

// MARK: - GitHubTransport

/// The concrete `URLSession`-backed implementation of `GitHubTransportProtocol`.
///
/// `GitHubTransport` owns the decoder, encoder, session, rate-limiter, token-provider,
/// and call counter. Callers that need a real network transport use `currentTransport`;
/// tests inject a mock conformer or construct a custom instance via
/// `init(decoder:encoder:session:rateLimiter:tokenProvider:logger:callCounter:)`.
///
/// **Thread safety:** `GitHubTransport` is a value type whose `let` properties are either
/// value types or `Sendable` reference types. `JSONDecoder`/`JSONEncoder` are reference types
/// but are `@unchecked Sendable` and stateless after `init`, safe for concurrent reads.
public struct GitHubTransport: GitHubTransportProtocol {

  // MARK: - Stored properties

  /// JSON decoder — stateless after `init`, safe for concurrent reads.
  ///
  /// ⚠️ **Do not mutate the returned instance.** `JSONDecoder` is a reference type;
  /// mutating its properties after this transport has been initialised will corrupt
  /// concurrent decodes. Configure before passing to init and never touch it again.
  public let decoder: JSONDecoder

  /// JSON encoder — stateless after `init`, safe for concurrent reads.
  internal let encoder: JSONEncoder

  /// URL session used for all network requests. Defaults to `URLSession.shared`.
  private let session: URLSession

  /// Rate-limit actor used to arm/clear the global back-off window.
  private let rateLimiter: any RateLimitActorProtocol

  /// Async closure that returns the current GitHub PAT, or `nil` when signed out.
  ///
  /// Async so that `TokenCache.token()` can resolve the token lazily — including
  /// spawning a login shell on a cold Finder/Dock launch — without blocking any
  /// actor's serial executor. The closure is awaited inside `execute()`, which is
  /// already `async`, so the suspension point is transparent to callers.
  private let tokenProvider: @Sendable () async -> String?

  /// Optional logger for diagnostic messages.
  public let logger: (any GitHubLogger)?

  /// Call counter incremented once per successful HTTP round-trip (2xx response).
  ///
  /// Injected at init so tests can pass a mock conformer and assert call counts
  /// without touching the shared singleton. Defaults to `APICallCounter.shared`.
  private let callCounter: any APICallCounterProtocol

  // MARK: - Init

  /// Creates a `GitHubTransport` with the given dependencies.
  ///
  /// - Note: In production, `GitHubClient.init` always supplies an explicit
  ///   `tokenProvider` (`{ await cache.token() }`). The `nil` default exists only
  ///   so `GitHubTransport()` compiles in test or standalone contexts.
  public init(
    decoder: JSONDecoder = JSONDecoder(),
    encoder: JSONEncoder = JSONEncoder(),
    session: URLSession = .shared,
    rateLimiter: some RateLimitActorProtocol = rateLimitActor,
    tokenProvider: (@Sendable () async -> String?)? = nil,
    logger: (any GitHubLogger)? = nil,
    callCounter: any APICallCounterProtocol = APICallCounter.shared
  ) {
    self.decoder = decoder
    self.encoder = encoder
    self.session = session
    self.rateLimiter = rateLimiter
    self.tokenProvider = tokenProvider ?? { nil }
    self.logger = logger
    self.callCounter = callCounter
  }

  // MARK: - Core execution

  /// Core execution pipeline shared by all `GitHubTransportProtocol` methods.
  ///
  /// Resolves the token (async — may spawn a login shell on cold Finder launch),
  /// builds a signed `URLRequest`, performs the `URLSession` round-trip, and maps
  /// the HTTP response to an `ExecuteResult`.
  @concurrent
  func execute(
    _ endpoint: String,
    timeout: TimeInterval,
    logTag: String,
    useRawAccept: Bool = false,
    configure: @Sendable (URLRequest) -> URLRequest = { $0 }
  ) async -> ExecuteResult {
    guard let token = await tokenProvider() else {
      logger?.log("\(logTag) › no token available", category: "transport")
      return .noToken
    }
    guard let req = buildRequest(
      endpoint: endpoint,
      token: token,
      timeout: timeout,
      useRawAccept: useRawAccept,
      configure: configure,
      logTag: logTag
    ) else {
      return .networkError(URLError(.badURL))
    }
    do {
      let (data, response) = try await session.data(for: req)
      return await interpretHTTPResponse(
        response, data: data, urlString: resolveURL(endpoint)
      )
    } catch {
      logger?.log(
        "\(logTag) › \(resolveURL(endpoint)) network error: \(error.localizedDescription)",
        category: "transport")
      return .networkError(error)
    }
  }

  // MARK: - Request building

  /// Builds a signed `URLRequest` for `endpoint`, or `nil` if the URL is invalid.
  private func buildRequest(
    endpoint: String,
    token: String,
    timeout: TimeInterval,
    useRawAccept: Bool,
    configure: @Sendable (URLRequest) -> URLRequest,
    logTag: String
  ) -> URLRequest? {
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
      logger?.log("\(logTag) › invalid URL: \(urlString)", category: "transport")
      return nil
    }
    let base =
      useRawAccept
      ? makeRawRequest(url: url, token: token, timeout: timeout)
      : makeRequest(url: url, token: token, timeout: timeout)
    return configure(base)
  }

  // MARK: - HTTP response interpretation

  /// Maps an HTTP response + body into an `ExecuteResult`, arming rate-limit back-off as needed.
  ///
  /// Records one call-counter hit on every 2xx response.
  ///
  /// Sequential awaits — not a missed `async let` optimisation:
  /// `rateLimiter.clearIfNotLimited()` and `callCounter.record()` are intentionally
  /// sequential: rate-limit state must be cleared before success is recorded.
  private func interpretHTTPResponse(
    _ response: URLResponse,
    data: Data,
    urlString: String
  ) async -> ExecuteResult {
    guard let http = response as? HTTPURLResponse else {
      return .networkError(URLError(.badServerResponse))
    }
    if http.statusCode == 403 || http.statusCode == 429 {
      let wasRateLimited = await handleRateLimitResponse(
        statusCode: http.statusCode,
        data: data,
        response: http,
        endpoint: urlString,
        rateLimiter: rateLimiter,
        logger: logger
      )
      return wasRateLimited ? .rateLimited : .permissionDenied
    }
    guard (200..<300).contains(http.statusCode) else {
      logErrorBody(data, endpoint: urlString, status: http.statusCode, logger: logger)
      return .httpError(http.statusCode)
    }
    await rateLimiter.clearIfNotLimited()
    if let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) {
        await rateLimiter.updateRemaining(remaining)
    }
    await callCounter.record()
    let linkHeader = http.value(forHTTPHeaderField: "Link")
    return .success(data, statusCode: http.statusCode, linkHeader: linkHeader)
  }
}

// MARK: - Shared execution core

/// The result of a single URLSession round-trip through `execute`.
internal enum ExecuteResult {
  /// A 2xx response with body, status code, and optional `Link` header.
  case success(Data, statusCode: Int, linkHeader: String?)
  /// No GitHub token was available — user is signed out or no env var is set.
  case noToken
  /// A non-2xx HTTP status code was returned.
  case httpError(Int)
  /// The request was rate limited (403/429 with rate-limit signals).
  case rateLimited
  /// The request was denied (403/429 without rate-limit signals).
  case permissionDenied
  /// A transport-level network error occurred (DNS failure, TLS error, timeout, etc.).
  case networkError(Error)
}
