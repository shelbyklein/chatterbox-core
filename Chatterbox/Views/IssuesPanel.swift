import AppKit
import SwiftUI

/// Whether a chat's Issues panel is open, which issue it shows, and its filters. Kept
/// outside the list so the filters survive a trip into an issue and back.
@MainActor
@Observable
final class IssuesPanelState {
    enum Sort: String, CaseIterable, Identifiable {
        case updated, newest, comments
        var id: String { rawValue }
        var label: String {
            switch self {
            case .updated: "Recently Updated"
            case .newest: "Newest"
            case .comments: "Most Commented"
            }
        }
    }

    /// Milestone filter: nil is any, `noMilestone` is issues without one.
    static let noMilestone = "\u{0}none"

    var isOpen = false
    /// The issue shown in detail; nil shows the list.
    var selected: Int?
    var search = ""
    var label: String?
    var milestone: String?
    var assignedToMe = false
    var sort: Sort = .updated

    var isFiltering: Bool { !search.isEmpty || label != nil || milestone != nil || assignedToMe }

    func show(issue: Int? = nil) {
        selected = issue
        isOpen = true
    }

    func toggle() { isOpen.toggle() }

    func apply(to issues: [GitHubIssue], login: String?) -> [GitHubIssue] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let number = Int(query.hasPrefix("#") ? String(query.dropFirst()) : query)
        let filtered = issues.filter { issue in
            if let label, !issue.labels.contains(where: { $0.name == label }) { return false }
            if let milestone {
                if milestone == Self.noMilestone ? issue.milestone != nil : issue.milestone != milestone { return false }
            }
            if assignedToMe, !issue.assignees.contains(where: { $0.login.caseInsensitiveCompare(login ?? "") == .orderedSame }) { return false }
            guard !query.isEmpty else { return true }
            return issue.number == number || issue.title.lowercased().contains(query)
                || issue.labels.contains { $0.name.lowercased().contains(query) }
                || issue.author?.login.lowercased().contains(query) == true
        }
        switch sort {
        case .updated: return filtered.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .newest: return filtered.sorted { $0.number > $1.number }
        case .comments: return filtered.sorted { ($0.commentCount, $0.number) > ($1.commentCount, $1.number) }
        }
    }
}

/// The right-hand panel listing the project repo's open issues, and one issue's detail.
/// It only reads GitHub. "Work on This" and "Triage" send a message to the chat's agent.
struct IssuesPanel: View {
    let session: ChatSession
    @Bindable var panel: IssuesPanelState
    /// A send that would steer a running turn, waiting for the user to confirm.
    @State private var pending: PendingSend?

    enum PendingSend: Identifiable {
        case work(GitHubIssue, repo: String)
        case triage([GitHubIssue], repo: String)
        var id: String {
            switch self {
            case .work(let issue, _): "work\(issue.number)"
            case .triage: "triage"
            }
        }
    }

    var body: some View {
        Group {
            if let repo = session.record.githubRepo {
                if let number = panel.selected {
                    IssueDetailView(repo: repo, number: number, onBack: { panel.selected = nil }, onWork: { request(.work($0, repo: repo)) })
                } else {
                    IssueListView(repo: repo, panel: panel, onWork: { request(.work($0, repo: repo)) },
                                  onTriage: { request(.triage($0, repo: repo)) })
                }
            } else {
                IssuesMessage(systemImage: "folder.badge.questionmark",
                              text: session.record.projectFolder == nil
                                ? "Bind this chat to a project folder to see its GitHub issues."
                                : "This project's folder has no GitHub remote, so there are no issues to show.")
            }
        }
        .alert("Send while \(session.record.backend.label) is working?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { send in
            Button("Send Anyway") { perform(send) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(session.record.backend.label) is in the middle of a turn. This message joins it and changes what it's working on.")
        }
    }

    private func request(_ send: PendingSend) {
        if session.isRunning { pending = send } else { perform(send) }
    }

    private func perform(_ send: PendingSend) {
        switch send {
        case .work(let issue, let repo): session.workOn(issue, repo: repo)
        case .triage(let issues, let repo): session.triage(issues, repo: repo)
        }
    }
}

// MARK: - List

private struct IssueListView: View {
    let repo: String
    @Bindable var panel: IssuesPanelState
    let onWork: (GitHubIssue) -> Void
    let onTriage: ([GitHubIssue]) -> Void
    private var store: GitHubIssuesStore { .shared }

    var body: some View {
        let state = store.issues(for: repo)
        VStack(spacing: 0) {
            header(state)
            filters(state.issues)
            Divider()
            content(state)
        }
        .task(id: repo) { await store.load(repo) }
    }

    private func header(_ state: GitHubIssuesStore.RepoIssues) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Issues").font(.headline)
                Text(repo).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if state.loading { ProgressView().controlSize(.small) }
            Button { Task { await store.load(repo, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(state.loading)
                .help("Reload the open issues from GitHub")
            Button("Triage") { onTriage(state.issues) }
                .disabled(state.issues.isEmpty)
                .help("Ask the agent to rank these issues, flag duplicates and stale ones, and suggest what to work on next")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func filters(_ issues: [GitHubIssue]) -> some View {
        let labels = Array(Set(issues.flatMap(\.labels))).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let milestones = Array(Set(issues.compactMap(\.milestone))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return VStack(spacing: 6) {
            TextField("Search issues", text: $panel.search)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Menu {
                    Picker("Label", selection: $panel.label) {
                        Text("Any Label").tag(String?.none)
                        ForEach(labels, id: \.name) { label in
                            Text(label.name).tag(String?.some(label.name))
                        }
                    }
                    .pickerStyle(.inline)
                } label: { Text(panel.label ?? "Label") }
                .fixedSize()
                if !milestones.isEmpty {
                    Menu {
                        Picker("Milestone", selection: $panel.milestone) {
                            Text("Any Milestone").tag(String?.none)
                            Text("No Milestone").tag(String?.some(IssuesPanelState.noMilestone))
                            ForEach(milestones, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(panel.milestone.map { $0 == IssuesPanelState.noMilestone ? "No Milestone" : $0 } ?? "Milestone")
                    }
                    .fixedSize()
                }
                Toggle("Mine", isOn: $panel.assignedToMe)
                    .toggleStyle(.button)
                    .disabled(store.login == nil)
                    .help(store.login.map { "Only issues assigned to @\($0)" } ?? "Assigned to me (needs a signed-in `gh`)")
                Spacer(minLength: 0)
                Menu {
                    Picker("Sort", selection: $panel.sort) {
                        ForEach(IssuesPanelState.Sort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort: \(panel.sort.label)")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func content(_ state: GitHubIssuesStore.RepoIssues) -> some View {
        if let error = state.error, state.issues.isEmpty {
            IssuesMessage(systemImage: "exclamationmark.triangle", text: error) {
                Button("Try Again") { Task { await store.load(repo, force: true) } }
            }
        } else if state.loadedAt == nil {
            IssuesMessage(systemImage: nil, text: "Loading issues\u{2026}")
        } else if state.issues.isEmpty {
            IssuesMessage(systemImage: "checkmark.circle", text: "No open issues in \(repo).")
        } else {
            let shown = panel.apply(to: state.issues, login: store.login)
            if shown.isEmpty {
                IssuesMessage(systemImage: "line.3.horizontal.decrease.circle", text: "No open issues match these filters.") {
                    Button("Clear Filters") {
                        panel.search = ""; panel.label = nil; panel.milestone = nil; panel.assignedToMe = false
                    }
                }
            } else {
                List {
                    if let error = state.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(shown) { issue in
                        Button { panel.selected = issue.number } label: { IssueRow(issue: issue) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Work on This") { onWork(issue) }
                                Divider()
                                Button("Open on GitHub") { NSWorkspace.shared.open(issue.url) }
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(issue.url.absoluteString, forType: .string)
                                }
                            }
                    }
                }
                .listStyle(.plain)
                footer(shown: shown.count, total: state.issues.count)
            }
        }
    }

    private func footer(shown: Int, total: Int) -> some View {
        let atLimit = total >= GitHubIssuesAPI.issueLimit
        return Text(shown == total ? "\(total) open\(atLimit ? " (the most recently updated \(total))" : "")" : "\(shown) of \(total) open")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

private struct IssueRow: View {
    let issue: GitHubIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("#\(issue.number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).lineLimit(3)
                if !issue.labels.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(issue.labels, id: \.name) { LabelPill(label: $0) }
                    }
                }
                HStack(spacing: 10) {
                    Text(ShortAge.string(since: issue.updatedAt))
                        .help("Opened \(ShortAge.string(since: issue.createdAt)) ago, updated \(ShortAge.string(since: issue.updatedAt)) ago")
                    if issue.commentCount > 0 {
                        Label("\(issue.commentCount)", systemImage: "bubble.left").labelStyle(SpacedLabelStyle(spacing: 3))
                    }
                    if let milestone = issue.milestone {
                        Label(milestone, systemImage: "flag").labelStyle(SpacedLabelStyle(spacing: 3)).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            AssigneeStack(users: issue.assignees)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

private struct IssueDetailView: View {
    let repo: String
    let number: Int
    let onBack: () -> Void
    let onWork: (GitHubIssue) -> Void
    private var store: GitHubIssuesStore { .shared }

    private var fallbackURL: URL { URL(string: "https://github.com/\(repo)/issues/\(number)")! }

    /// A step smaller than the transcript, to suit the narrower panel.
    private var style: ReaderStyle {
        var style = ReaderStyle.defaults
        style.textSize = 12
        style.codeSize = 11
        style.paragraphSpacing = 8
        return style
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) { Label("Issues", systemImage: "chevron.left").labelStyle(SpacedLabelStyle(spacing: 3)) }
                    .buttonStyle(.borderless)
                Spacer()
                Button { Task { await store.loadDetail(repo, number, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload this issue")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .task(id: "\(repo)#\(number)") { await store.loadDetail(repo, number) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.detail(repo, number) {
        case .loaded(let detail):
            ScrollView { loaded(detail).padding(14) }
        case .failed(let message):
            IssuesMessage(systemImage: "exclamationmark.triangle", text: message) {
                Button("Open on GitHub") { NSWorkspace.shared.open(fallbackURL) }
            }
        case .loading, nil:
            IssuesMessage(systemImage: nil, text: "Loading #\(number)\u{2026}")
        }
    }

    private func loaded(_ detail: GitHubIssueDetail) -> some View {
        let issue = detail.issue
        return LazyVStack(alignment: .leading, spacing: 12) {
            Text(issue.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 6) {
                Text(issue.state.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((issue.state == "open" ? Color.green : Color.purple).opacity(0.2)))
                Text("#\(issue.number) opened \(ShortAge.string(since: issue.createdAt)) ago by @\(issue.author?.login ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !issue.labels.isEmpty {
                FlowLayout(spacing: 4) { ForEach(issue.labels, id: \.name) { LabelPill(label: $0) } }
            }
            if !issue.assignees.isEmpty || issue.milestone != nil {
                HStack(spacing: 10) {
                    if !issue.assignees.isEmpty {
                        Label(issue.assignees.map { "@" + $0.login }.joined(separator: ", "), systemImage: "person")
                    }
                    if let milestone = issue.milestone { Label(milestone, systemImage: "flag") }
                }
                .labelStyle(SpacedLabelStyle(spacing: 3))
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { onWork(issue) } label: { Label("Work on This", systemImage: "hammer") }
                    .buttonStyle(HighlightButtonStyle())
                    .disabled(issue.state != "open")
                    .help("Send this issue to the chat's agent and make it the chat's current issue")
                Button("Open on GitHub") { NSWorkspace.shared.open(issue.url) }
            }
            .controlSize(.small)
            Divider()
            Group {
                if issue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No description.").foregroundStyle(.secondary)
                } else {
                    MarkdownText(text: issue.body)
                }
            }
            .textSelection(.enabled)
            if !detail.comments.isEmpty {
                Text("\(detail.comments.count) comment\(detail.comments.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(detail.comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Avatar(user: comment.author, size: 16)
                            Text("@\(comment.author?.login ?? "unknown")").font(.caption.weight(.medium))
                            Text(ShortAge.string(since: comment.createdAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        MarkdownText(text: comment.body).textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                }
                if detail.comments.count < issue.commentCount {
                    Button("\(issue.commentCount - detail.comments.count) more comments on GitHub") { NSWorkspace.shared.open(issue.url) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.readerStyle, style)
    }
}

// MARK: - Pieces

/// A centered message filling the panel, with an optional action under it.
private struct IssuesMessage<Actions: View>: View {
    let systemImage: String?
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
            actions
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension IssuesMessage where Actions == EmptyView {
    init(systemImage: String?, text: String) {
        self.init(systemImage: systemImage, text: text) { EmptyView() }
    }
}

/// A label in its GitHub color, tinted so it reads in light and dark mode.
struct LabelPill: View {
    let label: GitHubLabel

    var body: some View {
        let color = Color(githubHex: label.color) ?? .secondary
        Text(label.name)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.22)))
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 0.5))
    }
}

/// Up to three assignee avatars, overlapping, with the rest counted.
private struct AssigneeStack: View {
    let users: [GitHubUser]

    var body: some View {
        if !users.isEmpty {
            HStack(spacing: -5) {
                ForEach(users.prefix(3), id: \.login) { Avatar(user: $0, size: 18) }
                if users.count > 3 {
                    Text("+\(users.count - 3)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 7)
                }
            }
            .help("Assigned to " + users.map { "@" + $0.login }.joined(separator: ", "))
        }
    }
}

/// A GitHub avatar, or the login's initial while it loads or when there's none.
struct Avatar: View {
    let user: GitHubUser?
    let size: CGFloat

    private var url: URL? {
        guard let base = user?.avatarURL, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "\(Int(size * 2))")]
        return parts.url
    }

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(user?.login.prefix(1).uppercased() ?? "?")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.2))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
    }
}

extension Color {
    /// A GitHub label color: six hex digits, no "#".
    init?(githubHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
