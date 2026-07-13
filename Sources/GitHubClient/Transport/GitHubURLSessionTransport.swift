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
/// Concurrent reads are safe; there is no mutable state.
public struct GitHubTransport: GitHubTransportProtocol {

  // MARK: - Stored properties

  /// JSON decoder — stateless after `init`, safe for concurrent reads.
  ///
  /// ⚠️ **Do not mutate the returned instance.** `JSONDecoder` is a reference type;
  /// mutating its properties (e.g. `keyDecodingStrategy`, `dateDecodingStrategy`)
  /// after this transport has been initialised will corrupt concurrent decodes
  /// across all callers sharing this transport instance. Configure the decoder
  /// before passing it to `GitHubTransport.init(decoder:...)` and never touch it
  /// again. This constraint cannot be enforced by the type system because
  /// `GitHubTransportProtocol.decoder` must satisfy a `public` protocol requirement.
  public let decoder: JSONDecoder

  /// JSON encoder — stateless after `init`, safe for concurrent reads.
  internal let encoder: JSONEncoder

  /// URL session used for all network requests. Defaults to `URLSession.shared`.
  private let session: URLSession

  /// Rate-limit actor used to arm/clear the global back-off window.
  private let rateLimiter: any RateLimitActorProtocol

  /// Synchronous closure that returns the current GitHub PAT, or `nil` when
  /// the user is signed out.
  private let tokenProvider: @Sendable () -> String?

  /// Optional logger for diagnostic messages.
  ///
  /// `public` (not `private`) so the protocol requirement in `GitHubTransportProtocol`
  /// is satisfied and host apps can forward it to `configureGHLogger(_:)` without
  /// downcasting to the concrete `GitHubTransport` type.
  public let logger: (any GitHubLogger)?

  /// Call counter incremented once per successful HTTP round-trip (2xx response).
  ///
  /// Injected at init so tests can pass a mock conformer and assert call counts
  /// without touching the shared singleton. Defaults to `APICallCounter.shared`.
  ///
  /// Recorded inside `interpretHTTPResponse` — the single path every successful
  /// `execute(_:)` call flows through, regardless of HTTP verb or pagination.
  private let callCounter: any APICallCounterProtocol

  // MARK: - Init

  /// Creates a `GitHubTransport` with the given dependencies. All parameters have defaults
  /// that reproduce the production behaviour, so `GitHubTransport()` is ready to use.
  ///
  /// - Note: In production, `GitHubClient.init` always supplies an explicit `tokenProvider`
  ///   (`{ cache.token() }`) so the `nil` default is never used in the app target.
  ///   The default (`{ nil }`) exists only so `GitHubTransport()` compiles without
  ///   a token provider in test or standalone contexts where no `TokenCache` is wired.
  public init(
    decoder: JSONDecoder = JSONDecoder(),
    encoder: JSONEncoder = JSONEncoder(),
    session: URLSession = .shared,
    rateLimiter: some RateLimitActorProtocol = rateLimitActor,
    tokenProvider: (@Sendable () -> String?)? = nil,
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
  /// Resolves the token, builds a signed `URLRequest`, performs the `URLSession` round-trip,
  /// and maps the HTTP response to an `ExecuteResult`. All public transport methods delegate
  /// to this function. `configure` is applied after the base request is built, allowing
  /// callers to override the HTTP method, body, and headers for POST/PUT/DELETE.
  @concurrent
  func execute(
    _ endpoint: String,
    timeout: TimeInterval,
    logTag: String,
    useRawAccept: Bool = false,
    configure: @Sendable (URLRequest) -> URLRequest = { $0 }
  ) async -> ExecuteResult {
    guard let token = tokenProvider() else {
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
  /// Records one call-counter hit on every 2xx response — the single point all successful
  /// HTTP round-trips flow through regardless of verb or pagination depth.
  ///
  /// Also forwards `X-RateLimit-Remaining` to `rateLimiter` on every 2xx response so that
  /// `RateLimitActor.snapshot()` always carries the latest remaining-count. The header is
  /// absent on raw/S3 responses; the guard-let falls through and `remaining` is left unchanged
  /// (still `Int.max` until the first API response that includes the header).
  ///
  /// Counter exclusions:
  /// - 403/429 responses: handled before the 2xx guard and return `.rateLimited` or
  ///   `.permissionDenied` without calling `callCounter.record()`. Both are excluded
  ///   deliberately — a request that was denied or rate-limited did not consume a
  ///   successful API quota slot. `.permissionDenied` specifically covers plain 403s
  ///   with no rate-limit headers (wrong token scope, revoked PAT, repo access denial);
  ///   the request reached GitHub but was rejected, so counting it would overstate usage.
  ///
  /// Sequential awaits — not a missed `async let` optimisation:
  /// - `rateLimiter.clearIfNotLimited()`, `rateLimiter.updateRemaining(_:)`, and
  ///   `callCounter.record()` are intentionally sequential. Rate-limit state must be
  ///   cleared and the remaining count updated before the success is recorded so all
  ///   three pieces of state stay consistent from the caller’s perspective. All three
  ///   are nanosecond in-memory actor operations; `async let` child-task allocation
  ///   overhead would exceed any latency gain here.
  ///
  /// 3xx and the (200..<300) guard:
  /// - The status range includes 3xx in principle, but URLSession follows redirects
  ///   automatically and never surfaces a 3xx response to this completion handler.
  ///   A 304 Not Modified is only returned when a conditional GET includes an
  ///   `If-None-Match` / `If-Modified-Since` header — none of which this client sends.
  ///   In practice this guard can only be reached by a 2xx; the wider range is harmless.
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
    // Sequential awaits are intentional — see doc comment above.
    await rateLimiter.clearIfNotLimited()
    // Forward X-RateLimit-Remaining so RateLimitActor.snapshot() carries a live count.
    // The header is absent on raw/S3 redirect responses — guard-let falls through safely.
    if let raw = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
       let value = Int(raw) {
        await rateLimiter.updateRemaining(value)
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
  /// No GitHub token was available.
  case noToken
  /// A non-2xx HTTP status code was returned.
  case httpError(Int)
  /// The request was rate limited (403/429 with rate-limit signals).
  case rateLimited
  /// The request was denied (403/429 without rate-limit signals).
  case permissionDenied
  /// A transport-level network error occurred.
  case networkError(Error)
}
