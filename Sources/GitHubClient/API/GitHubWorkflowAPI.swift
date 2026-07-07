// GitHubWorkflowAPI.swift
// GitHubClient

import Foundation

// MARK: - Models

/// A GitHub Actions workflow run as returned by the REST API.
public struct GitHubWorkflowRun: Decodable, Sendable {
    /// Unique numeric run ID assigned by GitHub.
    public let id: Int
    /// Display name of the workflow (may be `nil` for anonymous workflows).
    public let name: String?
    /// Raw status string from the API: `"queued"`, `"in_progress"`, or `"completed"`.
    public let status: String
    /// Raw conclusion string: `"success"`, `"failure"`, `"cancelled"`, or `nil` when still running.
    public let conclusion: String?
    /// The branch this run was triggered on.
    public let headBranch: String?
    /// The commit SHA this run was triggered on.
    public let headSha: String
    /// GitHub web URL for this run.
    public let htmlUrl: String
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let createdAt: String
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let updatedAt: String

    /// Coding keys mapping snake_case JSON fields to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        /// Maps `id`.
        case id
        /// Maps `name`.
        case name
        /// Maps `status`.
        case status
        /// Maps `conclusion`.
        case conclusion
        /// Maps `head_branch`.
        case headBranch = "head_branch"
        /// Maps `head_sha`.
        case headSha = "head_sha"
        /// Maps `html_url`.
        case htmlUrl = "html_url"
        /// Maps `created_at`.
        case createdAt = "created_at"
        /// Maps `updated_at`.
        case updatedAt = "updated_at"
    }
}

/// A GitHub Actions job as returned by the REST API.
public struct GitHubJob: Decodable, Identifiable, Equatable, Sendable {
    /// Unique numeric job ID assigned by GitHub.
    public let id: Int
    /// The workflow run this job belongs to. Maps the `run_id` JSON field.
    public let runID: Int
    /// Display name of the job.
    public let name: String
    /// Raw status string — NOT `JobStatus` (a RunBotCore type).
    public let status: String
    /// Raw conclusion string — NOT `JobConclusion` (a RunBotCore type).
    public let conclusion: String?
    /// GitHub web URL for this job.
    public let htmlUrl: String?
    /// Name of the runner executing this job, or `nil` if not yet assigned.
    public let runnerName: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let startedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let completedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let createdAt: String?
    /// Steps within this job.
    public let steps: [GitHubStep]

    /// Coding keys mapping snake_case JSON fields to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        /// Maps `id`.
        case id
        /// Maps `name`.
        case name
        /// Maps `status`.
        case status
        /// Maps `conclusion`.
        case conclusion
        /// Maps `steps`.
        case steps
        /// Maps `run_id`.
        case runID = "run_id"
        /// Maps `html_url`.
        case htmlUrl = "html_url"
        /// Maps `runner_name`.
        case runnerName = "runner_name"
        /// Maps `started_at`.
        case startedAt = "started_at"
        /// Maps `completed_at`.
        case completedAt = "completed_at"
        /// Maps `created_at`.
        case createdAt = "created_at"
    }

    /// Decodes a `GitHubJob` from the GitHub REST API JSON payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        runID = try container.decode(Int.self, forKey: .runID)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
        htmlUrl = try container.decodeIfPresent(String.self, forKey: .htmlUrl)
        runnerName = try container.decodeIfPresent(String.self, forKey: .runnerName)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        // `try?` here is intentional, not a silent-failure smell.
        // The GitHub API omits the `steps` key entirely for queued jobs — it is
        // not an empty array but an absent key. `decodeIfPresent` returns `nil`
        // for an absent key, and `try?` converts a malformed-but-present array
        // to `nil` as well. Both cases correctly fall back to `[]`.
        // This is a known API shape difference, not a decode bug.
        steps = (try? container.decodeIfPresent([GitHubStep].self, forKey: .steps)) ?? []
    }

    /// Full memberwise initialiser — used by `copying(...)` helpers and tests.
    public init(
        id: Int,
        runID: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        htmlUrl: String? = nil,
        runnerName: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        createdAt: String? = nil,
        steps: [GitHubStep] = []
    ) {
        self.id = id; self.runID = runID; self.name = name; self.status = status
        self.conclusion = conclusion; self.htmlUrl = htmlUrl
        self.runnerName = runnerName; self.startedAt = startedAt
        self.completedAt = completedAt; self.createdAt = createdAt
        self.steps = steps
    }

    // MARK: copying helpers — used by ActiveJob.withUpdatedRaw

    /// Returns a copy of this job with `runnerName` replaced.
    public func copying(runnerName newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: newValue, startedAt: startedAt,
                  completedAt: completedAt, createdAt: createdAt, steps: steps)
    }

    /// Returns a copy of this job with `startedAt` replaced.
    public func copying(startedAt newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: newValue,
                  completedAt: completedAt, createdAt: createdAt, steps: steps)
    }

    /// Returns a copy of this job with `completedAt` replaced.
    public func copying(completedAt newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: newValue, createdAt: createdAt, steps: steps)
    }

    /// Returns a copy of this job with `createdAt` replaced.
    public func copying(createdAt newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: completedAt, createdAt: newValue, steps: steps)
    }

    /// Returns a copy of this job with `steps` replaced.
    public func copying(steps newValue: [GitHubStep]) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: completedAt, createdAt: createdAt, steps: newValue)
    }

    /// Returns a copy of this job with `conclusion` replaced.
    public func copying(conclusion newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: newValue, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: completedAt, createdAt: createdAt, steps: steps)
    }
}

/// A single step within a GitHub Actions job.
public struct GitHubStep: Decodable, Equatable, Sendable {
    /// Display name of the step.
    public let name: String
    /// Raw status string from the API.
    public let status: String
    /// Raw conclusion string from the API, or `nil` if still running.
    public let conclusion: String?
    /// 1-based step number within the job.
    public let number: Int
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let startedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let completedAt: String?

    /// Coding keys mapping snake_case JSON fields to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        /// Maps `name`.
        case name
        /// Maps `status`.
        case status
        /// Maps `conclusion`.
        case conclusion
        /// Maps `number`.
        case number
        /// Maps `started_at`.
        case startedAt = "started_at"
        /// Maps `completed_at`.
        case completedAt = "completed_at"
    }

    /// Memberwise initialiser for use within `GitHubClient` only (e.g. `copying` helpers).
    ///
    /// Intentionally `internal` — `GitHubStep` is `Decodable`-only at the public
    /// API surface. Tests construct instances via the JSON round-trip shim in
    /// `TestModelHelpers.swift` (`@testable import GitHubClient`).
    init(
        number: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil
    ) {
        self.number = number
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// The result of fetching active workflow runs, distinguishing auth/rate-limit failures
/// from partial and full successes.
///
/// - Note: `.authFailure` is currently never produced by `fetchActiveRuns` — the
///   underlying transport collapses all failure modes to `nil`, so auth failures
///   are surfaced as `.noToken` (first page) or `.rateLimited` (subsequent pages).
///   The case is part of the intended API for when the transport exposes a typed
///   `ExecuteResult`-returning call (tracked in #1950). Callers should handle it
///   defensively but must not rely on it being produced today.
public enum GitHubRunsFetchResult: Sendable {
    /// All pages fetched successfully.
    case success([GitHubWorkflowRun])
    /// Rate limit hit mid-fetch — results are valid but may be incomplete.
    case rateLimited([GitHubWorkflowRun])
    /// Token was rejected (401/403 without rate-limit headers) — discard everything.
    /// Currently unreachable from `fetchActiveRuns`; see type-level note above.
    case authFailure
    /// No GitHub token is configured — or any first-page transport failure
    /// (see type-level note above).
    case noToken
}

// MARK: - API

/// Fetches active (queued + in_progress) workflow runs for a scope.
///
/// Each `transport.apiPaginated` call records its own hits in the transport layer
/// (one count per successful HTTP page). No manual `apiCallCounter.record()` is needed.
///
/// `apiPaginated` returns a flat JSON array encoded as `Data`. This function decodes
/// that directly as `[GitHubWorkflowRun]` — **not** via a `{"workflow_runs":[...]}` wrapper.
/// The GitHub REST API wraps runs in a `workflow_runs` key, but `apiPaginated` strips the
/// envelope and returns only the array items, so no wrapper is needed here.
///
/// - Note: **Nil-transport heuristic —** `transport.apiPaginated` collapses all
///   failure modes (no token, rate limit, 401/403, network error) to `nil` because
///   the current transport API does not expose a typed result. The heuristic is:
///   nil on the **first** page (when `allRuns` is still empty) is surfaced as
///   `.noToken` to prompt sign-in; nil on a **subsequent** page is surfaced as
///   `.rateLimited` so callers keep the partial results. This means a rate-limit
///   hit on the first page is misclassified as `.noToken`, and a 401 mid-loop
///   is misclassified as `.rateLimited`. Both are known limitations tracked
///   in #1950 (typed `ExecuteResult` on the transport protocol).
///
/// - Note: **Rate-limit budget change (PR #37).** Before PR #37, `fetchActiveRuns`
///   was counted as **1** logical operation (record() was called once after the
///   for-loop). After PR #37, record() fires inside `interpretHTTPResponse` on
///   every 2xx response, so a **fully successful** invocation registers **2** hits
///   against the hourly budget — one for the `in_progress` query and one for the
///   `queued` query. Early exits record only the pages that completed: **0** hits
///   on `.noToken`, **1** hit on `.rateLimited`. Callers that track or display the
///   counter value should account for this.
///
/// - Parameters:
///   - scope: The org or repo scope to query.
///   - transport: The network transport to use. Defaults to `currentTransport`
///     (wired at launch by `GitHubClient.init`). Pass a mock in tests.
@concurrent
public func fetchActiveRuns(
    scope: Scope,
    transport: any GitHubTransportProtocol = currentTransport
) async -> GitHubRunsFetchResult {
    let statuses = ["in_progress", "queued"]
    var allRuns: [GitHubWorkflowRun] = []
    var seenIDs = Set<Int>()
    for status in statuses {
        let endpoint = "\(scope.apiPrefix)/actions/runs?status=\(status)&per_page=\(GitHubConstants.activeRunsPageSize)"
        guard let data = await transport.apiPaginated(endpoint) else {
            // See the nil-transport heuristic note in the function doc comment above.
            if allRuns.isEmpty { return .noToken } else { return .rateLimited(allRuns) }
        }
        // apiPaginated returns a flat JSON array — decode directly as [GitHubWorkflowRun].
        // Do NOT use a {"workflow_runs":[...]} wrapper here: apiPaginated strips the
        // GitHub API envelope and encodes only the array items into the returned Data.
        do {
            let runs = try transport.decoder.decode([GitHubWorkflowRun].self, from: data)
            for run in runs where seenIDs.insert(run.id).inserted {
                allRuns.append(run)
            }
        } catch {
            transport.logger?.log(
                "fetchActiveRuns › decode failed for status=\(status): \(error)",
                category: "transport"
            )
        }
    }
    return .success(allRuns)
}

/// Fetches all jobs for a given workflow run ID.
///
/// Each `transport.apiPaginated` call records its own hits in the transport layer
/// (one count per successful HTTP page). No manual `apiCallCounter.record()` is needed.
///
/// - Parameters:
///   - runID: The numeric GitHub workflow run ID.
///   - scope: The org or repo scope the run belongs to.
///   - transport: The network transport to use. Defaults to `currentTransport`
///     (wired at launch by `GitHubClient.init`). Pass a mock in tests.
@concurrent
public func fetchJobs(
    runID: Int,
    scope: Scope,
    transport: any GitHubTransportProtocol = currentTransport
) async -> [GitHubJob] {
    let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/jobs?per_page=\(GitHubConstants.maxPageSize)"
    guard let data = await transport.apiPaginated(endpoint) else { return [] }
    struct Response: Decodable { let jobs: [GitHubJob] }
    do {
        return try transport.decoder.decode(Response.self, from: data).jobs
    } catch {
        transport.logger?.log(
            "fetchJobs › decode failed for runID=\(runID): \(error)",
            category: "transport"
        )
        return []
    }
}
