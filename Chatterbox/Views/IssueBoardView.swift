import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A project's issue board on the Mac (plans/project-issues.md, I2): the center pane, as Archived
// is. Issues grouped by game (the project's catalog; General otherwise), each game's issues in
// Open · In progress · Review · Done. New Issue and a card's sheet edit them; Start begins a work
// thread, Link and Unlink tie one; it follows the service's "issues.changed".

/// The board the center pane shows, and the service calls behind it.
@MainActor
@Observable
final class IssueBoardModel {
    static let shared = IssueBoardModel()

    private(set) var board: Companion.IssueBoard?
    private(set) var problem: String?
    private(set) var busy = false
    private(set) var folder: String?
    /// For tests: the service's answer to an "issues" body.
    @ObservationIgnored var transport: ((JSON) async throws -> JSON)?

    func show(_ folder: String) {
        if self.folder != folder { board = nil }
        self.folder = folder
        Task { await refresh() }
    }

    func refresh() async {
        guard let folder else { return }
        do { board = try await send(["action": "list", "project": .string(folder)]).decode(Companion.IssueBoard.self); problem = nil }
        catch { problem = error.localizedDescription }
    }

    /// add, update, delete, link, unlink: the service answers with the board (or the new issue).
    @discardableResult
    func act(_ action: String, _ fields: [String: JSON] = [:]) async -> Bool {
        guard let folder else { return false }
        busy = true
        defer { busy = false }
        var body = fields
        body["action"] = .string(action); body["project"] = .string(folder)
        do {
            let answer = try await send(.object(body))
            if let board = try? answer.decode(Companion.IssueBoard.self) { self.board = board } else { await refresh() }
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Start: the issue's work thread; answers its id, to open it.
    func start(_ issue: Companion.ProjectIssue) async -> UUID? {
        guard let folder else { return nil }
        busy = true
        defer { busy = false }
        do {
            let detail = try await send(["action": "start", "project": .string(folder), "id": .string(issue.id.uuidString)]).decode(Companion.ChatDetail.self)
            await refresh()
            problem = nil
            return detail.summary.id
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func runtimeEvent(_ event: RuntimeEvent) {
        guard event.kind == "issues.changed" || event.kind == "connected", folder != nil else { return }
        if event.kind == "connected" || event.payload?["project"]?.string == folder { Task { await refresh() } }
    }

    private func send(_ body: JSON) async throws -> JSON {
        if let transport { return try await transport(body) }
        if RuntimeClient.usesDaemon { return try await RuntimeClient.shared.request("issues", body: body, timeout: .seconds(20)) }
        return try ProjectIssueStore.shared.operation(body, agent: nil)
    }
}

enum IssueText {
    static let statuses: [(id: String, title: String)] = [("open", "Open"), ("inProgress", "In progress"), ("review", "Review"), ("done", "Done")]
    static func status(_ id: String) -> String { statuses.first { $0.id == id }?.title ?? id }
    static func type(_ id: String) -> String { ["bug": "Bug", "feature": "Feature", "polish": "Polish"][id] ?? id }
    static func priority(_ id: String) -> String { ["low": "Low", "normal": "Normal", "high": "High"][id] ?? id }
    static func typeIcon(_ id: String) -> String { ["bug": "ladybug", "feature": "sparkles", "polish": "wand.and.stars"][id] ?? "circle" }
    static func typeColor(_ id: String) -> Color { ["bug": .red, "feature": .blue, "polish": .purple][id] ?? .secondary }
}

/// The board itself.
struct IssueBoardView: View {
    @Environment(AppModel.self) private var app
    let folder: String
    private var board: IssueBoardModel { .shared }
    @State private var gameFilter: String = "all"
    @State private var showDone = false
    @State private var editing: IssueSheetTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let problem = board.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).padding(.horizontal, 20).padding(.top, 10)
            }
            if let current = board.board {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        let groups = groups(current)
                        if groups.isEmpty {
                            ContentUnavailableView("No issues yet", systemImage: "checklist",
                                                   description: Text("New Issue files one; agents in this project can file them with `issue add`."))
                                .padding(.top, 40)
                        }
                        ForEach(groups, id: \.id) { group in gameSection(group, current) }
                    }
                    .padding(20)
                }
                .accessibilityIdentifier("issue-board")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { board.show(folder) }
        .onChange(of: folder) { _, new in board.show(new) }
        .sheet(item: $editing) { target in
            IssueSheet(target: target, games: board.board?.games ?? [], folder: folder) { editing = nil }
                .environment(app)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(board.board?.projectName ?? (folder as NSString).lastPathComponent) Issues").font(.title2.weight(.semibold))
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let games = board.board?.games, !games.isEmpty {
                Picker("Game", selection: $gameFilter) {
                    Text("All games").tag("all")
                    Text("General").tag("general")
                    Divider()
                    ForEach(games) { Text($0.title).tag($0.id) }
                }
                .frame(width: 180)
                .accessibilityIdentifier("issue-game-filter")
            }
            Toggle("Show Done", isOn: $showDone).toggleStyle(.checkbox)
            Button { editing = .new } label: { Label("New Issue", systemImage: "plus") }
                .buttonStyle(.accent)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("issue-new")
            Button { app.issueBoardFolder = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close the board")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var summary: String {
        guard let issues = board.board?.issues else { return "Loading…" }
        let open = issues.filter { $0.status != "done" }.count
        let working = issues.filter { $0.status == "inProgress" }.count
        return "\(open) open\(working > 0 ? " · \(working) in progress" : "") · \(issues.count - open) done"
    }

    private struct Group { var id: String; var title: String; var image: String?; var issues: [Companion.ProjectIssue] }

    /// Games with issues, in catalog order, then General; the filter narrows them.
    private func groups(_ current: Companion.IssueBoard) -> [Group] {
        let shown = current.issues.filter { showDone || $0.status != "done" }
        var result: [Group] = current.games.compactMap { game in
            let issues = shown.filter { $0.game == game.id }
            return issues.isEmpty ? nil : Group(id: game.id, title: game.title, image: game.image, issues: issues)
        }
        let general = shown.filter { issue in issue.game == nil || !current.games.contains { $0.id == issue.game } }
        if !general.isEmpty { result.append(Group(id: "general", title: "General", image: nil, issues: general)) }
        return gameFilter == "all" ? result : result.filter { $0.id == gameFilter }
    }

    private func gameSection(_ group: Group, _ current: Companion.IssueBoard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let image = group.image, let picture = NSImage(contentsOfFile: image) {
                    Image(nsImage: picture).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: group.id == "general" ? "tray" : "gamecontroller").frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                Text(group.title).font(.headline)
                Text("\(group.issues.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { editing = .new(game: group.id == "general" ? nil : group.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New issue for \(group.title)")
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(IssueText.statuses.filter { showDone || $0.id != "done" }, id: \.id) { status in
                    let issues = group.issues.filter { $0.status == status.id }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(status.title) \(issues.isEmpty ? "" : "\(issues.count)")").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(issues) { issue in
                            IssueCard(issue: issue) { editing = .issue(issue) }
                        }
                        if issues.isEmpty { Color.clear.frame(height: 4) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("issue-game-\(group.id)")
    }
}

/// One issue on the board.
struct IssueCard: View {
    let issue: Companion.ProjectIssue
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: IssueText.typeIcon(issue.type)).foregroundStyle(IssueText.typeColor(issue.type))
                    Text("#\(issue.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if issue.priority == "high" {
                        Text("High").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if issue.needsYou == true { Circle().fill(Color.attention).frame(width: 8, height: 8).help("Its thread needs you") }
                }
                Text(issue.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading).lineLimit(3)
                if let image = issue.attachments.first(where: { $0.mediaType.hasPrefix("image/") }), let picture = NSImage(contentsOfFile: image.path) {
                    Image(nsImage: picture).resizable().scaledToFill().frame(height: 70).frame(maxWidth: .infinity).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let thread = issue.chatTitle {
                    Label(thread, systemImage: "bubble.left.and.text.bubble.right").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(hovered ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(issue.needsYou == true ? Color.attention.opacity(0.8) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("#\(issue.number) \(issue.title), \(IssueText.type(issue.type)), \(IssueText.status(issue.status))")
        .accessibilityIdentifier("issue-\(issue.number)")
    }
}

enum IssueSheetTarget: Identifiable {
    case new(game: String?)
    case issue(Companion.ProjectIssue)
    static var new: IssueSheetTarget { .new(game: nil) }
    var id: String { if case .issue(let issue) = self { return issue.id.uuidString }; return "new" }
}

/// New Issue, or an issue's details: edit its fields, attach files (drop or choose), and Start,
/// Open, Link or Unlink its thread; Delete.
struct IssueSheet: View {
    @Environment(AppModel.self) private var app
    let target: IssueSheetTarget
    let games: [Companion.IssueGame]
    let folder: String
    let close: () -> Void
    private var board: IssueBoardModel { .shared }

    @State private var title = ""
    @State private var notes = ""
    @State private var game = "general"
    @State private var type = "bug"
    @State private var priority = "normal"
    @State private var status = "open"
    @State private var newFiles: [URL] = []
    @State private var linking = false
    @State private var confirmingDelete = false

    private var issue: Companion.ProjectIssue? {
        if case .issue(let original) = target { return board.board?.issues.first { $0.id == original.id } ?? original }
        return nil
    }
    /// The project's open threads, for Link.
    private var threads: [ChatSession] {
        app.sessions.filter { session in
            session.record.archivedAt == nil && session.record.sidequestOf == nil
                && app.projectFolder(of: session) == folder
        }
        .sorted { $0.record.updatedAt > $1.record.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(issue.map { "Issue #\($0.number)" } ?? "New Issue").font(.title2.weight(.semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(.title3)
                .accessibilityIdentifier("issue-title")
            HStack(spacing: 12) {
                if !games.isEmpty {
                    Picker("Game", selection: $game) {
                        Text("General").tag("general")
                        Divider()
                        ForEach(games) { Text($0.title).tag($0.id) }
                    }
                    .frame(maxWidth: 220)
                }
                Picker("Type", selection: $type) { ForEach(ProjectIssueStore.types, id: \.self) { Text(IssueText.type($0)).tag($0) } }
                    .frame(maxWidth: 160)
                Picker("Priority", selection: $priority) { ForEach(ProjectIssueStore.priorities, id: \.self) { Text(IssueText.priority($0)).tag($0) } }
                    .frame(maxWidth: 170)
                if let issue, issue.chatID == nil {
                    Picker("Status", selection: $status) { ForEach(IssueText.statuses, id: \.id) { Text($0.title).tag($0.id) } }
                        .frame(maxWidth: 190)
                }
            }
            Text("Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $notes).font(.body).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            attachments
            if let issue { threadRow(issue) }
            if let problem = board.problem { Text(problem).font(.callout).foregroundStyle(.orange) }
            HStack {
                if issue != nil {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(issue == nil ? "File Issue" : "Save") { Task { await save() } }
                    .buttonStyle(.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || board.busy)
                    .accessibilityIdentifier("issue-save")
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear(perform: fill)
        .confirmationDialog("Delete issue #\(issue?.number ?? 0)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { if let issue, await board.act("delete", ["id": .string(issue.id.uuidString)]) { close() } }
            }
        } message: { Text("Its attachments go too. Its thread, if any, carries on.") }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { choose() } label: { Label("Add…", systemImage: "paperclip") }.buttonStyle(.borderless)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(issue?.attachments ?? [], id: \.path) { file in thumb(URL(fileURLWithPath: file.path), kept: true) }
                    ForEach(newFiles, id: \.self) { url in thumb(url, kept: false) }
                    if (issue?.attachments ?? []).isEmpty && newFiles.isEmpty {
                        Text("Drop screenshots or recordings here").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
            .frame(minHeight: 70)
            .padding(6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .dropDestination(for: URL.self) { urls, _ in newFiles += urls.filter(\.isFileURL); return true }
            if issue != nil && !newFiles.isEmpty {
                Text("Added files are attached when you save.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func thumb(_ url: URL, kept: Bool) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            VStack(spacing: 4) {
                if let picture = NSImage(contentsOf: url), ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(url.pathExtension.lowercased()) {
                    Image(nsImage: picture).resizable().scaledToFill().frame(width: 80, height: 54).clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "doc").font(.title2).frame(width: 80, height: 54)
                }
                Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 80)
            }
            .opacity(kept ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .help(kept ? "Open \(url.lastPathComponent)" : "To attach: \(url.lastPathComponent)")
    }

    @ViewBuilder private func threadRow(_ issue: Companion.ProjectIssue) -> some View {
        HStack(spacing: 10) {
            if let chat = issue.chatID {
                Label(issue.chatTitle ?? "Its thread", systemImage: "bubble.left.and.text.bubble.right").lineLimit(1)
                Text(IssueText.status(issue.status)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Thread") { app.selectedID = chat; close() }
                Button("Unlink") { Task { await board.act("unlink", ["id": .string(issue.id.uuidString)]) } }
            } else {
                Text("No thread yet").foregroundStyle(.secondary)
                Spacer()
                Button("Link…") { linking = true }
                    .popover(isPresented: $linking) { linkList(issue) }
                Button { Task { if let chat = await board.start(issue) { app.selectedID = chat; close() } } } label: {
                    Label("Start Thread", systemImage: "play.fill")
                }
                .help("A work thread in this project, given the issue (and its attachments) to work on")
                .accessibilityIdentifier("issue-start")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func linkList(_ issue: Companion.ProjectIssue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Link a thread in this project").font(.headline).padding(.bottom, 6)
            if threads.isEmpty { Text("No open threads.").foregroundStyle(.secondary) }
            ForEach(threads.prefix(12), id: \.id) { session in
                Button {
                    linking = false
                    Task { await board.act("link", ["id": .string(issue.id.uuidString), "thread": .string(session.id.uuidString)]) }
                } label: { Text(session.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func fill() {
        if let issue {
            title = issue.title; notes = issue.notes ?? ""; game = issue.game ?? "general"
            type = issue.type; priority = issue.priority; status = issue.status
        } else if case .new(let preset) = target {
            game = preset ?? "general"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { newFiles += panel.urls }
    }

    private func save() async {
        let files = JSON.array(newFiles.map { .string($0.path) })
        if let issue {
            var fields: [String: JSON] = ["id": .string(issue.id.uuidString), "title": .string(title), "notes": .string(notes),
                                          "game": .string(game == "general" ? "" : game), "type": .string(type), "priority": .string(priority)]
            if issue.chatID == nil { fields["status"] = .string(status) }
            guard await board.act("update", fields) else { return }
            if !newFiles.isEmpty, !(await board.act("attach", ["id": .string(issue.id.uuidString), "attachments": files])) { return }
            close()
        } else {
            var fields: [String: JSON] = ["title": .string(title), "type": .string(type), "priority": .string(priority), "attachments": files]
            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["notes"] = .string(notes) }
            if game != "general" { fields["game"] = .string(game) }
            // The service files it on the project of a session there (or the project's folder).
            if await board.act("add", fields) { close() }
        }
    }
}

extension AppModel {
    /// The project a session belongs to (as ProjectIssueStore works it out in the service): its
    /// folder, a worktree's main folder, or its parent's for a Sidechat, sidequest or work thread.
    func projectFolder(of session: ChatSession, depth: Int = 0) -> String? {
        if let folder = session.record.worktreeOf ?? session.record.projectFolder { return folder }
        if let parent = session.record.sidechatProjectFolder { return parent }
        guard depth < 4, let parentID = session.record.sidechatOf ?? session.record.sidequestOf ?? session.record.workOf,
              let parent = sessions.first(where: { $0.id == parentID }) else { return nil }
        return projectFolder(of: parent, depth: depth + 1)
    }
}

extension AppModel {
    /// Make Project from the Mac: the service turns the chat into a project working in `folder`
    /// (ConversationRuntime.promote), keeping its history.
    func promote(_ session: ChatSession, toProjectAt folder: String) async throws {
        let request = Companion.PromotionRequest(kind: .project, folder: folder)
        guard RuntimeClient.usesDaemon else { throw RuntimeFailure("Making a project needs Chatterbox's background service.") }
        _ = try await RuntimeClient.shared.request("promote", body: ["chatID": .string(session.id.uuidString), "request": try JSON.value(request)],
                                                   timeout: .seconds(20))
    }
}
