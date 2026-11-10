import Foundation

// Project issue boards (plans/project-issues.md): an internal board per project, stored by
// Chatterbox (issues.json and IssueAttachments/ in the data folder), never in the project's repo
// or on GitHub. A project with a game catalog (catalog/games.json, as PlayCase Arcade has) groups
// its issues by game. An issue can start a work thread or be linked to one, and then follows it;
// agents file issues with the `issue` command.

/// Every project's issues. The service owns it; the Mac reaches it through the socket's "issues"
/// operation, the phone through /v1/issues, agents through `issue`.
@MainActor
final class ProjectIssueStore {
    static let shared = ProjectIssueStore()
    typealias Failure = CompanionServer.Failure

    static let types = ["bug", "feature", "polish"]
    static let priorities = ["low", "normal", "high"]
    static let statuses = ["open", "inProgress", "review", "done"]

    /// One issue as kept; its status and thread title are worked out when it's shown.
    struct Record: Codable, Hashable {
        var id: UUID
        var number: Int
        var title: String
        var notes: String?
        var game: String?
        var type: String
        var priority: String
        /// The status set by hand, for an issue not linked to a thread.
        var status: String
        var attachments: [Companion.IssueAttachment]
        var chatID: UUID?
        var createdBy: String
        var createdAt: Date
        var updatedAt: Date
    }

    private struct Saved: Codable {
        var revision: Int
        /// By project folder.
        var projects: [String: [Record]]
    }

    private(set) var projects: [String: [Record]] = [:]
    private(set) var revision = 1
    /// After a change: the service tells the app (issues.changed), with the project's folder.
    var onChange: ((String) -> Void)?
    /// Sends a thread its first message; tests replace it, so no agent starts.
    var sendFirstMessage: (ChatSession, String) -> Void = { session, text in session.send(text) }

    private let file: URL
    private let attachmentsFolder: URL
    private var model: AppModel? { CompanionServer.shared.model }

    init(root: URL = RuntimePaths.data) {
        file = root.appendingPathComponent("issues.json")
        attachmentsFolder = root.appendingPathComponent("IssueAttachments", isDirectory: true)
        guard let data = try? Data(contentsOf: file) else { return }
        if let saved = try? Companion.decoder.decode(Saved.self, from: data) {
            projects = saved.projects
            revision = saved.revision + 1
        } else {
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            RuntimeHooks.note("The issue boards couldn't be read; kept as \(aside.lastPathComponent).")
        }
    }

    // MARK: - Projects

    /// The project a session belongs to: its folder (a worktree's main folder), or its parent's
    /// for a Sidechat, sidequest or work thread.
    func projectFolder(of session: ChatSession, depth: Int = 0) -> String? {
        if let folder = session.record.worktreeOf ?? session.record.projectFolder { return folder }
        if let parent = session.record.sidechatProjectFolder { return parent }
        guard depth < 4, let parentID = session.record.sidechatOf ?? session.record.sidequestOf ?? session.record.workOf,
              let parent = model?.sessions.first(where: { $0.id == parentID }) else { return nil }
        return projectFolder(of: parent, depth: depth + 1)
    }

    /// The project's own session (not a worktree, Sidechat or work thread), newest first: where
    /// an issue's work thread starts from.
    func frontSession(of folder: String) -> ChatSession? {
        model?.sessions
            .filter { $0.record.projectFolder == folder && $0.record.worktreeOf == nil && $0.record.sidechatOf == nil
                && $0.record.workOf == nil && $0.record.sidequestOf == nil && $0.record.archivedAt == nil }
            .max { $0.record.updatedAt < $1.record.updatedAt }
    }

    /// The games in the project's catalog/games.json, in its order; none without one.
    static func games(in folder: String) -> [Companion.IssueGame] {
        let catalog = URL(fileURLWithPath: folder).appendingPathComponent("catalog/games.json")
        guard let data = try? Data(contentsOf: catalog),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let games = root["games"] as? [[String: Any]] else { return [] }
        return games.compactMap { game in
            guard let id = game["id"] as? String, !id.isEmpty else { return nil }
            let image = (game["image"] as? String).map { URL(fileURLWithPath: folder).appendingPathComponent($0).path }
                .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            return .init(id: id, title: game["title"] as? String ?? id, image: image)
        }
    }

    // MARK: - The board

    func board(for folder: String) -> Companion.IssueBoard {
        let name = frontSession(of: folder)?.projectName ?? (folder as NSString).lastPathComponent
        let issues = (projects[folder] ?? []).map(shown).sorted(by: Self.boardOrder)
        return .init(project: folder, projectName: name, games: Self.games(in: folder), issues: issues, revision: revision)
    }

    /// Open work first, then by priority, newest first.
    static func boardOrder(_ a: Companion.ProjectIssue, _ b: Companion.ProjectIssue) -> Bool {
        let rank = { (status: String) in ["inProgress": 0, "review": 1, "open": 2, "done": 3][status] ?? 4 }
        let weight = { (priority: String) in ["high": 0, "normal": 1, "low": 2][priority] ?? 1 }
        if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
        if weight(a.priority) != weight(b.priority) { return weight(a.priority) < weight(b.priority) }
        return a.createdAt > b.createdAt
    }

    /// An issue as the board shows it: linked to a thread, it follows the thread.
    private func shown(_ record: Record) -> Companion.ProjectIssue {
        var status = record.status
        var needsYou: Bool?
        var chatTitle: String?
        if let chat = record.chatID, let session = model?.sessions.first(where: { $0.id == chat }) {
            chatTitle = session.title
            status = Self.status(archived: session.record.archivedAt != nil, working: session.isWorkingOn || session.isRunning,
                                 waiting: session.isWaitingOnYou)
            if session.isWaitingOnYou && session.record.archivedAt == nil { needsYou = true }
        }
        return .init(id: record.id, number: record.number, title: record.title, notes: record.notes, game: record.game,
                     type: record.type, priority: record.priority, status: status, needsYou: needsYou,
                     attachments: record.attachments, chatID: record.chatID, chatTitle: chatTitle,
                     createdBy: record.createdBy, createdAt: record.createdAt, updatedAt: record.updatedAt)
    }

    /// A linked thread's state on the board: archived is Done, working or waiting on Shelby is
    /// In progress, finished is Review.
    static func status(archived: Bool, working: Bool, waiting: Bool) -> String {
        archived ? "done" : (working || waiting) ? "inProgress" : "review"
    }

    // MARK: - Changes

    @discardableResult
    func add(_ body: Companion.IssueAddRequest, in folder: String, by who: String) throws -> Companion.ProjectIssue {
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure(status: 400, message: "Give the issue a title.") }
        let games = Self.games(in: folder)
        let game = try Self.checkedGame(body.game, games)
        let type = try Self.checked(body.type ?? "bug", Self.types, "A type is bug, feature or polish.")
        let priority = try Self.checked(body.priority ?? "normal", Self.priorities, "A priority is low, normal or high.")
        let id = UUID()
        let attachments = try (body.attachments ?? []).map { try copyIn($0, for: id) }
        let now = Self.wholeSeconds()
        let number = ((projects[folder] ?? []).map(\.number).max() ?? 0) + 1
        let record = Record(id: id, number: number, title: String(title.prefix(300)),
                            notes: Self.clean(body.notes).map { String($0.prefix(20_000)) }, game: game, type: type, priority: priority,
                            status: "open", attachments: attachments, chatID: nil, createdBy: who, createdAt: now, updatedAt: now)
        projects[folder, default: []].append(record)
        changed(folder)
        return shown(record)
    }

    func update(_ id: UUID, in folder: String, _ body: Companion.IssueUpdateRequest) throws {
        guard let index = projects[folder]?.firstIndex(where: { $0.id == id }) else { throw Failure(status: 404, message: "That issue is gone.") }
        var record = projects[folder]![index]
        if let title = body.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Failure(status: 400, message: "An issue needs a title.") }
            record.title = String(trimmed.prefix(300))
        }
        if let notes = body.notes { record.notes = Self.clean(notes).map { String($0.prefix(20_000)) } }
        if let game = body.game { record.game = game.isEmpty ? nil : try Self.checkedGame(game, Self.games(in: folder)) }
        if let type = body.type { record.type = try Self.checked(type, Self.types, "A type is bug, feature or polish.") }
        if let priority = body.priority { record.priority = try Self.checked(priority, Self.priorities, "A priority is low, normal or high.") }
        if let status = body.status {
            record.status = try Self.checked(status, Self.statuses, "A status is open, inProgress, review or done.")
            // Moving it by hand lets go of its thread (the thread carries on).
            if record.chatID != nil, status == "open" { record.chatID = nil }
        }
        record.updatedAt = Self.wholeSeconds()
        projects[folder]![index] = record
        changed(folder)
    }

    /// More files on an issue (copied in, as when it was filed).
    func attach(_ paths: [String], to id: UUID, in folder: String) throws {
        guard let index = projects[folder]?.firstIndex(where: { $0.id == id }) else { throw Failure(status: 404, message: "That issue is gone.") }
        let added = try paths.map { try copyIn($0, for: id) }
        projects[folder]![index].attachments += added
        projects[folder]![index].updatedAt = Self.wholeSeconds()
        changed(folder)
    }

    func delete(_ id: UUID, in folder: String) throws {
        guard let index = projects[folder]?.firstIndex(where: { $0.id == id }) else { throw Failure(status: 404, message: "That issue is gone.") }
        projects[folder]!.remove(at: index)
        try? FileManager.default.removeItem(at: attachmentsFolder.appendingPathComponent(id.uuidString))
        changed(folder)
    }

    func link(_ id: UUID, in folder: String, to chatID: UUID?) throws {
        guard let index = projects[folder]?.firstIndex(where: { $0.id == id }) else { throw Failure(status: 404, message: "That issue is gone.") }
        if let chatID {
            guard let session = model?.sessions.first(where: { $0.id == chatID }), session.record.archivedAt == nil else {
                throw Failure(status: 404, message: "That thread is gone.")
            }
            guard projectFolder(of: session) == folder else { throw Failure(status: 400, message: "That thread isn't in this project.") }
        }
        projects[folder]![index].chatID = chatID
        if chatID == nil { projects[folder]![index].status = "open" }
        projects[folder]![index].updatedAt = Self.wholeSeconds()
        changed(folder)
    }

    /// Start: a work thread of the project's session, named for the issue, whose first message is
    /// the issue (with its attachments' paths); the issue follows it from then on.
    func start(_ id: UUID, in folder: String, agent: String? = nil) throws -> ChatSession {
        guard let record = projects[folder]?.first(where: { $0.id == id }) else { throw Failure(status: 404, message: "That issue is gone.") }
        guard record.chatID == nil || model?.sessions.first(where: { $0.id == record.chatID })?.record.archivedAt != nil else {
            throw Failure(status: 409, message: "That issue already has a thread.")
        }
        guard let front = frontSession(of: folder), let model else { throw Failure(status: 404, message: "This project has no open session to start from.") }
        let session: ChatSession
        do { session = try model.newWorkThread(of: front, title: "#\(record.number) \(DeskStore.title(record.title))") }
        catch { throw Failure(status: 503, message: "Could not save the new work thread.") }
        if let agent, let backend = Backend(rawValue: agent.lowercased()), backend != session.record.backend { session.setBackend(backend) }
        try link(id, in: folder, to: session.id)
        session.sendFirstOrHold(Self.brief(record, games: Self.games(in: folder))) { sendFirstMessage(session, $0) }
        front.noteWorkStarted(session)
        return session
    }

    /// What a started issue's thread is asked.
    static func brief(_ record: Record, games: [Companion.IssueGame]) -> String {
        let game = record.game.flatMap { id in games.first { $0.id == id }?.title ?? id } ?? "General"
        var text = "Issue #\(record.number) (\(game), \(record.type), \(record.priority) priority): \(record.title)"
        if let notes = record.notes { text += "\n\n\(notes)" }
        if !record.attachments.isEmpty {
            text += "\n\nAttached:\n" + record.attachments.map { "- \($0.path)" }.joined(separator: "\n")
        }
        text += "\n\nWork on this issue in this project. When it's done, say what changed; the issue moves to Review on the board."
        return text
    }

    // MARK: - The service socket's "issues" operation

    /// `action` list (the default), add, update, attach, delete, link, unlink or start, on the project
    /// of `chatID`'s session (or `project`, a folder). Agents may list and add; the app does all.
    func operation(_ body: JSON, agent: String?) throws -> JSON {
        let action = body["action"]?.string ?? "list"
        guard agent == nil || ["list", "add"].contains(action) else { throw RuntimeFailure("permission_denied") }
        let folder = try project(of: body)
        switch action {
        case "list":
            return try .value(board(for: folder))
        case "add":
            guard let request = try? body.decode(Companion.IssueAddRequest.self) else { throw Failure(status: 400, message: "Give the issue a title.") }
            return try .value(add(request, in: folder, by: agent ?? "you"))
        case "update":
            let request = (try? body.decode(Companion.IssueUpdateRequest.self)) ?? .init()
            try update(try Self.issueID(body), in: folder, request)
        case "attach":
            try attach(body["attachments"]?.array?.compactMap(\.string) ?? [], to: try Self.issueID(body), in: folder)
        case "delete":
            try delete(try Self.issueID(body), in: folder)
        case "link":
            guard let thread = body["thread"]?.string.flatMap(UUID.init(uuidString:)) else { throw Failure(status: 400, message: "Say which thread.") }
            try link(try Self.issueID(body), in: folder, to: thread)
        case "unlink":
            try link(try Self.issueID(body), in: folder, to: nil)
        case "start":
            let session = try start(try Self.issueID(body), in: folder, agent: body["agent"]?.string)
            guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
            return try .value(CompanionMapper.detail(session, model: model))
        default:
            throw RuntimeFailure("unsupported_operation")
        }
        return try .value(board(for: folder))
    }

    /// The project: `project` (its folder), or the one `chatID`'s session belongs to.
    func project(of body: JSON) throws -> String {
        if let folder = body["project"]?.string, !folder.isEmpty { return folder }
        guard let chat = body["chatID"]?.string.flatMap(UUID.init(uuidString:)),
              let session = model?.sessions.first(where: { $0.id == chat }) else { throw Failure(status: 404, message: "That session is gone.") }
        guard let folder = projectFolder(of: session) else { throw Failure(status: 400, message: "That session isn't in a project.") }
        return folder
    }

    // MARK: - Helpers

    /// Copies a file into the issue's own folder, so the issue keeps it whatever happens to the original.
    private func copyIn(_ path: String, for id: UUID) throws -> Companion.IssueAttachment {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure(status: 400, message: "No file at \(path).") }
        let folder = attachmentsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) \(n).\(source.pathExtension)"); n += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return .init(name: target.lastPathComponent, path: target.path, mediaType: Self.mediaType(target.pathExtension))
    }

    static func mediaType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "mov": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }

    private static func checked(_ value: String, _ allowed: [String], _ message: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard let match = allowed.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { throw Failure(status: 400, message: message) }
        return match
    }

    /// A game's id or title (any case); nil or "general" is General.
    private static func checkedGame(_ value: String?, _ games: [Companion.IssueGame]) throws -> String? {
        guard let value = clean(value), value.lowercased() != "general" else { return nil }
        if let game = games.first(where: { $0.id.caseInsensitiveCompare(value) == .orderedSame || $0.title.caseInsensitiveCompare(value) == .orderedSame }) {
            return game.id
        }
        throw Failure(status: 400, message: games.isEmpty ? "This project has no game catalog: leave the game out."
                      : "No game \u{201C}\(value)\u{201D} in this project's catalog.")
    }

    private static func issueID(_ body: JSON) throws -> UUID {
        guard let id = body["id"]?.string.flatMap(UUID.init(uuidString:)) else { throw Failure(status: 400, message: "Say which issue.") }
        return id
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func wholeSeconds() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    /// A thread changed (its state shows on boards): tells the app, once a burst settles.
    private var refreshScheduled = false
    func sessionsChanged() {
        guard !refreshScheduled, projects.values.contains(where: { $0.contains { $0.chatID != nil } }) else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                for (folder, records) in self.projects where records.contains(where: { $0.chatID != nil }) { self.onChange?(folder) }
            }
        }
    }

    private func changed(_ folder: String) {
        revision += 1
        save()
        onChange?(folder)
    }

    private func save() {
        guard let data = try? Companion.encoder.encode(Saved(revision: revision, projects: projects)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
