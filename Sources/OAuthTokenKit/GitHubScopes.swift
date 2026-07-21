// GitHubScopes.swift
// OAuthTokenKit
import Foundation

// MARK: - GitHubScopes

/// Namespace for GitHub OAuth scope constants.
///
/// Use these constants when constructing `OAuthService` or `GitHubClient` to
/// get compile-time safety and discoverability for scope strings.
///
/// ## Background
/// GitHub OAuth scopes control which resources a token can access. Passing
/// an unrecognised scope string silently results in a token with reduced
/// permissions — GitHub ignores unknown scopes rather than rejecting them.
/// Using typed constants here prevents silent typo-induced permission gaps.
///
/// See https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps
/// for the full scope list.
public enum GitHubScopes {
    // MARK: - Default scope set

    /// The default scope set used by `OAuthService` and `GitHubClient`.
    ///
    /// Contains the minimum scopes required for `GitHubClient`'s current feature set:
    /// - `repo` — full repository access (read + write), required for Actions API calls
    /// - `read:user` — read the authenticated user's profile (username, avatar, etc.)
    ///
    /// Consumers that need a narrower scope set should pass their own array to the
    /// `scopes:` parameter on `OAuthService.init` or `GitHubClient.init` rather than
    /// mutating this constant.
    public static let `default`: [String] = [repo, readUser]

    // MARK: - Individual scopes

    /// Full read + write access to public and private repositories, including Actions.
    /// Required for any API call that reads or mutates repository resources.
    public static let repo = "repo"

    /// Read the authenticated user's profile information (login, name, avatar URL, etc.).
    /// Sufficient for display purposes; does not grant write access to the user's account.
    public static let readUser = "read:user"

    /// Read and write access to organisation members and teams.
    /// Required for API calls that list or manage organisation membership.
    public static let readOrg = "read:org"

    /// Full admin access to the authenticated user's gists.
    /// Required for API calls that create, update, or delete gists.
    public static let gist = "gist"
}
