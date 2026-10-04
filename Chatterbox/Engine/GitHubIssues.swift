import Foundation
import Observation

// Reading a repo's issues and pull requests through the user's `gh`. Everything here is
// read-only: the app never labels, comments on, or closes anything. Changes on GitHub are
// left to the agent in the chat, where they go through its normal approvals.
//
// Calls go through `gh api` (GitHub's REST API) rather than `gh issue list`: REST reports
// comment counts without fetching every comment, and it draws on a separate, larger rate
// limit than the GraphQL one `gh issue list` uses.

struct GitHubLabel: Hashable {
    var name: String
    /// Hex without "#", e.g. "d73a4a".
    var color: String
}

struct GitHubUser: Hashable {
    var login: String
    var avatarURL: URL?
}

struct GitHubIssue: Identifiable, Hashable {
    var id: Int { number }
    var number: Int
    var title: String
    var body: String
    var labels: [GitHubLabel]
    var assignees: [GitHubUser]
    var author: GitHubUser?
    var createdAt: Date?
    var updatedAt: Date?
    var commentCount: Int
    var milestone: String?
    var url: URL
    /// "open" or "closed".
    var state: String
}

struct GitHubComment: Identifiable, Hashable {
    var id: Int
    var author: GitHubUser?
    var body: String
    var createdAt: Date?
}

struct GitHubIssueDetail: Hashable {
    var issue: GitHubIssue
    var comments: [GitHubComment]
}

struct GitHubPullRequest: Hashable {
    var number: Int
    var title: String
    var url: URL
    /// "open", "closed", "merged", or "draft".
    var state: String
}

/// The issue a chat is working on, shown in the toolbar. Stored on the chat's record.
struct CurrentIssue: Codable, Equatable, Hashable {
    var number: Int
    var title: String
    var url: String
    /// "owner/name", so the chip can find the issue again in the panel.
    var repo: String?
}

enum GitHubIssuesError: LocalizedError {
    case noCLI
    case notSignedIn
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noCLI: "The GitHub CLI (`gh`) isn't installed. Install it (`brew install gh`), then run `gh auth login` in Terminal."
        case .notSignedIn: "`gh` isn't signed in to GitHub. Run `gh auth login` in Terminal, then refresh."
        case .failed(let message): message
        }
    }

    /// Turns gh's stderr into something a person can act on.
    static func from(_ output: Git.Output, repo: String) -> GitHubIssuesError {
        let err = output.err.isEmpty ? output.out : output.err
        let lower = err.lowercased()
        if lower.contains("gh auth login") || lower.contains("not logged in") || lower.contains("http 401")
            || lower.contains("bad credentials") {
            return .notSignedIn
        }
        if lower.contains("http 404") || lower.contains("not found") {
            return .failed("Couldn't find \(repo) on GitHub, or your `gh` account can't see it.")
        }
        if lower.contains("http 410") || lower.contains("issues are disabled") {
            return .failed("Issues are turned off for \(repo).")
        }
        if lower.contains("rate limit") {
            return .failed("GitHub's rate limit for your account is used up. Try again in a few minutes.")
        }
        return .failed(err.isEmpty ? "`gh` failed (exit \(output.status))." : err)
    }
}

/// The `gh api` calls and the parsing of what they return.
enum GitHubIssuesAPI {
    /// The most issues the panel loads, most recently updated first.
    static let issueLimit = 200

    private static func gh() throws -> String {
        guard let gh = GitHubCLI.locate() else { throw GitHubIssuesError.noCLI }
        return gh
    }

    private static func get(_ path: String, repo: String) async throws -> JSON {
        let result = await Git.run(try gh(), ["api", "-H", "Accept: application/vnd.github+json", path])
        guard result.status == 0 else { throw GitHubIssuesError.from(result, repo: repo) }
        do { return try JSON.parse(result.out) } catch {
            throw GitHubIssuesError.failed("GitHub sent something unexpected for \(repo).")
        }
    }

    /// Open issues, without pull requests (which the REST issues endpoint mixes in).
    static func openIssues(_ repo: String) async throws -> [GitHubIssue] {
        var issues: [GitHubIssue] = []
        for page in 1...5 {
            let json = try await get("repos/\(repo)/issues?state=open&sort=updated&direction=desc&per_page=100&page=\(page)", repo: repo)
            let items = json.array ?? []
            issues += items.filter { $0["pull_request"] == nil }.compactMap(parseIssue)
            if items.count < 100 || issues.count >= issueLimit { break }
        }
        return Array(issues.prefix(issueLimit))
    }

    static func detail(_ repo: String, number: Int) async throws -> GitHubIssueDetail {
        let issueJSON = try await get("repos/\(repo)/issues/\(number)", repo: repo)
        guard let issue = parseIssue(issueJSON) else { throw GitHubIssuesError.failed("Couldn't read issue #\(number).") }
        // Up to 300 comments; a longer thread shows a link to the rest on GitHub.
        var comments: [GitHubComment] = []
        var page = 1
        while comments.count < issue.commentCount, page <= 3 {
            let items = try await get("repos/\(repo)/issues/\(number)/comments?per_page=100&page=\(page)", repo: repo).array ?? []
            comments += items.compactMap(parseComment)
            if items.count < 100 { break }
            page += 1
        }
        return GitHubIssueDetail(issue: issue, comments: comments)
    }

    /// The signed-in login, for "Assigned to me".
    static func currentLogin() async throws -> String {
        let result = await Git.run(try gh(), ["api", "user", "--jq", ".login"])
        guard result.status == 0, !result.out.isEmpty else { throw GitHubIssuesError.from(result, repo: "your account") }
        return result.out
    }

    /// The newest pull request whose head is `branch` in the repo itself.
    static func pullRequest(_ repo: String, branch: String) async throws -> GitHubPullRequest? {
        let owner = repo.split(separator: "/").first.map(String.init) ?? ""
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let head = "\(owner):\(branch)".addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: ":"))) ?? branch
        let json = try await get("repos/\(repo)/pulls?head=\(head)&state=all&per_page=1", repo: repo)
        return json.array?.first.flatMap(parsePullRequest)
    }

    // MARK: - Parsing

    private static let dates = ISO8601DateFormatter()

    static func parseUser(_ json: JSON?) -> GitHubUser? {
        guard let json, let login = json["login"]?.string else { return nil }
        return GitHubUser(login: login, avatarURL: json["avatar_url"]?.string.flatMap(URL.init(string:)))
    }

    static func parseIssue(_ json: JSON) -> GitHubIssue? {
        guard let number = json["number"]?.int, let title = json["title"]?.string,
              let url = json["html_url"]?.string.flatMap(URL.init(string:)) else { return nil }
        return GitHubIssue(
            number: number, title: title, body: json["body"]?.string ?? "",
            labels: (json["labels"]?.array ?? []).compactMap { label in
                label["name"]?.string.map { GitHubLabel(name: $0, color: label["color"]?.string ?? "888888") }
            },
            assignees: (json["assignees"]?.array ?? []).compactMap(parseUser),
            author: parseUser(json["user"]),
            createdAt: json["created_at"]?.string.flatMap(dates.date(from:)),
            updatedAt: json["updated_at"]?.string.flatMap(dates.date(from:)),
            commentCount: json["comments"]?.int ?? 0,
            milestone: json["milestone"]?["title"]?.string,
            url: url,
            state: json["state"]?.string ?? "open")
    }

    static func parseComment(_ json: JSON) -> GitHubComment? {
        guard let id = json["id"]?.int else { return nil }
        return GitHubComment(id: id, author: parseUser(json["user"]), body: json["body"]?.string ?? "",
                             createdAt: json["created_at"]?.string.flatMap(dates.date(from:)))
    }

    static func parsePullRequest(_ json: JSON) -> GitHubPullRequest? {
        guard let number = json["number"]?.int, let url = json["html_url"]?.string.flatMap(URL.init(string:)) else { return nil }
        let merged = json["merged_at"]?.string != nil
        let state = merged ? "merged" : json["draft"]?.bool == true && json["state"]?.string == "open" ? "draft" : json["state"]?.string ?? "open"
        return GitHubPullRequest(number: number, title: json["title"]?.string ?? "", url: url, state: state)
    }
}

/// Issues per repo, loaded on demand and kept until refreshed, plus issue details and the
/// pull request for each branch.
@MainActor
@Observable
final class GitHubIssuesStore {
    static let shared = GitHubIssuesStore()

    struct RepoIssues {
        var issues: [GitHubIssue] = []
        var loadedAt: Date?
        var loading = false
        var error: String?
    }

    enum DetailState {
        case loading
        case loaded(GitHubIssueDetail)
        case failed(String)
    }

    private(set) var repos: [String: RepoIssues] = [:]
    private(set) var details: [String: DetailState] = [:]
    /// Keyed "owner/name|branch". A missing key means not looked up yet.
    private(set) var pullRequests: [String: GitHubPullRequest?] = [:]
    private(set) var login: String?

    func issues(for repo: String) -> RepoIssues { repos[repo.lowercased()] ?? RepoIssues() }

    /// Loads the repo's issues unless they're already here; `force` re-reads them.
    func load(_ repo: String, force: Bool = false) async {
        let key = repo.lowercased()
        var state = repos[key] ?? RepoIssues()
        guard !state.loading, force || state.loadedAt == nil else { return }
        state.loading = true
        repos[key] = state
        do {
            state.issues = try await GitHubIssuesAPI.openIssues(repo)
            state.loadedAt = Date()
            state.error = nil
        } catch {
            state.error = error.localizedDescription
        }
        state.loading = false
        repos[key] = state
        if login == nil { login = try? await GitHubIssuesAPI.currentLogin() }
    }

    func detail(_ repo: String, _ number: Int) -> DetailState? { details["\(repo.lowercased())#\(number)"] }

    func loadDetail(_ repo: String, _ number: Int, force: Bool = false) async {
        let key = "\(repo.lowercased())#\(number)"
        if !force, let existing = details[key], case .loaded = existing { return }
        if case .loading = details[key] { return }
        details[key] = .loading
        do { details[key] = .loaded(try await GitHubIssuesAPI.detail(repo, number: number)) } catch {
            details[key] = .failed(error.localizedDescription)
        }
    }

    func pullRequest(_ repo: String, branch: String) -> GitHubPullRequest? {
        pullRequests["\(repo.lowercased())|\(branch)"] ?? nil
    }

    /// Looks up the branch's pull request again. Failures keep what was known before, since
    /// the chip is a convenience and an error there isn't worth showing.
    func refreshPullRequest(_ repo: String, branch: String) async {
        let key = "\(repo.lowercased())|\(branch)"
        do {
            let pr = try await GitHubIssuesAPI.pullRequest(repo, branch: branch)
            if pullRequests[key] != .some(pr) { pullRequests[key] = .some(pr) }
        } catch {
            if pullRequests[key] == nil { pullRequests[key] = .some(nil) }
        }
    }
}

/// Short relative ages for issue rows: "now", "5m", "3h", "12d", "4mo", "2y".
enum ShortAge {
    static func string(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 60): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }

    static func days(since date: Date?, now: Date = Date()) -> Int? {
        date.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }
}
