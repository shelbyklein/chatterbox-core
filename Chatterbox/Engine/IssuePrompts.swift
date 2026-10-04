import Foundation

/// The messages the Issues panel sends into a chat. They show in the transcript as the
/// user's own message, so each reads as something a person would write: a short line on
/// what's wanted, then the details.
enum IssuePrompts {
    /// Long issue bodies are cut here; the agent can read the rest with `gh` if it needs to.
    static let bodyLimit = 12_000
    /// The most issues a triage message lists.
    static let triageLimit = 150

    /// "Work on this" for Claude without the dev-work skill, and for Codex.
    static func work(on issue: GitHubIssue, repo: String) -> String {
        var text = "Work on issue #\(issue.number) in \(repo): \(issue.title)\n\n\(issue.url.absoluteString)"
        let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            let clipped = body.count > bodyLimit ? String(body.prefix(bodyLimit)) + "\n\n(cut off; the full issue is at the link above)" : body
            text += "\n\n" + clipped
        }
        return text
    }

    /// "/dev-work #N" when the user's Claude Code has that skill.
    static func devWork(_ issue: GitHubIssue) -> String { "/dev-work #\(issue.number)" }

    /// Asks the agent to rank the open issues and then ask which one to take on next.
    /// `questionTool` is the agent's own tool name, so it knows which to reach for.
    static func triage(_ issues: [GitHubIssue], repo: String, questionTool: String, now: Date = Date()) -> String {
        let listed = Array(issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }.prefix(triageLimit))
        let count = listed.count < issues.count
            ? "\(issues.count) open issues; the \(listed.count) most recently updated are below"
            : "\(issues.count) open issue\(issues.count == 1 ? "" : "s")"
        let lines = listed.map { line(for: $0, now: now) }
        return """
        Please triage the open issues in \(repo) (\(count)).

        1. Rank them by impact and effort.
        2. Flag likely duplicates, stale issues, and issues missing labels.
        3. Then ask me which to work on next with your \(questionTool) tool, offering your top 3\u{2013}5 picks as options. If that tool isn't available, list the picks and ask in plain text.

        Don't change anything on GitHub (labels, comments, closing) unless I ask.

        \(lines.joined(separator: "\n"))
        """
    }

    /// "#12 Title · bug, ui · 34d old, updated 3d ago · 2 comments · @alice"
    static func line(for issue: GitHubIssue, now: Date = Date()) -> String {
        var parts = ["#\(issue.number) \(issue.title)"]
        parts.append(issue.labels.isEmpty ? "no labels" : issue.labels.map(\.name).joined(separator: ", "))
        var age: [String] = []
        if let days = ShortAge.days(since: issue.createdAt, now: now) { age.append("\(days)d old") }
        if let days = ShortAge.days(since: issue.updatedAt, now: now) { age.append("updated \(days)d ago") }
        if !age.isEmpty { parts.append(age.joined(separator: ", ")) }
        parts.append("\(issue.commentCount) comment\(issue.commentCount == 1 ? "" : "s")")
        parts.append(issue.assignees.isEmpty ? "unassigned" : issue.assignees.map { "@" + $0.login }.joined(separator: " "))
        return "- " + parts.joined(separator: " \u{00B7} ")
    }
}
