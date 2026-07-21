// GitHubScopes.swift
// OAuthTokenKit

// MARK: - GitHubScopes

/// Typed constants for GitHub OAuth scope strings.
///
/// Use these when constructing an `OAuthService` or `GitHubClient` with custom
/// scopes to avoid typos and improve call-site discoverability:
///
/// ```swift
/// let client = GitHubClient(
///     clientID: "…",
///     clientSecret: "…",
///     service: "…",
///     account: "…",
///     scopes: GitHubScopes.default + [GitHubScopes.readUser]
/// )
/// ```
public enum GitHubScopes {
    /// The default set of OAuth scopes requested by RunBot.
    /// Covers read access to workflows, actions, and runner registration.
    public static let `default`: [String] = ["repo", "workflow", "admin:org"]
    /// Read-only access to user profile information.
    public static let readUser = "read:user"
    /// Full read/write access to repositories.
    public static let repo = "repo"
    /// Read-only access to repositories.
    public static let readRepo = "public_repo"
    /// Workflow and Actions access.
    public static let workflow = "workflow"
    /// Organisation administration access.
    public static let adminOrg = "admin:org"
    /// Read-only access to organisation membership.
    public static let readOrg = "read:org"
}
