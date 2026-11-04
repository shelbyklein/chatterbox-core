import Foundation

// The Desk: incoming requests (desk.json), place proposals, and what needs Shelby. plans/front-desk.md
// The board's Ready to mark complete and Done: plans/desk-board.md

/// The Desk: what needs Shelby, work waiting to be placed, and what's working. It never does
/// work itself: starting a request opens a session in its Studio or project (or continues one
/// already there doing the same work), so work stays in its compartment. The service owns it; the phone and Claude's connector reach it through
/// the companion API (/v1/desk), the Mac app through the service socket (operation "desk").
///
/// Only the requests, what was silenced and what was marked complete are kept (desk.json in
/// the data folder). What needs Shelby, what's working and what's ready to mark complete come
/// from the sessions each time they're asked for.
@MainActor
final class DeskStore {
    static let shared = DeskStore()
    typealias Failure = CompanionServer.Failure

    /// Requests waiting to be placed and started, newest first.
    private(set) var requests: [Companion.DeskRequest] = []
    /// Waiting things Shelby silenced: off the Desk, still waiting in their sessions. Each goes
    /// once it no longer waits.
    private(set) var silences: [Silence] = []
    /// Sessions marked complete from the board (archived), newest first. Each goes from Done
    /// after a week, or once its session is unarchived or gone.
    private(set) var completions: [Completion] = []
    /// Goes up whenever anything the Desk shows changes, including what sessions are doing.
    private(set) var revision = 1
    /// After the Desk changed, with what it shows now: the service tells the app (desk.changed).
    var onChange: ((Companion.Desk) -> Void)?
    /// Sends a started request to its session: a new one's first message, or the next in one
    /// continued (queued while it works, as the phone's send is). Tests replace it, so no agent starts.
    var sendFirstMessage: (ChatSession, String) -> Void = { session, text in session.send(text) }

    /// The most requests kept; the oldest go first.
    static let limit = 200
    /// The most silences kept; the oldest go first.
    static let silenceLimit = 500
    /// The most sessions offered to continue, and the least a match scores to be offered.
    static let threadLimit = 5
    static let threadMinimum = 2
    /// How long a reply that ends on a question counts as waiting on Shelby.
    static let replyWindow: TimeInterval = 48 * 3600
    /// How long a finished reply stays Ready to mark complete, and a completion stays in Done.
    static let readyWindow: TimeInterval = 7 * 86_400
    static let doneWindow: TimeInterval = 7 * 86_400
    /// The most sessions Ready to mark complete shows, newest first.
    static let readyLimit = 50
    /// The most completions kept; the oldest go first.
    static let completionLimit = 200
    static let loose = Companion.DeskPlace(kind: "loose", id: nil, name: "Loose session",
                                           detail: "A session of its own, in no Studio or project.")

    /// One waiting thing silenced. An approval, plan or questions is its own item; a reply is
    /// the reply itself and the question it ends on, so a newer reply that asks shows again.
    /// A session Ready to mark complete ("ready") is its last reply: anything newer shows it again.
    struct Silence: Codable, Hashable {
        var chatID: UUID
        /// The approval's, plan's or questions' item, or the reply's.
        var itemID: UUID
        /// A DeskWaiting's kind, or "ready".
        var kind: String
        /// What it asked, as the Desk said it.
        var text: String
        var silencedAt: Date
    }

    /// A session marked complete from the board.
    struct Completion: Codable, Hashable {
        var chatID: UUID
        var completedAt: Date
    }

    private struct Saved: Codable {
        var revision: Int
        var requests: [Companion.DeskRequest]
        /// Nil in a desk.json from before silencing.
        var silences: [Silence]? = nil
        /// Nil in a desk.json from before the board.
        var completions: [Completion]? = nil
    }
    private struct Content: Equatable {
        var needsYou: [Companion.DeskWaiting]
        var incoming: [Companion.DeskRequest]
        var working: [Companion.DeskWorking]
        var silenced: [Companion.DeskWaiting]
        var ready: [Companion.DeskReady] = []
        var done: [Companion.DeskDone] = []
    }
    /// Something a session waits on Shelby for.
    private struct Waiting {
        var date: Date
        var item: Companion.DeskWaiting
        /// What silences it: the request's own item, or the reply's.
        var itemID: UUID

        func silenced(by silence: Silence) -> Bool {
            silence.kind != "ready" && silence.chatID == item.chatID && silence.itemID == itemID && (item.kind != "reply" || silence.text == item.text)
        }
    }
    /// A session's finished reply, asking nothing.
    private struct Finished {
        var date: Date
        var item: Companion.DeskReady
        /// The reply: what silencing it hides.
        var replyID: UUID
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
            completions = saved.completions ?? []
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

    /// Sessions already in `place` (else where the request was proposed) that look like the
    /// same work, best first: the request's and its note's words in each one's title (counted
    /// twice) and in what it was first asked and last said. Only that Studio's or project's
    /// own, open sessions; sidequests and automation runs report to their session instead.
    /// The best is a clear match when it scores well and well ahead of the next.
    func threads(for id: UUID, place chosen: Companion.DeskPlace? = nil) throws -> [Companion.DeskThread] {
        guard let request = requests.first(where: { $0.id == id }) else { throw Failure(status: 404, message: "That request is gone.") }
        guard let place = chosen ?? request.proposed else { return [] }
        let said = PlaceSuggestion.words(request.text + (request.note.map { "\n" + $0 } ?? ""))
        guard !said.isEmpty else { return [] }
        let ranked = sessions(in: place)
            .map { ($0, Self.overlap(said, with: $0)) }
            .filter { $0.1 >= Self.threadMinimum }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : Self.lastActive($0.0) > Self.lastActive($1.0) }
            .prefix(Self.threadLimit)
        let scores = ranked.map(\.1)
        let clear = (scores.first ?? 0) >= 4 && (scores.count < 2 || scores[0] >= scores[1] + 3)
        return ranked.enumerated().map { index, entry in
            let session = entry.0
            return .init(id: session.id, title: session.title, detail: session.lastActionSummary.map { Self.short($0, limit: 160) },
                         settings: session.settingsDescription, updatedAt: Self.lastActive(session), isRunning: session.isRunning,
                         match: index == 0 && clear ? "clear" : "possible")
        }
    }

    /// What a new session in `place` would start with, given the picks so far (New Chat's
    /// options for a Studio, a project's Sidechat, or a loose session). Nothing is created.
    func options(for place: Companion.DeskPlace, picks: Companion.SettingsRequest = .init()) throws -> Companion.ChatOptions {
        guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
        switch place.kind {
        case "studio":
            guard let studio = place.id.flatMap(model.studio), studio.archivedAt == nil else { throw Failure(status: 404, message: "That Studio is gone.") }
            return CompanionMapper.options(CompanionMapper.draftChat(picks, studio: studio))
        case "project":
            guard let project = model.sessions.first(where: { $0.id == place.id && $0.record.archivedAt == nil && $0.record.projectFolder != nil }) else {
                throw Failure(status: 404, message: "That project's session is gone.")
            }
            return CompanionMapper.options(CompanionMapper.draftChat(picks, studio: nil, project: project))
        default:
            return CompanionMapper.options(CompanionMapper.draftChat(picks, studio: nil))
        }
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
    /// reply since replaced, is left alone: the Desk shows what waits now. A session Ready to
    /// mark complete (its id, and the DeskReady's text) is hidden until something new happens
    /// in it. True when it's silenced.
    @discardableResult
    func silence(_ body: Companion.DeskSilenceRequest) -> Bool {
        guard let session = model?.sessions.first(where: { $0.id == body.chatID }), session.record.archivedAt == nil else { return false }
        let now = Date()
        let all = waiting(in: session, now: now)
        let silence: Silence
        // Whole seconds, as desk.json keeps it.
        let at = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        if let found = all.first(where: { candidate in
            candidate.item.id == body.id && (candidate.item.kind != "reply" || body.text == nil || body.text == candidate.item.text)
        }) {
            guard !silences.contains(where: found.silenced) else { return true }
            silence = Silence(chatID: session.id, itemID: found.itemID, kind: found.item.kind, text: found.item.text, silencedAt: at)
        } else if all.isEmpty, body.id == session.id, let finished = finished(session, now: now), body.text == nil || body.text == finished.item.text {
            guard !silences.contains(where: { $0.kind == "ready" && $0.chatID == session.id && $0.itemID == finished.replyID }) else { return true }
            silence = Silence(chatID: session.id, itemID: finished.replyID, kind: "ready", text: finished.item.text, silencedAt: at)
        } else {
            return false
        }
        silences.append(silence)
        if silences.count > Self.silenceLimit { silences.removeFirst(silences.count - Self.silenceLimit) }
        changed()
        return true
    }

    /// Mark complete: archives the session (its agent stops; nothing is removed) and puts it in
    /// Done for a week. Refused while it's working, so a reply is never cut off.
    func complete(_ chatID: UUID) throws {
        guard let model, let session = model.sessions.first(where: { $0.id == chatID }) else { throw Failure(status: 404, message: "That session is gone.") }
        guard !session.isRunning else { throw Failure(status: 409, message: "That session is working. Mark it complete once it finishes.") }
        if session.record.archivedAt == nil {
            // As the phone's Archive: the Mac keeps showing what it was.
            let shown = model.selectedID
            model.archive(session)
            if let shown, shown != session.id, model.sessions.contains(where: { $0.id == shown }) { model.selectedID = shown }
        }
        // Whole seconds, as desk.json keeps it.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        completions.removeAll { $0.chatID == chatID }
        completions.insert(Completion(chatID: chatID, completedAt: now), at: 0)
        if completions.count > Self.completionLimit { completions.removeLast(completions.count - Self.completionLimit) }
        changed()
    }

    /// Reopen: unarchives the session and takes it out of Done.
    func reopen(_ chatID: UUID) throws {
        guard let session = model?.sessions.first(where: { $0.id == chatID }) else { throw Failure(status: 404, message: "That session is gone.") }
        if session.record.archivedAt != nil { session.setArchived(false) }
        completions.removeAll { $0.chatID == chatID }
        changed()
    }

    func ignore(_ id: UUID) throws {
        guard requests.contains(where: { $0.id == id }) else { throw Failure(status: 404, message: "That request is gone.") }
        requests.removeAll { $0.id == id }
        changed()
    }

    /// Starts a request where it was proposed, or in `body.place`: a new chat in a Studio, a new
    /// Sidechat of a project's session, or a loose session, on the agent and model chosen (else
    /// as a new one there would start). It's named from the request, which becomes its first
    /// message (with the note, labelled), and leaves the Desk. With `body.continueChat`, the
    /// request is that session's next message instead (queued while it works) and nothing new starts.
    func start(_ id: UUID, _ body: Companion.DeskStartRequest = .init()) throws -> ChatSession {
        guard let request = requests.first(where: { $0.id == id }) else { throw Failure(status: 404, message: "That request is gone.") }
        if let chat = body.continueChat {
            guard let session = model?.sessions.first(where: { $0.id == chat }), session.record.archivedAt == nil else {
                throw Failure(status: 404, message: "That session is gone.")
            }
            guard !session.isRestartingThread else {
                throw Failure(status: 409, message: "That session is reconnecting. Try again when it's ready.")
            }
            requests.removeAll { $0.id == id }
            save()
            sendFirstMessage(session, Self.message(request))
            changed()
            return session
        }
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
        // The model chosen, before anything's sent.
        let settings = Companion.SettingsRequest(model: Self.clean(body.model), effort: Self.clean(body.effort), openModel: Self.clean(body.openModel))
        if settings.model != nil || settings.effort != nil || settings.openModel != nil { CompanionMapper.apply(settings, to: session) }
        session.setTitle(Self.title(request.text))
        // Off the Desk (and saved so) before it's sent, so a request is never started twice.
        requests.removeAll { $0.id == id }
        save()
        sendFirstMessage(session, Self.message(request))
        changed()
        return session
    }

    /// The service socket's "desk" operation (the Mac app): `action` get, add, start, ignore,
    /// silence, complete, reopen, places, threads or options, with the companion API's bodies, plus `id` for
    /// start, ignore and threads. Replies as the companion API does: the Desk, a started
    /// session's ChatDetail, the places, the sessions to continue, or a new session's options
    /// in `place` (with `picks`, a SettingsRequest). An agent's request is from Claude (or
    /// Codex), never from Shelby.
    func operation(_ body: JSON, agent: Bool) throws -> JSON {
        switch body["action"]?.string ?? "get" {
        case "get":
            return try .value(snapshot())
        case "places":
            return try .value(places())
        case "threads":
            let place = try body["place"].map { try $0.decode(Companion.DeskPlace.self) }
            return try .value(threads(for: try Self.requestID(body), place: place))
        case "options":
            guard let place = try? body["place"]?.decode(Companion.DeskPlace.self) else { throw Failure(status: 400, message: "Say which place.") }
            let picks = (try? body["picks"]?.decode(Companion.SettingsRequest.self)) ?? .init()
            return try .value(options(for: place, picks: picks))
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
        case "complete", "reopen":
            guard let request = try? body.decode(Companion.DeskSessionRequest.self) else { throw Failure(status: 400, message: "Say which session.") }
            if body["action"]?.string == "complete" { try complete(request.chatID) } else { try reopen(request.chatID) }
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

    /// What the Desk shows now. Silences that no longer match anything waiting (or ready) go,
    /// and completions no longer in Done.
    private func current() -> Content {
        guard let model else { return Content(needsYou: [], incoming: requests, working: [], silenced: []) }
        var needs: [(date: Date, item: Companion.DeskWaiting)] = []
        var silenced: [(date: Date, item: Companion.DeskWaiting)] = []
        var working: [(date: Date, item: Companion.DeskWorking)] = []
        var ready: [(date: Date, item: Companion.DeskReady)] = []
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
                                .init(id: session.id, title: name.title, place: placeName(session), subtitle: name.subtitle,
                                      activity: session.lastActionSummary.map { Self.short($0, limit: 160) }, since: session.record.turnStartedAt)))
            } else if all.isEmpty, let finished = finished(session, now: now) {
                if let silence = silences.first(where: { $0.kind == "ready" && $0.chatID == session.id && $0.itemID == finished.replyID }) {
                    live.insert(silence)
                } else {
                    ready.append((finished.date, finished.item))
                }
            }
        }
        if live.count < silences.count { silences.removeAll { !live.contains($0) } }
        // Done: completions from the last week whose sessions are still archived.
        let byID = Dictionary(model.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var done: [Companion.DeskDone] = []
        let kept = completions.filter { completion in
            guard now.timeIntervalSince(completion.completedAt) < Self.doneWindow, let session = byID[completion.chatID],
                  session.record.archivedAt != nil else { return false }
            let name = CompanionMapper.heading(session)
            done.append(.init(id: session.id, title: name.title, place: placeName(session), subtitle: name.subtitle, completedAt: completion.completedAt))
            return true
        }
        if kept.count < completions.count { completions = kept }
        func newestFirst<T: Identifiable>(_ a: (date: Date, item: T), _ b: (date: Date, item: T)) -> Bool where T.ID == UUID {
            a.date != b.date ? a.date > b.date : a.item.id.uuidString < b.item.id.uuidString
        }
        return Content(needsYou: needs.sorted(by: newestFirst).map(\.item), incoming: requests,
                       working: working.sorted(by: newestFirst).map(\.item), silenced: silenced.sorted(by: newestFirst).map(\.item),
                       ready: Array(ready.sorted(by: newestFirst).prefix(Self.readyLimit).map(\.item)),
                       done: done.map { (date: $0.completedAt, item: $0) }.sorted(by: newestFirst).map(\.item))
    }

    /// A session that finished its reply in the last week and asks nothing: idle, its last
    /// word the agent's. Sidequests and automation runs report to their session instead. The
    /// caller has checked it waits on nothing.
    private func finished(_ session: ChatSession, now: Date) -> Finished? {
        guard !session.isRunning, !session.hasBackgroundWork, session.record.sidequestOf == nil, session.record.automationID == nil,
              let last = session.items.last(where: { $0.kind == .user || ($0.kind == .assistant && $0.phase == .final) }),
              last.kind == .assistant else { return nil }
        let date = last.timestamp ?? session.record.updatedAt
        guard now.timeIntervalSince(date) < Self.readyWindow else { return nil }
        let name = CompanionMapper.heading(session)
        let text = ChatSession.firstSentence(of: last.text, limit: 160) ?? "Finished its reply."
        return Finished(date: date, item: .init(id: session.id, title: name.title, place: placeName(session), subtitle: name.subtitle,
                                                text: text, finishedAt: date), replyID: last.id)
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

    /// A place's own open sessions: a Studio's chats, a project's session with its Sidechats
    /// and worktrees, or loose ones. Never sidequests or automation runs.
    private func sessions(in place: Companion.DeskPlace) -> [ChatSession] {
        guard let model else { return [] }
        let open = model.sessions.filter { $0.record.archivedAt == nil && $0.record.sidequestOf == nil && $0.record.automationID == nil }
        switch place.kind {
        case "studio":
            guard let id = place.id else { return [] }
            return open.filter { $0.record.studioID == id }
        case "project":
            guard let project = model.sessions.first(where: { $0.id == place.id }), let folder = project.record.projectFolder else { return [] }
            return open.filter { $0.id == project.id || $0.record.sidechatOf == project.id || $0.record.worktreeOf == folder }
        case "loose":
            return open.filter {
                $0.record.studioID == nil && $0.record.projectFolder == nil && $0.record.sidechatOf == nil && $0.record.sidechatProjectFolder == nil
            }
        default:
            return []
        }
    }

    private static func lastActive(_ session: ChatSession) -> Date { max(session.record.updatedAt, session.record.createdAt) }

    /// How much of what was said a session shares: words in its title count twice, then words
    /// in what it was first asked and what it last asked and said.
    static func overlap(_ said: Set<String>, with session: ChatSession) -> Int {
        let named = PlaceSuggestion.words(session.title)
        let first = session.items.first { $0.kind == .user }
        let lastAsked = session.items.last { $0.kind == .user }
        let lastSaid = session.items.last { $0.kind == .assistant && $0.phase == .final }
        let text = [first, lastAsked, lastSaid].compactMap { $0.map { String($0.text.prefix(2_000)) } }.joined(separator: "\n")
        return named.intersection(said).count * 2 + PlaceSuggestion.words(text).subtracting(named).intersection(said).count
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
        .init(revision: revision, needsYou: content.needsYou, incoming: content.incoming, working: content.working, silenced: content.silenced,
              ready: content.ready, done: content.done)
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

    /// The requests, silences or completions changed: saved now, and announced.
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
            try Companion.encoder.encode(Saved(revision: revision, requests: requests, silences: silences, completions: completions)).write(to: file, options: .atomic)
        } catch {
            RuntimeHooks.note("The Desk couldn't save: \(error.localizedDescription)")
        }
    }
}
