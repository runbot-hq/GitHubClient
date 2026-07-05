# GitHubClient

A lightweight, modern Swift GitHub API client for macOS apps. Direct REST calls over `URLSession`, zero external dependencies, Swift 6.2 strict concurrency throughout.

## Features

- **Dual authentication** — OAuth Authorization Code flow for interactive users; `GH_TOKEN` / `GITHUB_TOKEN` env var for CI and automation. Same call site, no branching
- **Layered token resolution** — memory cache → Keychain → env var, resolved at call time
- **Direct REST over `URLSession`** — no code generation, no auto-generated OpenAPI types, no third-party networking layer
- **Rate-limit aware** — automatic backoff and retry on 429 / 403 rate-limit responses
- **Link-header pagination** — cursor-based pagination handled transparently
- **`KeychainTokenStore` built in** — ready-made Keychain integration via `Security.framework`; swap in a mock for tests via the `TokenStore` protocol
- **Swift 6.2 strict concurrency** — no `@unchecked Sendable`, compiler-enforced boundaries throughout
- **Testable by design** — every concrete type hidden behind a protocol; inject a fake transport or token store in tests with no Keychain involvement

## Requirements

- Swift 6.2+
- macOS 13+

## Installation

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/runbot-hq/GitHubClient", branch: "main")
```

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "GitHubClient", package: "GitHubClient")
    ]
)
```

## Usage

The recommended entry point is the `GitHubClient` facade. It constructs and wires
`KeychainTokenStore`, `TokenCache`, `OAuthService`, and `GitHubTransport` in one call.

```swift
// AppDelegate or your app's composition root (@MainActor)
let github = GitHubClient(
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    service: "com.yourapp.github",
    account: "github-oauth-token",
    logger: MyLogger.shared
)

let oauth: any OAuthServiceProtocol = github.oauthService
let transport: any GitHubTransportProtocol = github.transport
```

For tests, inject protocol mocks directly:

```swift
let github = GitHubClient(
    oauthService: MockOAuthService(),
    transport: MockTransport()
)
```

## Authentication

### Token resolution order

At every API call, the token is resolved in this order — first match wins:

1. In-memory cache
2. `TokenStore` (Keychain by default)
3. `GH_TOKEN` environment variable
4. `GITHUB_TOKEN` environment variable

### OAuth (interactive users)

```swift
if let url = github.oauthService.makeSignInURL() {
    NSWorkspace.shared.open(url)
}
// Forward the OAuth redirect callback:
github.oauthService.handleCallback(url)
```

### Environment token (CI / automation)

Export `GH_TOKEN` or `GITHUB_TOKEN` — the library picks it up automatically with no additional configuration.

## License

MIT
