import Foundation

/// Sending GitHub issues into a chat. The app only reads GitHub; anything the agent then
/// changes there goes through its own tools and approvals.
extension ChatSession {
    /// Claude Code's dev-work skill, when the user has it, takes an issue number directly.
    var hasDevWorkSkill: Bool {
        record.backend == .claude && (claudeCommands ?? ClaudeModels.shared.commands).contains { $0.name == "dev-work" }
    }

    /// The agent's tool for asking the user a multiple-choice question.
    var questionToolName: String { record.backend == .claude ? "AskUserQuestion" : "request_user_input" }

    /// Starts (or, mid-turn, steers) the agent onto an issue and marks it as this chat's current one.
    func workOn(_ issue: GitHubIssue, repo: String) {
        let text = hasDevWorkSkill ? IssuePrompts.devWork(issue) : IssuePrompts.work(on: issue, repo: repo)
        setCurrentIssue(CurrentIssue(number: issue.number, title: issue.title, url: issue.url.absoluteString, repo: repo))
        send(text)
    }

    func triage(_ issues: [GitHubIssue], repo: String) {
        send(IssuePrompts.triage(issues, repo: repo, questionTool: questionToolName))
    }

    func setCurrentIssue(_ issue: CurrentIssue?) {
        guard record.currentIssue != issue else { return }
        record.currentIssue = issue
        onChange?(self)
    }
}
