// GitHubScopes.swift
// GitHubClient

// MARK: - GitHubScopes

/// Typed constants for GitHub OAuth scope strings.
///
/// Use these when constructing a `GitHubClient` with custom scopes to avoid
/// typos and improve call-site discoverability:
///
/// ```swift
/// let client = GitHubClient(
///     clientID: "...",
///     clientSecret: "...",
///     service: "com.example.app",
///     account: "github-oauth-token",
///     scopes: [GitHubScopes.repo, GitHubScopes.readOrg]
/// )
/// ```
///
/// You can also extend the default set:
///
/// ```swift
/// GitHubClient(scopes: OAuthService.defaultScopes + [GitHubScopes.readUser])
/// ```
///
/// - SeeAlso: [GitHub OAuth scopes documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
public enum GitHubScopes {
    /// Grants full read/write access to code, commits, and pull requests.
    public static let repo = "repo"
    /// Grants read-only access to organisation membership and teams.
    public static let readOrg = "read:org"
    /// Grants full admin access to organisation membership and teams.
    public static let adminOrg = "admin:org"
    /// Grants access to manage self-hosted runners in an organisation.
    public static let manageRunnersOrg = "manage_runners:org"
    /// Grants the ability to manage and run GitHub Actions workflows.
    public static let workflow = "workflow"
    /// Grants read-only access to a user's profile data.
    public static let readUser = "read:user"
}
