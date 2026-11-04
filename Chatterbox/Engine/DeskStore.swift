import Foundation

// The Desk: incoming requests (desk.json), place proposals, and what needs Shelby. plans/front-desk.md

/// The Desk: what needs Shelby, work waiting to be placed, and what's working. It never does
/// work itself: starting a request opens a session in its Studio or project, so work stays in
/// its compartment. The service owns it; the phone and Claude's connector reach it through
/// the companion API (/v1/desk), the Mac app through the service socket (operation "desk").
///
/// Only the requests and what was silenced are kept (desk.json in the data folder). What
/// needs Shelby and what's working come from the sessions each time they're asked for.
@MainActor
final class DeskStore {
    static let shared = DeskStore()
    typealias Failure = CompanionServer.Failure

    /// Requests waiting to be placed and started, newest first.
    private(set) var requests: [Companion.DeskRequest] = []
    /// Waiting things Shelby silenced: off the Desk, still waiting in their sessions. Each goes
    /// once it no longer waits.
    private(set) var silences: [Silence] = []
    /// Goes up whenever anything the Desk shows changes, including what sessions are doing.
    private(set) var revision = 1
    /// After the Desk changed, with what it shows now: the service tells the app (desk.changed).
    var onChange: ((Companion.Desk) -> Void)?
    /// Sends a started request's first message. Tests replace it, so no agent starts.
    var sendFirstMessage: (ChatSession, String) -> Void = { session, text in session.send(text) }

    /// The most requests kept; the oldest go first.
    static let limit = 200
    /// The most silences kept; the oldest go first.
    static let silenceLimit = 500
    /// How long a reply that ends on a question counts as waiting on Shelby.
    static let replyWindow: TimeInterval = 48 * 3600
    static let loose = Companion.DeskPlace(kind: "loose", id: nil, name: "Loose session",
                                           detail: "A session of its own, in no Studio or project.")

    /// One waiting thing silenced. An approval, plan or questions is its own item; a reply is
    /// the reply itself and the question it ends on, so a newer reply that asks shows again.
    struct Silence: Codable, Hashable {
        var chatID: UUID
        /// The approval's, plan's or questions' item, or the reply's.
        var itemID: UUID
        var kind: String
        /// What it asked, as the Desk said it.
        var text: String
        var silencedAt: Date
    }

    private struct Saved: Codable {
        var revision: Int
        var requests: [Companion.DeskRequest]
        /// Nil in a desk.json from before silencing.
        var silences: [Silence]? = nil
    }
    private struct Content: Equatable {
        var needsYou: [Companion.DeskWaiting]
        var incoming: [Companion.DeskRequest]
        var working: [Companion.DeskWorking]
        var silenced: [Companion.DeskWaiting]
    }
    /// Something a session waits on Shelby for.
    private struct Waiting {
        var date: Date
        var item: Companion.DeskWaiting
        /// What silences it: the request's own item, or the reply's.
        var itemID: UUID

        func silenced(by silence: Silence) -> Bool {
            silence.chatID == item.chatID && silence.itemID == itemID && (item.kind != "reply" || silence.text == item.text)
        }
    }

    private let file: URL
    /// What the Desk last showed, to notice changes.
    private var shown: Content?
    private var refreshScheduled = false
    private var saveScheduled = false
    /// Where sessions live; the companion server's, wherever it runs (the service, or the app
    /// running its own conversations).
    private var model: AppModel? { CompanionServer.shared.model }

    init(file: URL = RuntimePaths.data.appendingPathComponent("desk.json")) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        if let saved = try? Companion.decoder.decode(Saved.self, from: data) {
            requests = saved.requests.sorted { $0.createdAt > $1.createdAt }
            silences = saved.silences ?? []
            // Sessions may have changed while the service was down.
            revision = saved.revision + 1
        } else {
            // Kept aside rather than overwritten by the next save.
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            RuntimeHooks.note("The Desk's saved requests couldn't be read; kept as \(aside.lastPathComponent).")
        }
    }

    // MARK: - What it shows

    /// The Desk now. A change since it was last shown gets a new revision (and is announced).
    func snapshot() -> Companion.Desk {
        let content = current()
        if let shown, shown != content {
            revision += 1
            self.shown = content
            let desk = Self.desk(content, revision: revision)
            scheduleSave()
            onChange?(desk)
            return desk
        }
        shown = content
        return Self.desk(content, revision: revision)
    }

    /// Sessions changed (a reply started or ended, a question came or was answered, one was
    /// renamed or archived): looks once a burst settles, and announces the Desk if that changed it.
    func sessionsChanged() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                _ = self.snapshot()
            }
        }
    }

    /// Where work can go: every open Studio and project, then a loose session.
    func places() -> [Companion.DeskPlace] {
        choices().map(Self.place) + [Self.loose]
    }

    // MARK: - Changing it

    /// Puts a request on the Desk, proposing the place it names, or else the one place that
    /// clearly fits from each Studio's instructions and project's brief (none when unsure).
    @discardableResult
    func add(_ body: Companion.DeskAddRequest, source fallback: String = "you") throws -> Companion.DeskRequest {
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure(status: 400, message: "Say what needs doing.") }
        guard text.count <= 100_000 else { throw Failure(status: 400, message: "That's too long for the Desk.") }
        let note = Self.clean(body.note).map { String($0.prefix(4_000)) }
        let source = Self.clean(body.source).map { String($0.lowercased().prefix(32)) } ?? fallback
        let choices = choices()
        var proposed: Companion.DeskPlace?
        if let name = Self.clean(body.place) {
            if ["loose", "loose session", "none", "no place"].contains(name.lowercased()) {
                proposed = Self.loose
            } else if let match = PlaceSuggestion.named(name, among: choices) {
                proposed = Self.place(match)
            } else {
                throw Failure(status: 404, message: "No single Studio or project is called \(name).")
            }
        } else {
            proposed = PlaceSuggestion.best(for: text + (note.map { "\n" + $0 } ?? ""), among: choices).map(Self.place)
        }
        // Whole seconds, as desk.json keeps it.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let request = Companion.DeskRequest(id: UUID(), text: text, source: source, createdAt: now, proposed: proposed, note: note)
        requests.insert(request, at: 0)
        if requests.count > Self.limit { requests.removeLast(requests.count - Self.limit) }
        changed()
        return request
    }

    /// Silence: takes one waiting thing off the Desk, on every device, without answering it
    /// (an approval stays pending in its session). `id` is the DeskWaiting's: any of a
    /// session's approvals, plans or questions, or its id for the reply it waits on, whose
    /// `text` (when given) must still be what that reply asks. Something no longer waiting, or a
    /// reply since replaced, is left alone: the Desk shows what waits now. True when it's silenced.
    @discardableResult
    func silence(_ body: Companion.DeskSilenceRequest) -> Bool {
        guard let session = model?.sessions.first(where: { $0.id == body.chatID }), session.record.archivedAt == nil,
              let found = waiting(in: session, now: Date()).first(where: { candidate in
                  candidate.item.id == body.id && (candidate.item.kind != "reply" || body.text == nil || body.text == candidate.item.text)
              }) else { return false }
        guard !silences.contains(where: found.silenced) else { return true }
        // Whole seconds, as desk.json keeps it.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        silences.append(Silence(chatID: session.id, itemID: found.itemID, kind: found.item.kind, text: found.item.text, silencedAt: now))
        if silences.count > Self.silenceLimit { silences.removeFirst(silences.count - Self.silenceLimit) }
        changed()
        return true
    }

    func ignore(_ id: UUID) throws {
        guard requests.contains(where: { $0.id == id }) else { throw Failure(status: 404, message: "That request is gone.") }
        requests.removeAll { $0.id == id }
        changed()
    }

    /// Starts a request where it was proposed, or in `body.place`: a new chat in a Studio, a new
    /// Sidechat of a project's session, or a loose session. It's named from the request, which
    /// becomes its first message (with the note, labelled), and leaves the Desk.
    func start(_ id: UUID, _ body: Companion.DeskStartRequest = .init()) throws -> ChatSession {
        guard let request = requests.first(where: { $0.id == id }) else { throw Failure(status: 404, message: "That request is gone.") }
        guard let place = body.place ?? request.proposed else {
            throw Failure(status: 400, message: "Choose where this goes: a Studio, a project, or a loose session.")
        }
        var backend: Backend?
        if let agent = Self.clean(body.agent) {
            guard let chosen = Backend(rawValue: agent.lowercased()) else { throw Failure(status: 400, message: "The agent is claude or codex.") }
            backend = chosen
        }
        let server = CompanionServer.shared
        let session: ChatSession
        switch place.kind {
        case "studio":
            guard let studio = place.id else { throw Failure(status: 404, message: "That Studio is gone.") }
            session = try server.newSession(project: nil, studio: studio, backend: backend)
        case "project":
            guard let project = place.id, model?.sessions.first(where: { $0.id == project })?.record.projectFolder != nil else {
                throw Failure(status: 404, message: "That project's session is gone.")
            }
            // A Sidechat starts on its project's agent; another one is switched to before anything's sent.
            session = try server.newSession(project: project, studio: nil, backend: nil)
            if let backend, backend != session.record.backend { session.setBackend(backend) }
        case "loose":
            session = try server.newSession(project: nil, studio: nil, backend: backend)
        default:
            throw Failure(status: 400, message: "A place is a studio, a project, or loose.")
        }
        session.setTitle(Self.title(request.text))
        // Off the Desk (and saved so) before it's sent, so a request is never started twice.
        requests.removeAll { $0.id == id }
        save()
        sendFirstMessage(session, Self.message(request))
        changed()
        return session
    }

    /// The service socket's "desk" operation (the Mac app): `action` get, add, start, ignore,
    /// silence or places, with the companion API's bodies, plus `id` for start and ignore.
    /// Replies as the companion API does: the Desk, a started session's ChatDetail, or the
    /// places. An agent's request is from Claude (or Codex), never from Shelby.
    func operation(_ body: JSON, agent: Bool) throws -> JSON {
        switch body["action"]?.string ?? "get" {
        case "get":
            return try .value(snapshot())
        case "places":
            return try .value(places())
        case "add":
            guard var request = try? body.decode(Companion.DeskAddRequest.self) else { throw Failure(status: 400, message: "Say what needs doing.") }
            if agent { request.source = ["claude", "codex"].contains(request.source ?? "") ? request.source : "claude" }
            try add(request)
            return try .value(snapshot())
        case "ignore":
            try ignore(try Self.requestID(body))
            return try .value(snapshot())
        case "silence":
            guard let request = try? body.decode(Companion.DeskSilenceRequest.self) else { throw Failure(status: 400, message: "Say what to silence.") }
            silence(request)
            return try .value(snapshot())
        case "start":
            let id = try Self.requestID(body)
            guard let start = try? body.decode(Companion.DeskStartRequest.self) else { throw Failure(status: 400, message: "Bad place.") }
            let session = try self.start(id, start)
            guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
            return try .value(CompanionMapper.detail(session, model: model))
        default:
            throw RuntimeFailure("unsupported_operation")
        }
    }

    // MARK: - Building it

    /// What the Desk shows now. Silences that no longer match anything waiting go.
    private func current() -> Content {
        guard let model else { return Content(needsYou: [], incoming: requests, working: [], silenced: []) }
        var needs: [(date: Date, item: Companion.DeskWaiting)] = []
        var silenced: [(date: Date, item: Companion.DeskWaiting)] = []
        var working: [(date: Date, item: Companion.DeskWorking)] = []
        var live = Set<Silence>()
        let now = Date()
        for session in model.sessions where session.record.archivedAt == nil {
            let all = waiting(in: session, now: now)
            var shown: Waiting?
            for waiting in all {
                if let silence = silences.first(where: waiting.silenced) {
                    live.insert(silence)
                    silenced.append((waiting.date, waiting.item))
                } else if shown == nil {
                    shown = waiting
                }
            }
            if let shown {
                needs.append((shown.date, shown.item))
            } else if all.isEmpty, session.isRunning {
                // One waiting on something silenced is waiting, not working.
                let name = CompanionMapper.heading(session)
                working.append((session.record.turnStartedAt ?? session.record.updatedAt,
                                .init(id: session.id, title: name.title, place: placeName(session), subtitle: name.subtitle)))
            }
        }
        if live.count < silences.count { silences.removeAll { !live.contains($0) } }
        func newestFirst<T: Identifiable>(_ a: (date: Date, item: T), _ b: (date: Date, item: T)) -> Bool where T.ID == UUID {
            a.date != b.date ? a.date > b.date : a.item.id.uuidString < b.item.id.uuidString
        }
        return Content(needsYou: needs.sorted(by: newestFirst).map(\.item), incoming: requests,
                       working: working.sorted(by: newestFirst).map(\.item), silenced: silenced.sorted(by: newestFirst).map(\.item))
    }

    /// What a session waits on Shelby for, oldest first: its approvals, plans and questions,
    /// or else a recent reply that ends on a question. The Desk shows the first not silenced.
    private func waiting(in session: ChatSession, now: Date) -> [Waiting] {
        let place = placeName(session)
        let name = CompanionMapper.heading(session)
        func item(id: UUID, kind: String, text: String, questions: [Companion.Question]? = nil) -> Companion.DeskWaiting {
            .init(id: id, chatID: session.id, title: name.title, place: place, kind: kind, text: text, questions: questions, subtitle: name.subtitle)
        }
        let pending = session.pendingRequests
        if !pending.isEmpty {
            return pending.map { request in
                let date = request.timestamp ?? session.record.updatedAt
                if request.kind == .questions {
                    let questions = (request.questions ?? []).map { q in
                        Companion.Question(id: q.id, header: q.header, question: q.question,
                                           options: q.options.map { .init(label: $0.label, detail: $0.detail) },
                                           multiSelect: q.multiSelect, isSecret: q.isSecret)
                    }
                    var text = questions.first?.question ?? request.text
                    if questions.count > 1 { text += " (and \(questions.count - 1) more)" }
                    return Waiting(date: date, item: item(id: request.id, kind: "questions", text: Self.short(text), questions: questions), itemID: request.id)
                }
                return Waiting(date: date, item: item(id: request.id, kind: request.approvalStyle == .plan ? "plan" : "approval", text: Self.short(request.text)),
                               itemID: request.id)
            }
        }
        // A question in a reply: the last thing said is the agent's, asking. Sidequests and
        // automation runs report to their session, not to Shelby.
        guard !session.isRunning, session.record.sidequestOf == nil, session.record.automationID == nil,
              let last = session.items.last(where: { $0.kind == .user || ($0.kind == .assistant && $0.phase == .final) }),
              last.kind == .assistant else { return [] }
        let date = last.timestamp ?? session.record.updatedAt
        guard now.timeIntervalSince(date) < Self.replyWindow, let question = Self.question(in: last.text) else { return [] }
        return [Waiting(date: date, item: item(id: session.id, kind: "reply", text: question), itemID: last.id)]
    }

    /// A session's Studio or project, or its parent's for a Sidechat or sidequest.
    private func placeName(_ session: ChatSession, depth: Int = 0) -> String? {
        guard let model else { return nil }
        if let id = session.record.studioID, let studio = model.studio(id) { return studio.name }
        if session.record.projectFolder != nil { return session.projectName }
        if depth < 3, let parentID = session.record.sidechatOf ?? session.record.sidequestOf,
           let parent = model.sessions.first(where: { $0.id == parentID }) {
            return placeName(parent, depth: depth + 1)
        }
        return session.record.sidechatProjectFolder.map { ($0 as NSString).lastPathComponent }
    }

    /// Open Studios, then projects' own sessions (not their Sidechats or worktrees), by name.
    private func choices() -> [PlaceSuggestion.Place] {
        guard let model else { return [] }
        func byName(_ a: PlaceSuggestion.Place, _ b: PlaceSuggestion.Place) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let studios = model.activeStudios.map {
            PlaceSuggestion.Place(id: $0.id, name: $0.name, instructions: $0.trimmedInstructions, kind: .studio)
        }
        let projects = model.sidebarProjects
            .filter { $0.record.sidechatOf == nil && $0.record.sidequestOf == nil && $0.record.worktreeOf == nil }
            .map { PlaceSuggestion.Place(id: $0.id, name: $0.projectName,
                                         instructions: $0.record.brief?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", kind: .project) }
        return studios.sorted(by: byName) + projects.sorted(by: byName)
    }

    private static func place(_ place: PlaceSuggestion.Place) -> Companion.DeskPlace {
        .init(kind: place.kind.rawValue, id: place.id, name: place.name,
              detail: place.instructions.isEmpty ? nil : short(place.instructions, limit: 500))
    }

    private static func desk(_ content: Content, revision: Int) -> Companion.Desk {
        .init(revision: revision, needsYou: content.needsYou, incoming: content.incoming, working: content.working, silenced: content.silenced)
    }

    // MARK: - Text

    /// A new session's name: the request's first line, short.
    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
        guard line.count > 48 else { return line }
        let cut = line.prefix(47)
        let end = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return end.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "\u{2026}"
    }

    /// The first message: the request, and the asker's note labelled as theirs.
    static func message(_ request: Companion.DeskRequest) -> String {
        guard let note = request.note else { return request.text }
        let who = ["you": "Shelby", "claude": "Claude", "codex": "Codex"][request.source] ?? request.source.capitalized
        return request.text + "\n\n---\nNote from \(who) with this request: \(note)"
    }

    /// The question a reply ends on ("Want me to ship it?"), if it ends on one.
    static func question(in markdown: String) -> String? {
        // A long reply's end is enough; code blocks aren't questions to Shelby.
        let text = String(markdown.suffix(4_000)).replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)
        guard var line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return nil }
        line = line.replacingOccurrences(of: #"^([-*+>]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`", "*"] { line = line.replacingOccurrences(of: mark, with: "") }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " _)\"'\u{201D}\u{2019}"))
        guard line.hasSuffix("?") else { return nil }
        // Just the question: its line's last sentence.
        var start = line.startIndex
        var index = line.startIndex
        while index < line.index(before: line.endIndex) {
            let next = line.index(after: index)
            if ".!?".contains(line[index]), line[next] == " " { start = next }
            index = next
        }
        let question = line[start...].trimmingCharacters(in: .whitespaces)
        return question.count > 1 ? short(question) : nil
    }

    static func short(_ text: String, limit: Int = 240) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : flat
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func requestID(_ body: JSON) throws -> UUID {
        guard let id = body["id"]?.string.flatMap(UUID.init(uuidString:)) else { throw Failure(status: 404, message: "That request is gone.") }
        return id
    }

    // MARK: - Saving

    /// The requests changed: saved now, and announced.
    private func changed() {
        revision += 1
        let content = current()
        shown = content
        save()
        onChange?(Self.desk(content, revision: revision))
    }

    /// A change only sessions made: the revision is saved soon, so it never goes back after a restart.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                self.save()
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Companion.encoder.encode(Saved(revision: revision, requests: requests, silences: silences)).write(to: file, options: .atomic)
        } catch {
            RuntimeHooks.note("The Desk couldn't save: \(error.localizedDescription)")
        }
    }
}
