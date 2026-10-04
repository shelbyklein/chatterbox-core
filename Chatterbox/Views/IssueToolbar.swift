import AppKit
import SwiftUI

/// Toolbar items next to the repo chip: the chat's current issue, the branch's pull request,
/// and the Issues panel button (⌘⇧I).
struct IssueToolbarItems: View {
    let session: ChatSession
    let panel: IssuesPanelState
    let repo: String
    let branch: String?
    private var store: GitHubIssuesStore { .shared }

    var body: some View {
        HStack(spacing: 8) {
            if let issue = session.record.currentIssue { currentIssueChip(issue) }
            if let branch, let pr = store.pullRequest(repo, branch: branch) { pullRequestChip(pr) }
            Button { panel.toggle() } label: {
                Label("Issues", systemImage: "exclamationmark.bubble")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help("Show or hide \(repo)'s open issues (\u{2318}\u{21E7}I)")
        }
        // Like the git status, re-check after each turn: the agent may have opened a PR.
        .task(id: "\(repo)|\(branch ?? "")|\(session.isRunning)") {
            guard let branch, !session.isRunning else { return }
            await store.refreshPullRequest(repo, branch: branch)
        }
    }

    private func currentIssueChip(_ issue: CurrentIssue) -> some View {
        Menu {
            if let url = URL(string: issue.url) {
                Button("Open Issue") { NSWorkspace.shared.open(url) }
            }
            Button("Show in Issues Panel") { panel.show(issue: issue.number) }
            Divider()
            Button("Clear") { session.setCurrentIssue(nil) }
        } label: {
            ToolbarLabel("#\(issue.number) \u{00B7} \(Self.short(issue.title))", systemImage: "smallcircle.filled.circle")
        }
        .help("This chat is working on #\(issue.number): \(issue.title)")
    }

    private func pullRequestChip(_ pr: GitHubPullRequest) -> some View {
        Menu {
            Button("Open Pull Request") { NSWorkspace.shared.open(pr.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
            }
        } label: {
            ToolbarLabel("PR #\(pr.number) \u{00B7} \(pr.state.capitalized)", systemImage: "arrow.triangle.pull")
        } primaryAction: {
            NSWorkspace.shared.open(pr.url)
        }
        .help("Pull request #\(pr.number) for \(branch ?? "this branch"): \(pr.title) (\(pr.state))")
    }

    static func short(_ title: String, limit: Int = 28) -> String {
        title.count > limit ? String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : title
    }
}
