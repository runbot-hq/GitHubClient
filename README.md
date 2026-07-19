# GitHubClient

A lightweight, modern Swift GitHub API client for macOS apps. Direct REST calls over `URLSession`, zero external dependencies, Swift 6.2 strict concurrency throughout.

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SPM](https://img.shields.io/badge/SPM-compatible-F05138?logo=swift&logoColor=white)

**CI Checks & Review**

![Unit Tests](https://github.com/runbot-hq/GitHubClient/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/runbot-hq/GitHubClient/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/runbot-hq/GitHubClient/actions/workflows/periphery.yml/badge.svg)
[![Greptile](https://img.shields.io/badge/🦎%20AI%20Review-Greptile-6C47FF?logoColor=white)](https://greptile.com)

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Codebase Structure](#codebase-Structure)
- [Usage](#usage)
- [Usage Examples](#usage-examples)
- [Authentication](#authentication)
- [License](#license)

## Features

- 🔐 **Dual authentication** — OAuth Authorization Code flow for interactive users; `GH_TOKEN` / `GITHUB_TOKEN` env var for CI and automation. Same call site, no branching
- 🪜 **Layered token resolution** — memory cache → Keychain → env var, resolved at call time
- 🌐 **Direct REST over `URLSession`** — no code generation, no auto-generated OpenAPI types, no third-party networking layer
- 🛡️ **Rate-limit aware** — automatic backoff and retry on 429 / 403 rate-limit responses
- 📄 **Link-header pagination** — cursor-based pagination handled transparently
- 🔑 **`KeychainTokenStore` built in** — ready-made Keychain integration via `Security.framework`; swap in a mock for tests via the `TokenStore` protocol
- ⚡ **Swift 6.2 strict concurrency** — no `@unchecked Sendable`, compiler-enforced boundaries throughout
- 🧪 **Testable by design** — every concrete type hidden behind a protocol; inject a fake transport or token store in tests with no Keychain involvement
- 🤖 **Self-hosted runner queries** — fetch all runners for an org or repo scope via `fetchRunners(scope:)` / `fetchRunners(scopeString:)`; returns `[GitHubRunner]` with name, status, busy flag, and labels. Pagination handled automatically
- ⚙️ **Workflow run & job inspection** — `fetchActiveRuns(scope:)` returns a typed `GitHubRunsFetchResult` distinguishing `.success`, `.rateLimited(partial)`, and `.noToken`; `fetchJobs(runID:scope:)` returns full `[GitHubJob]` trees with steps, runner name, and timestamps; `fetchStepLog(jobID:stepNumber:scope:)` fetches and parses raw CI logs per step, stripping ANSI codes automatically
- 👤 **User context helpers** — `fetchUserOrgs()` and `fetchUserRepos()` return the authenticated user's org login names and `owner/repo` full names; useful for building scope-picker UIs

## Requirements

- Swift 6.2+
- macOS 15+

## Codebase Structure
The package is organized into three layers :

- API/ — workflow/runner domain functions and models
- Auth/ — OAuth, Keychain, token caching
- Transport/ — URLSession-backed HTTP transport

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

## Usage Examples

### Fetch self-hosted runners for an org

```swift
import GitHubClient

// CI / automation — token picked up from GH_TOKEN / GITHUB_TOKEN automatically
let runners = await fetchRunners(scopeString: "orgs/acme")
for runner in runners ?? [] {
    print("\(runner.name) — \(runner.status) (busy: \(runner.busy))")
}
```

### Fetch active workflow runs for a repo

```swift
let scope = Scope.parse("repos/acme/my-repo")!

switch await fetchActiveRuns(scope: scope) {
case .success(let runs):
    for run in runs {
        print("[\(run.status)] \(run.name ?? "unnamed") — \(run.htmlUrl)")
    }
case .rateLimited(let partial):
    print("Rate-limited; \(partial.count) partial results returned")
case .noToken:
    print("No GitHub token configured — trigger OAuth sign-in")
case .authFailure:
    print("Token rejected by GitHub")
}
```

### Fetch jobs for a specific run

```swift
let jobs = await fetchJobs(runID: 12345678, scope: scope)
for job in jobs {
    let conclusion = job.conclusion ?? "in progress"
    print("  \(job.name): \(conclusion) (\(job.steps.count) steps)")
}
```

### Fetch a step log

```swift
if let log = await fetchStepLog(jobID: 987654, stepNumber: 2, scope: "repos/acme/my-repo") {
    print(log)
}
```

### Fetch user orgs and repos

```swift
let orgs = await fetchUserOrgs()
let repos = await fetchUserRepos()
print("Orgs: \(orgs)")
print("Repos: \(repos)")
```

### Testing with mock transport

```swift
// Inject a MockTransport — no Keychain, no network
let client = GitHubClient(
    oauthService: MockOAuthService(),
    transport: MockTransport()
)
let jobs = await fetchJobs(runID: 1, scope: .org("acme"), transport: client.transport)
XCTAssertEqual(jobs.count, 2)
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

### OAuth scopes

Scopes control what permissions are requested from the user during sign-in. Pass a `scopes:` array to `GitHubClient.init` using the typed constants in `GitHubScopes`.

**Default scopes** (used when `scopes:` is omitted):

| Constant | GitHub scope | Access granted |
|---|---|---|
| `GitHubScopes.repo` | `repo` | Full read/write access to code, commits, pull requests |
| `GitHubScopes.readOrg` | `read:org` | Read-only access to org membership and teams |
| `GitHubScopes.adminOrg` | `admin:org` | Full admin access to org membership and teams |
| `GitHubScopes.manageRunnersOrg` | `manage_runners:org` | Manage self-hosted runners in an org |
| `GitHubScopes.workflow` | `workflow` | Manage and trigger GitHub Actions workflows |

**Request only what you need** — for a read-only tool, narrow the scopes at init time:

```swift
let github = GitHubClient(
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    service: "com.yourapp.github",
    account: "github-oauth-token",
    scopes: [GitHubScopes.readOrg, GitHubScopes.repo]
)
```

**Extend the defaults** when you need an extra scope (e.g. reading user profile data):

```swift
let github = GitHubClient(
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    service: "com.yourapp.github",
    account: "github-oauth-token",
    scopes: GitHubScopes.default + [GitHubScopes.readUser]
)
```

See the [GitHub OAuth scopes documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps) for the full list of available scopes.

### Environment token (CI / automation)

Export `GH_TOKEN` or `GITHUB_TOKEN` — the library picks it up automatically with no additional configuration.

## License

MIT
