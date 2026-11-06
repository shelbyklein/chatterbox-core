import Foundation

// The Desk: tasks (desk.json), place proposals, and what needs Shelby. plans/front-desk.md
// The board's Review and Done: plans/desk-board.md
// Tasks linked to threads, and work threads: plans/work-threads.md

/// The Desk: what needs Shelby, work waiting to be placed, and what's working. It never does
/// work itself: starting a request opens a session in its Studio or project (or continues one
/// already there doing the same work), so work stays in its compartment. The service owns it; the phone and Claude's connector reach it through
/// the companion API (/v1/desk), the Mac app through the service socket (operation "desk").
///
/// A request is a **task**: it stays on the Desk once started, linked to the thread doing it
/// (one task per thread, one thread per task), and moves across the board with that thread:
/// To do (not linked), Working, Needs you, Review, Done (its thread archived,
/// for a week). Threads with no task show only when they need Shelby.
///
/// Only the tasks and what was silenced are kept (desk.json in the data folder). What needs
/// Shelby, what's working and what's ready come from the sessions each time they're asked for.
@MainActor
final class DeskStore {
    static let shared = DeskStore()
    typealias Failure = CompanionServer.Failure

    /// Every task, newest first: To do, linked to a thread, or done this week.
    private(set) var tasks: [TaskRecord] = []
    /// To do: tasks waiting to be placed and started (or linked), newest first.
    var requests: [Companion.DeskRequest] { tasks.filter(isToDo).map(\.request) }
    /// Waiting things Shelby silenced: off the Desk, still waiting in their sessions. Each goes
    /// once it no longer waits.
    private(set) var silences: [Silence] = []
    /// Goes up whenever anything the Desk shows changes, including what sessions are doing.
    private(set) var revision = 1
    /// After the Desk changed, with what it shows now: the service tells the app (desk.changed).
    var onChange: ((Companion.Desk) -> Void)?
    /// Sends a started request to its session: a new one's first message, or the next in one
    /// continued (queued while it works, as the phone's send is). Tests replace it, so no agent starts.
    var sendFirstMessage: (ChatSession, String) -> Void = { session, text in session.send(text) }

    /// The most tasks kept to do; the oldest go first.
    static let limit = 200
    /// The most silences kept; the oldest go first.
    static let silenceLimit = 500
    /// The most sessions offered to continue, and the least a match scores to be offered.
    static let threadLimit = 5
    static let threadMinimum = 2
    /// How long a reply that ends on a question counts as waiting on Shelby.
    static let replyWindow: TimeInterval = 48 * 3600
    /// How long a completed task stays in Done (and in desk.json).
    static let doneWindow: TimeInterval = 7 * 86_400
    /// The most tasks Review shows, newest first.
    static let readyLimit = 50
    static let loose = Companion.DeskPlace(kind: "loose", id: nil, name: "Loose session",
                                           detail: "A session of its own, in no Studio or project.")

    /// One waiting thing silenced. An approval, plan or questions is its own item; a reply is
    /// the reply itself and the question it ends on, so a newer reply that asks shows again.
    /// A session Review ("ready") is its last reply: anything newer shows it again.
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

    /// A task: a request, and the thread doing it once it's linked.
    struct TaskRecord: Codable, Hashable {
        var id: UUID
        var text: String
        var source: String
        var createdAt: Date
        var proposed: Companion.DeskPlace?
        var note: String? = nil
        /// The thread doing it; nil while it's to do.
        var chatID: UUID? = nil
        var linkedAt: Date? = nil
        /// When it was marked complete (its thread archived).
        var completedAt: Date? = nil
        /// Named after its thread (put on the Desk as the thread was made): the first message,
        /// then the thread's own name, renamed with it.
        var followsThread: Bool? = nil
        /// Where it came from: a ClickUp task or an email (plans/source-linked-tasks.md).
        var origin: Companion.DeskOrigin? = nil
        /// Can an agent finish it without Shelby? (plans/desk-confidence.md)
        var confidence: Companion.DeskConfidence? = nil
        /// Started by itself because it scored Yes.
        var autoStarted: Bool? = nil

        init(_ request: Companion.DeskRequest) {
            id = request.id; text = request.text; source = request.source; createdAt = request.createdAt
            proposed = request.proposed; note = request.note; origin = request.origin; confidence = request.confidence
        }
        var request: Companion.DeskRequest {
            .init(id: id, text: text, source: source, createdAt: createdAt, proposed: proposed, note: note,
                  origin: origin, check: DeskOriginRules.check(origin, column: .todo, since: createdAt), confidence: confidence)
        }
        var isOpen: Bool { completedAt == nil }
    }

    private struct Saved: Codable {
        var revision: Int
        /// To do, as builds from before tasks read it.
        var requests: [Companion.DeskRequest]
        /// Nil in a desk.json from before silencing.
        var silences: [Silence]? = nil
        /// Every task; nil in a desk.json from before tasks, whose requests become tasks to do.
        var tasks: [TaskRecord]? = nil
    }
    private struct Content: Equatable {
        var needsYou: [Companion.DeskWaiting]
        var incoming: [Companion.DeskRequest]
        var working: [Companion.DeskWorking]
        var silenced: [Companion.DeskWaiting]
        var ready: [Companion.DeskReady] = []
        var done: [Companion.DeskDone] = []
        var linked: [Companion.DeskTask] = []
        var sourcePull: Companion.DeskSourcePull? = nil
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
            // Requests from before tasks are tasks to do; sessions aren't made tasks.
            tasks = (saved.tasks ?? saved.requests.map(TaskRecord.init)).sorted { $0.createdAt > $1.createdAt }
            // Tasks from before sources: a ClickUp link in the note or text is their source.
            for index in tasks.indices where tasks[index].origin == nil {
                tasks[index].origin = DeskOriginRules.clickUp(in: (tasks[index].note ?? "") + "\n" + tasks[index].text)
            }
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
                // A thread finished: an auto-started slot may be free.
                self.autoStartWaiting()
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
    /// The best is a clear match when it scores well and well ahead of the next. With `all`
    /// (Link a thread), every one there, the rest ("other") after the matches, newest first.
    /// Each names the open task it already carries.
    func threads(for id: UUID, place chosen: Companion.DeskPlace? = nil, all: Bool = false) throws -> [Companion.DeskThread] {
        guard let request = requests.first(where: { $0.id == id }) else { throw Failure(status: 404, message: "That request is gone.") }
        guard let place = chosen ?? request.proposed else { return [] }
        let said = PlaceSuggestion.words(request.text + (request.note.map { "\n" + $0 } ?? ""))
        guard all || !said.isEmpty else { return [] }
        let scored = sessions(in: place)
            .map { ($0, said.isEmpty ? 0 : Self.overlap(said, with: $0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : Self.lastActive($0.0) > Self.lastActive($1.0) }
        let matching = scored.filter { $0.1 >= Self.threadMinimum }.prefix(all ? Int.max : Self.threadLimit)
        let ranked = all ? scored : Array(matching)
        let scores = matching.map(\.1)
        let clear = (scores.first ?? 0) >= 4 && (scores.count < 2 || scores[0] >= scores[1] + 3)
        return ranked.enumerated().map { index, entry in
            let session = entry.0
            let match = entry.1 < Self.threadMinimum ? "other" : index == 0 && clear ? "clear" : "possible"
            return .init(id: session.id, title: session.title, detail: session.lastActionSummary.map { Self.short($0, limit: 160) },
                         settings: session.settingsDescription, updatedAt: Self.lastActive(session), isRunning: session.isRunning,
                         match: match, task: openTask(for: session.id).map { Self.short($0.text, limit: 160) })
        }
    }

    /// What a new session in `place` would start with, given the picks so far (New Chat's
    /// options for a Studio, a project's Sidechat, or a loose session). Nothing is created.
    /// With `chat`, what that session would run on with the picks instead (Continue).
    func options(for place: Companion.DeskPlace, picks: Companion.SettingsRequest = .init(), chat: UUID? = nil) throws -> Companion.ChatOptions {
        guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
        if let chat {
            guard let session = model.sessions.first(where: { $0.id == chat && $0.record.archivedAt == nil }) else {
                throw Failure(status: 404, message: "That session is gone.")
            }
            return CompanionMapper.options(CompanionMapper.draftChat(picks, like: session))
        }
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
        var origin: Companion.DeskOrigin?
        if let ref = Self.clean(body.origin) {
            guard let parsed = DeskOriginRules.parse(ref) else {
                throw Failure(status: 400, message: "A source is clickup:<task id or link> or email:<message id>.")
            }
            origin = parsed
        } else {
            origin = DeskOriginRules.clickUp(in: (note ?? "") + "\n" + text)
        }
        if let title = Self.clean(body.originTitle) { origin?.title = String(title.prefix(200)) }
        if let url = Self.clean(body.originURL) {
            guard origin != nil else { throw Failure(status: 400, message: "Give the source reference with its link.") }
            origin?.url = try DeskOriginRules.sourceURL(url)
        }
        var confidence: Companion.DeskConfidence?
        if let answer = Self.clean(body.confidence)?.lowercased() {
            guard ["yes", "no"].contains(answer) else { throw Failure(status: 400, message: "Confidence is yes or no.") }
            guard let reason = Self.clean(body.reason) else { throw Failure(status: 400, message: "Give the reason for the confidence: what makes it safe, or what needs Shelby.") }
            confidence = .init(canRunAlone: answer == "yes", reason: String(reason.prefix(300)), by: source, at: now)
        }
        // Compare the stored inventory, not the visible board (Review and Done are capped).
        // Re-importing work must not rescore it, restart it, or move its existing thread.
        if let origin, let existing = tasks.first(where: { $0.origin.map { DeskOriginRules.sameSource($0, origin) } ?? false }) {
            return existing.request
        }
        if let existing = tasks.first(where: { task in
            if task.origin != nil && origin != nil { return false }
            // Legacy imports without a source need exact content and context. Different
            // verified identities never collapse just because their titles happen to match.
            return Self.identityText(task.text) == Self.identityText(text)
                && Self.identityText(task.note ?? "") == Self.identityText(note ?? "")
                && task.proposed?.kind == proposed?.kind && task.proposed?.id == proposed?.id
        }) { return existing.request }
        let request = Companion.DeskRequest(id: UUID(), text: text, source: source, createdAt: now, proposed: proposed, note: note, origin: origin, confidence: confidence)
        tasks.insert(TaskRecord(request), at: 0)
        // The oldest to do go first; linked and done ones stay.
        let todo = tasks.filter(isToDo)
        if todo.count > Self.limit { let old = Set(todo.suffix(todo.count - Self.limit).map(\.id)); tasks.removeAll { old.contains($0.id) } }
        changed()
        if confidence == nil { scoreQuickly(request.id) } else { autoStartWaiting() }
        return request
    }

    // MARK: - Confidence and auto-start (plans/desk-confidence.md)

    /// Auto-started tasks working at once; the rest start as those finish.
    static let autoStartLimit = 2
    /// Settings → Background service: Yes tasks start by themselves (on by default). Tests set
    /// `autoStartOverride`.
    var autoStartOverride: Bool?
    var autoStartEnabled: Bool { autoStartOverride ?? (AppPreferences.defaults.object(forKey: "deskAutoStart") as? Bool ?? true) }
    /// Scores a task added without one (the quick pass); tests replace it, so no model runs.
    var scoreTask: (Companion.DeskRequest, Companion.DeskPlace?) async -> Companion.DeskConfidence? = { request, place in
        await DeskStore.quickScore(request, place: place)
    }
    /// Tasks auto-start tried (and failed to start), so they aren't tried again until restart.
    private var autoStartTried: Set<UUID> = []

    /// The quick pass: a small model scores a task nobody scored, against the rubric.
    private func scoreQuickly(_ id: UUID) {
        guard let request = requests.first(where: { $0.id == id }) else { return }
        let place = request.proposed.flatMap { proposed in places().first { $0.id == proposed.id && $0.kind == proposed.kind } } ?? request.proposed
        Task { [weak self] in
            guard let self, let score = await self.scoreTask(request, place) else { return }
            guard let index = self.tasks.firstIndex(where: { $0.id == id }), self.isToDo(self.tasks[index]), self.tasks[index].confidence == nil else { return }
            self.tasks[index].confidence = score
            self.changed()
            self.autoStartWaiting()
        }
    }

    /// Starts the To do tasks that scored Yes, oldest first, while fewer than two auto-started
    /// ones are working. Only with a reason and a proposed place, and not while its source
    /// disagrees with the board. New sessions still wait while the Mac is under pressure.
    func autoStartWaiting() {
        guard autoStartEnabled, let model else { return }
        let byID = Dictionary(model.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let running = tasks.filter { task in
            guard task.autoStarted == true, task.isOpen, let chat = task.chatID, let session = byID[chat] else { return false }
            return session.isWorkingOn || session.isRunning || session.record.pressureHold != nil
        }.count
        var slots = Self.autoStartLimit - running
        guard slots > 0 else { return }
        let ready = tasks.filter { task in
            guard isToDo(task), !autoStartTried.contains(task.id), let score = task.confidence, score.canRunAlone,
                  !score.reason.trimmingCharacters(in: .whitespaces).isEmpty, task.proposed != nil else { return false }
            return DeskOriginRules.check(task.origin, column: .todo, since: task.createdAt) == nil
        }.sorted { $0.createdAt < $1.createdAt }
        for task in ready where slots > 0 {
            autoStartTried.insert(task.id)
            do { _ = try start(task.id, auto: true); slots -= 1 }
            catch { RuntimeHooks.note("The Desk couldn't start \u{201C}\(Self.short(task.text, limit: 60))\u{201D} by itself: \(error.localizedDescription)") }
        }
    }

    /// The rubric, as the quick pass is given it.
    static let rubric = """
    You score one task for Shelby's Desk: can an AI agent finish it without Shelby? Answer No if any of these holds:
    1. Creative judgment: it needs Shelby's taste or direction (choosing between designs, deciding a look, writing in Shelby's voice for something that matters).
    2. Missing info or access: something it needs isn't in the task, its note, its source or its place (a file, a detail, a login, a decision).
    3. Outward-facing: finishing it means sending email, publishing, pushing live, changing ClickUp, or anything other people see.
    4. Approvals mid-work: it would need permission for installs, deleting files, working outside its folder, or spending money.
    5. No clear place: it isn't clear which Studio or project it belongs in.
    Otherwise Yes: a clear deliverable, everything at hand, staying inside the Mac and its folder. When unsure, answer No.
    Reply with JSON only: {"canRunAlone": true or false, "reason": "one short line: the blocking rule for No, or why it's safe for Yes"}
    """

    /// The quick pass itself: Claude Haiku with no tools or files, a minute at most. Nil when it
    /// doesn't answer (the task stays unscored and waits for Shelby, as before).
    static func quickScore(_ request: Companion.DeskRequest, place: Companion.DeskPlace?) async -> Companion.DeskConfidence? {
        var prompt = "Task: \(request.text)\nAdded by: \(request.source)"
        if let note = request.note { prompt += "\nNote: \(note)" }
        if let origin = request.origin { prompt += "\nSource: \(origin.kind) \(origin.title ?? origin.id)" }
        if let place {
            prompt += "\nPlace: \(place.kind) \u{201C}\(place.name)\u{201D}" + (place.detail.map { " — what belongs there: " + String($0.prefix(1_500)) } ?? "")
        } else {
            prompt += "\nPlace: none proposed"
        }
        guard let raw = await NextSteps.quick(prompt, system: rubric, backend: .claude) else { return nil }
        return parseScore(raw, at: wholeSeconds())
    }

    /// The quick pass's JSON answer.
    static func parseScore(_ raw: String, at: Date) -> Companion.DeskConfidence? {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(raw[open...close].utf8)) as? [String: Any],
              let yes = object["canRunAlone"] as? Bool,
              let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
        return .init(canRunAlone: yes, reason: String(reason.prefix(300)), by: "quick pass", at: at)
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
        } else if all.isEmpty, body.id == session.id, !session.isRunning, let task = openTask(for: session.id),
                  case let finished = finished(session, task: task), body.text == nil || body.text == finished.item.text {
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

    /// Unsilence: puts something silenced back on the Desk, on every device (Undo after
    /// silencing, and the "silenced" list). The body names it as `silence` did: an approval's,
    /// plan's or questions' item, or the session's id for a reply (with what it asks) or for a
    /// session Review. True when a silence went.
    @discardableResult
    func unsilence(_ body: Companion.DeskSilenceRequest) -> Bool {
        let before = silences.count
        silences.removeAll { silence in
            silence.chatID == body.chatID
                && (silence.itemID == body.id || (body.id == body.chatID && (body.text == nil || silence.text == body.text)))
        }
        guard silences.count < before else { return false }
        changed()
        return true
    }

    /// Mark complete: archives the session (its agent stops; nothing is removed), and the task
    /// it carries goes to Done for a week. Refused while it's working, so a reply is never cut off.
    func complete(_ chatID: UUID) throws {
        guard let model, let session = model.sessions.first(where: { $0.id == chatID }) else { throw Failure(status: 404, message: "That session is gone.") }
        guard !session.isRunning else { throw Failure(status: 409, message: "That session is working. Mark it complete once it finishes.") }
        if session.record.archivedAt == nil {
            // As the phone's Archive: the Mac keeps showing what it was.
            let shown = model.selectedID
            model.archive(session)
            if let shown, shown != session.id, model.sessions.contains(where: { $0.id == shown }) { model.selectedID = shown }
        }
        let now = Self.wholeSeconds()
        for index in tasks.indices where tasks[index].chatID == chatID && tasks[index].completedAt == nil { tasks[index].completedAt = now }
        changed()
    }

    /// Reopen: unarchives the session, and its task leaves Done (to wherever its thread is now).
    func reopen(_ chatID: UUID) throws {
        // A task marked done without a thread (its id stands in for the session's): back to To do.
        if model?.sessions.contains(where: { $0.id == chatID }) != true,
           let index = tasks.firstIndex(where: { $0.id == chatID && $0.chatID == nil && $0.completedAt != nil }) {
            tasks[index].completedAt = nil
            changed()
            return
        }
        guard let session = model?.sessions.first(where: { $0.id == chatID }) else { throw Failure(status: 404, message: "That session is gone.") }
        if session.record.archivedAt != nil { session.setArchived(false) }
        // Its newest task: one thread carries one task.
        if let index = tasks.firstIndex(where: { $0.chatID == chatID }) { tasks[index].completedAt = nil }
        changed()
    }

    /// What a task's source says now (`desk source`): every task with that source (or the one
    /// named) takes the status, and its card warns where the board disagrees. The number updated.
    @discardableResult
    func reportOrigin(_ body: Companion.DeskOriginReport) throws -> Int {
        guard let status = Self.clean(body.status) else { throw Failure(status: 400, message: "Say what the source's status is.") }
        let wanted = try body.ref.map { ref -> Companion.DeskOrigin in
            guard let parsed = DeskOriginRules.parse(ref) else { throw Failure(status: 400, message: "A source is clickup:<task id or link> or email:<message id>.") }
            return parsed
        }
        guard wanted != nil || body.task != nil else { throw Failure(status: 400, message: "Say which source or task.") }
        let sourceURL = try Self.clean(body.url).map(DeskOriginRules.sourceURL)
        let now = Self.wholeSeconds()
        var count = 0
        for index in tasks.indices {
            let matches = body.task.map { $0 == tasks[index].id }
                ?? (wanted.map { w in tasks[index].origin.map { $0.kind == w.kind && $0.id.lowercased() == w.id.lowercased() } ?? false } ?? false)
            guard matches else { continue }
            var origin = tasks[index].origin ?? wanted ?? Companion.DeskOrigin(kind: "clickup", id: "")
            guard !origin.id.isEmpty else { continue }
            let newReply = origin.kind == "email" && status.lowercased() == "new reply"
            origin.status = String(status.prefix(60))
            origin.checkedAt = now
            if let title = Self.clean(body.title) { origin.title = String(title.prefix(200)) }
            if let sourceURL { origin.url = sourceURL }
            if newReply {
                origin.replyFrom = Self.clean(body.replyFrom) ?? origin.replyFrom
                origin.replyAt = now
            } else if origin.kind == "email" {
                origin.replyFrom = nil; origin.replyAt = nil
            }
            tasks[index].origin = origin
            count += 1
        }
        guard count > 0 else { throw Failure(status: 404, message: "No task on the Desk has that source.") }
        changed()
        return count
    }

    /// Write-back (Shelby's tap on a card's offer, plans/source-linked-tasks.md): asks an agent
    /// to make the change in the task's source, ClickUp or a reply to the email, with its
    /// connector. It goes to the task's open thread, else a new session in its Studio (or a loose
    /// one), named for it. Nothing changes outside Chatterbox until that agent does it; an email
    /// is only drafted. Answers the session it went to.
    func writeBack(_ id: UUID) throws -> ChatSession {
        guard let task = tasks.first(where: { $0.id == id }), let origin = task.origin else { throw Failure(status: 404, message: "That task has no source.") }
        let desk = snapshot()
        let checks: [Companion.DeskOriginCheck?] = desk.incoming.filter { $0.id == id }.map(\.check)
            + desk.needsYou.filter { $0.task == id }.map(\.check) + desk.working.filter { $0.task == id }.map(\.check)
            + (desk.ready ?? []).filter { $0.task == id }.map(\.check) + (desk.done ?? []).filter { $0.task == id }.map(\.check)
        guard let offer = checks.compactMap({ $0?.writeBack }).first else { throw Failure(status: 409, message: "Its source agrees with the board now.") }
        let text = Self.writeBackMessage(offer, origin: origin, task: task.text)
        if let chat = task.chatID, let session = model?.sessions.first(where: { $0.id == chat }), session.record.archivedAt == nil {
            sendFirstMessage(session, text)
            return session
        }
        let server = CompanionServer.shared
        let studio = task.proposed?.kind == "studio" ? task.proposed?.id : nil
        let session = try server.newSession(project: nil, studio: studio, backend: nil)
        session.setTitle(Self.title(offer))
        sendFirstMessage(session, text)
        return session
    }

    /// What a write-back asks the agent, with the source named so it can find it.
    static func writeBackMessage(_ offer: String, origin: Companion.DeskOrigin, task: String) -> String {
        let named = origin.title.map { "\u{201C}\($0)\u{201D}" } ?? ""
        let ref = "\(origin.kind):\(origin.id)"
        if origin.kind == "email" {
            return """
            \(offer) (from the Desk). The email \(named) has message id \(origin.id); the task here is \u{201C}\(task)\u{201D}. Read the newest reply with your mail connector and draft my reply in a draft block for me to review. Don't send it. Once it's answered, report it with `desk source \(ref) --status "answered"`.
            """
        }
        let link = origin.url.map { " (\($0))" } ?? ""
        return """
        \(offer) (from the Desk). The ClickUp task \(named)\(link) has id \(origin.id); the task here is \u{201C}\(task)\u{201D}. Make that change with your ClickUp connector and tell me when it's done, then report the new status with `desk source \(ref) --status "<its status>"`.
        """
    }

    /// Mark done: a task to do that was done outside Chatterbox (no thread) goes straight to Done.
    func markDone(_ id: UUID) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id && isToDo($0) }) else { throw Failure(status: 404, message: "That request is gone.") }
        tasks[index].chatID = nil
        tasks[index].completedAt = Self.wholeSeconds()
        changed()
    }

    /// Remove (Ignore): a task to do leaves the Desk.
    func ignore(_ id: UUID) throws {
        guard tasks.contains(where: { $0.id == id && isToDo($0) }) else { throw Failure(status: 404, message: "That request is gone.") }
        tasks.removeAll { $0.id == id }
        changed()
    }

    /// Starts a task to do where it was proposed, or in `body.place`: a new chat in a Studio, a
    /// new work thread of a project's session (it reports back there), or a loose session, on the
    /// agent and model chosen (else as a new one there would start). It's named from the request,
    /// which becomes its first message (with the note, labelled), and the task is linked to it.
    /// With `body.continueChat`, the request is that session's next message instead (queued while
    /// it works), nothing new starts, and the task is linked to it; a session carrying another
    /// open task is refused unless `body.replace` (that task goes back to To do). The agent and
    /// model given switch that session first, as Session Settings would.
    func start(_ id: UUID, _ body: Companion.DeskStartRequest = .init(), auto: Bool = false) throws -> ChatSession {
        guard let index = tasks.firstIndex(where: { $0.id == id && isToDo($0) }) else { throw Failure(status: 404, message: "That request is gone.") }
        let request = tasks[index].request
        if let chat = body.continueChat {
            guard let session = model?.sessions.first(where: { $0.id == chat }), session.record.archivedAt == nil else {
                throw Failure(status: 404, message: "That session is gone.")
            }
            guard !session.isRestartingThread else {
                throw Failure(status: 409, message: "That session is reconnecting. Try again when it's ready.")
            }
            // The model chosen for it, as Session Settings would switch it, before it's sent.
            let settings = Companion.SettingsRequest(backend: Self.clean(body.agent)?.lowercased(), model: Self.clean(body.model),
                                                     effort: Self.clean(body.effort), openModel: Self.clean(body.openModel))
            if let agent = settings.backend {
                guard let chosen = Backend(rawValue: agent) else { throw Failure(status: 400, message: "The agent is claude or codex.") }
                // Its agent changes only between replies.
                if chosen != session.record.backend, session.isRunning {
                    throw Failure(status: 409, message: "That session is working. Its agent can change once it's done.")
                }
            }
            try canCarry(session, replacing: body.replace == true)
            if settings.backend != nil || settings.model != nil || settings.effort != nil || settings.openModel != nil {
                CompanionMapper.apply(settings, to: session)
            }
            link(id, to: session.id)
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
            session.setTitle(Self.title(request.text))
        case "project":
            guard let id = place.id, let project = model?.sessions.first(where: { $0.id == id && $0.record.archivedAt == nil }),
                  project.record.projectFolder != nil else {
                throw Failure(status: 404, message: "That project's session is gone.")
            }
            // A work thread of the project's session: it starts on its agent (another one is
            // switched to before anything's sent), and reports back there.
            session = try newWorkThread(of: project, title: Self.title(request.text))
            if let backend, backend != session.record.backend { session.setBackend(backend) }
        case "loose":
            session = try server.newSession(project: nil, studio: nil, backend: backend)
            session.setTitle(Self.title(request.text))
        default:
            throw Failure(status: 400, message: "A place is a studio, a project, or loose.")
        }
        // The model chosen, before anything's sent.
        let settings = Companion.SettingsRequest(model: Self.clean(body.model), effort: Self.clean(body.effort), openModel: Self.clean(body.openModel))
        if settings.model != nil || settings.effort != nil || settings.openModel != nil { CompanionMapper.apply(settings, to: session) }
        // Linked (and saved so) before it's sent, so a request is never started twice.
        link(id, to: session.id)
        if auto, let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].autoStarted = true }
        save()
        // A work thread waits to start while the Mac is under pressure (ChatSession+Pressure).
        let first = auto ? Self.autoPreface(request) + Self.message(request) : Self.message(request)
        session.sendFirstOrHold(first) { sendFirstMessage(session, $0) }
        if let front = session.record.workOf.flatMap({ id in model?.sessions.first { $0.id == id } }) { front.noteWorkStarted(session) }
        changed()
        return session
    }

    // MARK: - Tasks and threads (plans/work-threads.md)

    /// Link a thread (from a To do card): the task is done in that thread. One that carries
    /// another open task is refused unless `replace`: then that task goes back to To do.
    func link(_ id: UUID, _ body: Companion.DeskLinkRequest) throws {
        guard let task = tasks.first(where: { $0.id == id }), task.isOpen else { throw Failure(status: 404, message: "That task is gone.") }
        guard let session = model?.sessions.first(where: { $0.id == body.chatID }), session.record.archivedAt == nil else {
            throw Failure(status: 404, message: "That session is gone.")
        }
        guard task.chatID != session.id else { return }
        try canCarry(session, replacing: body.replace == true)
        link(id, to: session.id)
        changed()
    }

    /// Unlink: the task goes back to To do; its thread carries on as a thread.
    func unlink(_ id: UUID) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].isOpen else { throw Failure(status: 404, message: "That task is gone.") }
        tasks[index].chatID = nil
        tasks[index].linkedAt = nil
        changed()
    }

    /// Make this a task (from a thread): a new task, already linked, named `text` or else the
    /// thread's title, in the thread's place.
    @discardableResult
    func makeTask(_ body: Companion.DeskTaskRequest, source: String = "you") throws -> UUID {
        guard let session = model?.sessions.first(where: { $0.id == body.chatID }), session.record.archivedAt == nil else {
            throw Failure(status: 404, message: "That session is gone.")
        }
        try canCarry(session, replacing: false)
        let follow = body.follow == true
        let text = Self.clean(body.text).map { String($0.prefix(4_000)) } ?? (follow ? Self.threadName(session) : nil) ?? session.title
        var task = TaskRecord(.init(id: UUID(), text: text, source: source, createdAt: Self.wholeSeconds(), proposed: place(of: session)))
        task.chatID = session.id
        task.linkedAt = task.createdAt
        if follow { task.followsThread = true }
        tasks.insert(task, at: 0)
        changed()
        return task.id
    }

    /// To do: open, and not linked (or linked to a thread that's gone).
    func isToDo(_ task: TaskRecord) -> Bool {
        task.isOpen && (task.chatID.map { id in model?.sessions.contains { $0.id == id } != true } ?? true)
    }

    /// The open task a thread carries.
    func openTask(for chatID: UUID) -> TaskRecord? { tasks.first { $0.chatID == chatID && $0.isOpen } }

    /// Whether `session` can carry a task: not a sidequest or automation run, and not one
    /// carrying another open task, unless that one may go back to To do (`replacing`).
    private func canCarry(_ session: ChatSession, replacing: Bool) throws {
        guard session.record.sidequestOf == nil, session.record.automationID == nil else {
            throw Failure(status: 409, message: "Sidequests and automation runs report to their session; they aren't tasks.")
        }
        guard let other = openTask(for: session.id) else { return }
        guard replacing else {
            throw Failure(status: 409, message: "That thread already carries a task: \u{201C}\(Self.short(other.text, limit: 80))\u{201D}. Link it anyway to send that one back to To do.")
        }
        if let index = tasks.firstIndex(where: { $0.id == other.id }) { tasks[index].chatID = nil; tasks[index].linkedAt = nil }
    }

    private func link(_ id: UUID, to chatID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].chatID = chatID
        tasks[index].linkedAt = Self.wholeSeconds()
    }

    /// What a task named after its thread is called: the thread's name once it has one of its
    /// own (given, or named from the first message), else its first message's first line; nil
    /// while there's neither (a new sidechat, before its first message).
    static func threadName(_ session: ChatSession) -> String? {
        let title = session.title
        let untitled = title == "New chat"
            || (session.record.sidechatOf != nil && title.hasPrefix("Sidechat") && title.contains(" \u{00B7} "))
        if !untitled { return title }
        guard let first = session.items.first(where: { $0.kind == .user && $0.automatic != true && !$0.text.isEmpty }) else { return nil }
        let line = first.text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 80 ? String(line.prefix(79)) + "\u{2026}" : line
    }

    /// A thread was deleted: its open task goes back to To do, and a done one goes.
    func threadDeleted(_ chatID: UUID) {
        guard tasks.contains(where: { $0.chatID == chatID }) else { return }
        tasks.removeAll { $0.chatID == chatID && !$0.isOpen }
        for index in tasks.indices where tasks[index].chatID == chatID { tasks[index].chatID = nil; tasks[index].linkedAt = nil }
        changed()
    }

    /// A work thread of `front` (plans/work-threads.md): a fresh thread in its folder, started
    /// with `brief` as its first message, on the front thread's agent and model unless `agent`
    /// or `model` say otherwise, carrying its own task (linked, in the front thread's place),
    /// reporting back when it finishes. Only from a thread that isn't one itself, a sidequest or
    /// an automation run.
    func startWork(from front: ChatSession, _ body: Companion.WorkStartRequest, source: String) throws -> ChatSession {
        guard front.record.archivedAt == nil else { throw Failure(status: 404, message: "That session is archived.") }
        guard front.record.workOf == nil else {
            throw Failure(status: 409, message: "A work thread doesn't start work threads of its own; report back instead (work report).")
        }
        guard front.record.sidequestOf == nil, front.record.automationID == nil else {
            throw Failure(status: 409, message: "Sidequests and automation runs can't start work threads.")
        }
        guard let title = Self.clean(body.title) else { throw Failure(status: 400, message: "Name the work thread.") }
        guard let brief = Self.clean(body.brief) else {
            throw Failure(status: 400, message: "Give the work thread a brief: what to do, what's decided, which files to read.")
        }
        guard brief.count <= 100_000 else { throw Failure(status: 400, message: "That brief is too long.") }
        var backend: Backend?
        if let agent = Self.clean(body.agent) {
            guard let chosen = Backend(rawValue: agent.lowercased()) else { throw Failure(status: 400, message: "The agent is claude or codex.") }
            backend = chosen
        }
        let session = try newWorkThread(of: front, title: Self.title(title))
        if let backend, backend != session.record.backend { session.setBackend(backend) }
        if let model = Self.clean(body.model) { CompanionMapper.apply(.init(model: model), to: session) }
        var task = TaskRecord(.init(id: UUID(), text: String(title.prefix(4_000)), source: Self.clean(source) ?? "you",
                                    createdAt: Self.wholeSeconds(), proposed: place(of: front)))
        task.chatID = session.id
        task.linkedAt = task.createdAt
        tasks.insert(task, at: 0)
        // Saved before it's sent, so the task is there when the thread starts working.
        save()
        // Made now, with its task; started once the Mac isn't under pressure (ChatSession+Pressure).
        session.sendFirstOrHold(brief) { sendFirstMessage(session, $0) }
        front.noteWorkStarted(session)
        changed()
        return session
    }

    private func newWorkThread(of front: ChatSession, title: String) throws -> ChatSession {
        guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
        let shown = model.selectedID
        defer { if let shown, model.sessions.contains(where: { $0.id == shown }) { model.selectedID = shown } }
        do { return try model.newWorkThread(of: front, title: title) } catch { throw Failure(status: 503, message: "Could not save the new work thread.") }
    }

    /// A front thread's work threads for its Work strip, newest first: open ones, and those
    /// done (archived) this week.
    func workThreads(of front: ChatSession) -> [Companion.WorkThread] {
        guard let model else { return [] }
        let now = Date()
        return model.sessions.filter { session in
            guard session.record.workOf == front.id else { return false }
            guard let archived = session.record.archivedAt else { return true }
            return now.timeIntervalSince(archived) < Self.doneWindow
        }
        .sorted { $0.record.createdAt > $1.record.createdAt }
        .map { session in
            let state = session.record.archivedAt != nil ? "done" : session.isWaitingOnYou ? "needsYou"
                : session.isWorkingOn ? "working" : "ready"
            return .init(id: session.id, title: session.title, state: state, task: tasks.first { $0.chatID == session.id }?.id,
                         backend: session.record.backend.rawValue, updatedAt: session.record.updatedAt,
                         status: state == "working" ? session.lastActionSummary.map { Self.short($0, limit: 160) } : nil)
        }
    }

    /// The service socket's "work" operation, once the caller may: `action` start (a
    /// WorkStartRequest's fields) answers the work thread's ChatDetail; list, the front
    /// thread's work threads. Report is the session's own (ChatSession.reportWork).
    func workOperation(_ body: JSON, in session: ChatSession, agent: Bool) throws -> JSON {
        guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
        switch body["action"]?.string ?? "list" {
        case "list":
            let front = session.record.workOf.flatMap { id in model.sessions.first { $0.id == id } } ?? session
            return try .value(workThreads(of: front))
        case "start":
            guard let request = try? body.decode(Companion.WorkStartRequest.self) else { throw Failure(status: 400, message: "Name the work thread and give it a brief.") }
            let work = try startWork(from: session, request, source: agent ? session.record.backend.rawValue : "you")
            return try .value(CompanionMapper.detail(work, model: model))
        default:
            throw RuntimeFailure("unsupported_operation")
        }
    }

    /// The service socket's "desk" operation (the Mac app): `action` get, add, start, ignore,
    /// silence, unsilence, complete, reopen, link, unlink, makeTask, places, threads or options,
    /// with the companion API's bodies, plus `id` for start, ignore, link, unlink and threads
    /// (and `all` for threads). Replies as the companion API does: the Desk, a started
    /// session's ChatDetail, the places, the sessions to continue, or a new session's options
    /// in `place` (with `picks`, a SettingsRequest). An agent's request is from Claude (or
    /// Codex), never from Shelby.
    func operation(_ body: JSON, agent: Bool) throws -> JSON {
        switch body["action"]?.string ?? "get" {
        case "checkSources":
            guard !agent else { throw Failure(status: 403, message: "Only you can request a source check.") }
            try checkSources(includeNew: body["includeNew"]?.bool ?? true)
            return try .value(snapshot())
        case "get":
            var result = try JSON.value(snapshot()).object ?? [:]
            // Agent inventory includes every stored task, even hidden/older review and done.
            result["tasks"] = try .value(tasks)
            return .object(result)
        case "places":
            return try .value(places())
        case "threads":
            let place = try body["place"].map { try $0.decode(Companion.DeskPlace.self) }
            return try .value(threads(for: try Self.requestID(body), place: place, all: body["all"]?.bool == true))
        case "options":
            guard let place = try? body["place"]?.decode(Companion.DeskPlace.self) else { throw Failure(status: 400, message: "Say which place.") }
            let picks = (try? body["picks"]?.decode(Companion.SettingsRequest.self)) ?? .init()
            // `chat`: as that session would run with the picks (Continue).
            let chat = body["chat"]?.string.flatMap(UUID.init(uuidString:))
            return try .value(options(for: place, picks: picks, chat: chat))
        case "add":
            guard var request = try? body.decode(Companion.DeskAddRequest.self) else { throw Failure(status: 400, message: "Say what needs doing.") }
            if agent { request.source = ["claude", "codex"].contains(request.source ?? "") ? request.source : "claude" }
            let before = Set(tasks.map(\.id))
            let added = try add(request)
            var result = try JSON.value(snapshot()).object ?? [:]
            result["addition"] = ["id": .string(added.id.uuidString), "created": .bool(!before.contains(added.id))]
            return .object(result)
        case "origin":
            guard let report = try? body.decode(Companion.DeskOriginReport.self) else { throw Failure(status: 400, message: "Say which source and its status.") }
            try reportOrigin(report)
            return try .value(snapshot())
        case "writeBack":
            let session = try writeBack(try Self.requestID(body))
            guard let model else { throw Failure(status: 503, message: "Chatterbox is starting.") }
            return try .value(CompanionMapper.detail(session, model: model))
        case "ignore":
            try ignore(try Self.requestID(body))
            return try .value(snapshot())
        case "markDone":
            try markDone(try Self.requestID(body))
            return try .value(snapshot())
        case "silence":
            guard let request = try? body.decode(Companion.DeskSilenceRequest.self) else { throw Failure(status: 400, message: "Say what to silence.") }
            silence(request)
            return try .value(snapshot())
        case "unsilence":
            guard let request = try? body.decode(Companion.DeskSilenceRequest.self) else { throw Failure(status: 400, message: "Say what to unsilence.") }
            unsilence(request)
            return try .value(snapshot())
        case "complete", "reopen":
            guard let request = try? body.decode(Companion.DeskSessionRequest.self) else { throw Failure(status: 400, message: "Say which session.") }
            if body["action"]?.string == "complete" { try complete(request.chatID) } else { try reopen(request.chatID) }
            return try .value(snapshot())
        case "link":
            let id = try Self.requestID(body)
            guard let request = try? body.decode(Companion.DeskLinkRequest.self) else { throw Failure(status: 400, message: "Say which thread.") }
            try link(id, request)
            return try .value(snapshot())
        case "unlink":
            try unlink(try Self.requestID(body))
            return try .value(snapshot())
        case "makeTask":
            guard let request = try? body.decode(Companion.DeskTaskRequest.self) else { throw Failure(status: 400, message: "Say which thread.") }
            try makeTask(request)
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

    /// What the Desk shows now. To do: tasks not linked (or whose thread is gone). Needs you:
    /// every thread waiting on Shelby, task or not. Working and Ready: threads carrying a task,
    /// by what they're doing. Done: tasks completed this week. Silences that no longer match
    /// anything waiting (or ready) go.
    private func current() -> Content {
        guard let model else { return Content(needsYou: [], incoming: requests, working: [], silenced: []) }
        let now = Date()
        let byID = Dictionary(model.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if reconcile(byID, now: now) { scheduleSave() }
        var carried: [UUID: TaskRecord] = [:]
        for task in tasks where task.isOpen { if let chat = task.chatID, carried[chat] == nil { carried[chat] = task } }
        var needs: [(date: Date, item: Companion.DeskWaiting)] = []
        var silenced: [(date: Date, item: Companion.DeskWaiting)] = []
        var working: [(date: Date, item: Companion.DeskWorking)] = []
        var ready: [(date: Date, item: Companion.DeskReady)] = []
        var live = Set<Silence>()
        for session in model.sessions where session.record.archivedAt == nil {
            let task = carried[session.id]
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
            if var shown {
                shown.item.task = task?.id
                shown.item.taskText = task?.text
                shown.item.origin = task?.origin
                shown.item.autoStarted = task?.autoStarted
                shown.item.check = task.flatMap { DeskOriginRules.check($0.origin, column: .needsYou, since: $0.linkedAt ?? $0.createdAt) }
                needs.append((shown.date, shown.item))
            } else if !all.isEmpty || task == nil {
                // Waiting on something silenced is waiting, not working; a thread with no task
                // shows only when it needs Shelby.
                continue
            } else if session.isWorkingOn {
                // A work thread between turns, waiting on its background work, is working too.
                let name = CompanionMapper.heading(session)
                working.append((session.record.turnStartedAt ?? session.record.updatedAt,
                                .init(id: session.id, title: name.title, place: placeName(session), subtitle: name.subtitle,
                                      activity: session.lastActionSummary.map { Self.short($0, limit: 160) }, since: session.record.turnStartedAt,
                                      task: task?.id, taskText: task?.text, origin: task?.origin,
                                      check: task.flatMap { DeskOriginRules.check($0.origin, column: .working, since: $0.linkedAt ?? $0.createdAt) },
                                      autoStarted: task?.autoStarted)))
            } else {
                let finished = finished(session, task: task)
                if let silence = silences.first(where: { $0.kind == "ready" && $0.chatID == session.id && $0.itemID == finished.replyID }) {
                    live.insert(silence)
                } else {
                    ready.append((finished.date, finished.item))
                }
            }
        }
        if live.count < silences.count { silences.removeAll { !live.contains($0) } }
        // Done: tasks completed this week whose threads are still archived.
        var done: [Companion.DeskDone] = []
        for task in tasks {
            // Done outside Chatterbox: no thread; Reopen sends it back to To do (its id as the session's).
            if let completed = task.completedAt, task.chatID == nil {
                done.append(.init(id: task.id, title: task.text, place: task.proposed?.name, subtitle: "Done outside Chatterbox", completedAt: completed,
                                  task: task.id, taskText: task.text, origin: task.origin,
                                  check: DeskOriginRules.check(task.origin, column: .done, since: completed)))
                continue
            }
            guard let completed = task.completedAt, let chat = task.chatID, let session = byID[chat], session.record.archivedAt != nil else { continue }
            let name = CompanionMapper.heading(session)
            done.append(.init(id: session.id, title: name.title, place: placeName(session), subtitle: name.subtitle, completedAt: completed,
                              task: task.id, taskText: task.text, origin: task.origin,
                              check: DeskOriginRules.check(task.origin, column: .done, since: completed), autoStarted: task.autoStarted))
        }
        // To do: not linked, or linked to a thread that's gone (until its deletion unlinks it).
        let incoming = tasks.filter { $0.isOpen && ($0.chatID.map { byID[$0] == nil } ?? true) }.map(\.request)
        let linked = tasks.compactMap { task -> Companion.DeskTask? in
            guard let chat = task.chatID, byID[chat] != nil else { return nil }
            return .init(id: task.id, text: task.text, chatID: chat, completedAt: task.completedAt)
        }
        func newestFirst<T: Identifiable>(_ a: (date: Date, item: T), _ b: (date: Date, item: T)) -> Bool where T.ID == UUID {
            a.date != b.date ? a.date > b.date : a.item.id.uuidString < b.item.id.uuidString
        }
        return Content(needsYou: needs.sorted(by: newestFirst).map(\.item), incoming: incoming,
                       working: working.sorted(by: newestFirst).map(\.item), silenced: silenced.sorted(by: newestFirst).map(\.item),
                       ready: Array(ready.sorted(by: newestFirst).prefix(Self.readyLimit).map(\.item)),
                       done: done.map { (date: $0.completedAt, item: $0) }.sorted(by: newestFirst).map(\.item),
                       linked: linked, sourcePull: sourcePullState())
    }

    private func sourcePullState() -> Companion.DeskSourcePull {
        guard let routine = try? ProjectAutomations.deskSourceRoutine(in: ProjectAutomations.load()) else { return .init() }
        let state = ProjectAutomations.loadState()
        let latest = routine.compactMap { state[$0.id.uuidString] }.max { ($0.lastRun ?? .distantPast) < ($1.lastRun ?? .distantPast) }
        let thread = latest?.threadID.flatMap { id in model?.sessions.first { $0.id == id } }
        return .init(routineID: routine.first?.id, lastRequestedAt: latest?.lastRun, threadID: thread?.id,
                     isRunning: thread.map { $0.record.archivedAt == nil && ($0.isRunning || $0.isWaitingOnYou) } ?? false,
                     needsYou: thread?.isWaitingOnYou ?? false)
    }

    /// A user tap reuses the configured intake, without a second scheduler or duplicate run.
    func checkSources(includeNew: Bool = true) throws {
        let routine: [ProjectAutomation]
        do { routine = try ProjectAutomations.deskSourceRoutine(in: ProjectAutomations.load()) }
        catch { throw Failure(status: 409, message: error.localizedDescription) }
        if sourcePullState().isRunning { return }
        _ = try CompanionServer.shared.runAutomation(routine[0].id, deskSources: true, includeNew: includeNew)
        changed()
    }

    /// Tasks follow their threads: one archived outside the board is done (when it was
    /// archived), one unarchived is open again, and done ones go after a week. True when
    /// something changed.
    private func reconcile(_ byID: [UUID: ChatSession], now: Date) -> Bool {
        var changed = false
        for index in tasks.indices {
            guard let chat = tasks[index].chatID, let session = byID[chat] else { continue }
            if let archived = session.record.archivedAt, tasks[index].completedAt == nil {
                tasks[index].completedAt = Date(timeIntervalSince1970: archived.timeIntervalSince1970.rounded(.down))
                changed = true
            } else if session.record.archivedAt == nil, tasks[index].completedAt != nil {
                tasks[index].completedAt = nil
                changed = true
            }
            if tasks[index].followsThread == true, let name = Self.threadName(session), name != tasks[index].text {
                tasks[index].text = name
                changed = true
            }
        }
        let before = tasks.count
        tasks.removeAll { task in task.completedAt.map { now.timeIntervalSince($0) >= Self.doneWindow } ?? false }
        return changed || tasks.count < before
    }

    /// A thread carrying a task, idle and asking nothing: Review, however long
    /// ago it finished, with its last reply's first sentence. The caller has checked it waits
    /// on nothing.
    private func finished(_ session: ChatSession, task: TaskRecord?) -> Finished {
        let name = CompanionMapper.heading(session)
        let last = session.items.last(where: { $0.kind == .user || ($0.kind == .assistant && $0.phase == .final) })
        let reply = last?.kind == .assistant ? last : nil
        let date = reply?.timestamp ?? session.record.updatedAt
        let text = reply.flatMap { ChatSession.firstSentence(of: $0.text, limit: 160) } ?? (reply == nil ? "No reply yet." : "Finished its reply.")
        return Finished(date: date, item: .init(id: session.id, title: name.title, place: placeName(session), subtitle: name.subtitle,
                                                text: text, finishedAt: date, task: task?.id, taskText: task?.text,
                                                assets: reply.map { Self.assets(of: $0, folder: session.workingFolder) }.flatMap { $0.isEmpty ? nil : $0 },
                                                origin: task?.origin, check: DeskOriginRules.check(task?.origin, column: .review, since: date),
                                                autoStarted: task?.autoStarted),
                        replyID: reply?.id ?? session.id)
    }

    /// What a finished reply made or points to, for the Review column: files and images it
    /// attached or names (that exist), then its web links. Newest reply only, at most six.
    static func assets(of reply: DisplayItem, folder: String?, limit: Int = 6) -> [Companion.DeskAsset] {
        var seen = Set<String>()
        var found: [Companion.DeskAsset] = []
        let fm = FileManager.default
        func addFile(_ path: String) {
            var directory: ObjCBool = false
            guard found.count < limit, seen.insert(path).inserted, fm.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return }
            let url = URL(fileURLWithPath: path)
            let image = MediaKind.isStillImage(path) || url.pathExtension.lowercased() == "gif"
            found.append(.init(kind: image ? "image" : "file", title: url.lastPathComponent, path: path))
        }
        reply.attachments?.forEach { addFile($0.url.path) }
        ChatSession.referencedImages(in: reply.text, folder: folder).forEach { addFile($0.path) }
        PathLinks.referencedFiles(in: reply.text, folder: folder).forEach(addFile)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let text = reply.text
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard found.count < limit, let url = match.url, ["http", "https"].contains(url.scheme ?? ""), seen.insert(url.absoluteString).inserted else { continue }
                let title = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "") + (url.path.count > 1 ? url.path : "")
                found.append(.init(kind: "link", title: String(title.prefix(60)), url: url.absoluteString))
            }
        }
        return found
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
                let isPlan = request.approvalStyle == .plan
                var waiting = item(id: request.id, kind: isPlan ? "plan" : "approval", text: Self.short(request.text))
                // The exact command or files, so it can be allowed from the Desk without opening it.
                if !isPlan, let detail = request.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                    waiting.detail = detail.count > 4000 ? String(detail.prefix(3999)) + "\u{2026}" : detail
                }
                return Waiting(date: date, item: waiting, itemID: request.id)
            }
        }
        // A question in a reply: the last thing said is the agent's, asking. Sidequests and
        // automation runs report to their session, not to Shelby.
        // A work thread's reply between turns (background work still going) is progress.
        guard !session.isRunning, !session.isWorkPending, session.record.sidequestOf == nil, session.record.automationID == nil,
              let last = session.items.last(where: { $0.kind == .user || ($0.kind == .assistant && $0.phase == .final) }),
              last.kind == .assistant else { return [] }
        let date = last.timestamp ?? session.record.updatedAt
        guard now.timeIntervalSince(date) < Self.replyWindow, let question = Self.question(in: last.text) else { return [] }
        return [Waiting(date: date, item: item(id: session.id, kind: "reply", text: question), itemID: last.id)]
    }

    /// A session's Studio or project, or its parent's for a Sidechat, sidequest or work thread.
    private func placeName(_ session: ChatSession, depth: Int = 0) -> String? {
        guard let model else { return nil }
        if let id = session.record.studioID, let studio = model.studio(id) { return studio.name }
        if session.record.projectFolder != nil { return session.projectName }
        if depth < 3, let parentID = session.record.sidechatOf ?? session.record.sidequestOf ?? session.record.workOf,
           let parent = model.sessions.first(where: { $0.id == parentID }) {
            return placeName(parent, depth: depth + 1)
        }
        return session.record.sidechatProjectFolder.map { ($0 as NSString).lastPathComponent }
    }

    /// Where a session is, as a place to propose: its Studio, its project (a worktree's or a
    /// Sidechat's, the project's own session), or loose.
    private func place(of session: ChatSession, depth: Int = 0) -> Companion.DeskPlace? {
        guard let model else { return nil }
        if let id = session.record.studioID, let studio = model.studio(id) {
            return Self.place(.init(id: studio.id, name: studio.name, instructions: studio.trimmedInstructions, kind: .studio))
        }
        let folder = session.record.worktreeOf ?? session.record.projectFolder
        if let folder, let project = model.sessions.first(where: { $0.record.projectFolder == folder && $0.record.worktreeOf == nil && $0.record.archivedAt == nil }) {
            return Self.place(.init(id: project.id, name: project.projectName,
                                    instructions: project.record.brief?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", kind: .project))
        }
        if depth < 3, let parentID = session.record.sidechatOf ?? session.record.sidequestOf ?? session.record.workOf,
           let parent = model.sessions.first(where: { $0.id == parentID }) {
            return place(of: parent, depth: depth + 1)
        }
        return session.record.sidechatProjectFolder == nil ? Self.loose : nil
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
              ready: content.ready, done: content.done, linked: content.linked, sourcePull: content.sourcePull)
    }

    /// Now, in whole seconds, as desk.json keeps it.
    private static func wholeSeconds() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

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
    /// What an auto-started task's first message opens with: why it started, and to stop and
    /// ask at anything the rubric says needs Shelby.
    static func autoPreface(_ request: Companion.DeskRequest) -> String {
        let why = request.confidence.map { " (\($0.reason))" } ?? ""
        return "[Started automatically from the Desk: it was judged doable without the user\(why). If you reach a creative call, missing information or access, anything outward-facing (sending, publishing, changing ClickUp), or something needing approval, stop and ask instead of guessing.]\n\n"
    }

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

    private static func identityText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
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

    /// The tasks or silences changed: saved now, and announced.
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
            try Companion.encoder.encode(Saved(revision: revision, requests: requests, silences: silences, tasks: tasks)).write(to: file, options: .atomic)
        } catch {
            RuntimeHooks.note("The Desk couldn't save: \(error.localizedDescription)")
        }
    }
}

/// Tasks from ClickUp and email (plans/source-linked-tasks.md): reading a source reference, and
/// whether what the source last said agrees with the task's column. Warn only.
enum DeskOriginRules {
    enum Column { case todo, working, needsYou, review, done }

    static func sameSource(_ a: Companion.DeskOrigin, _ b: Companion.DeskOrigin) -> Bool {
        guard a.kind == b.kind else { return false }
        // ClickUp IDs are case-insensitive; email IDs are opaque and case-sensitive.
        return a.kind == "clickup" ? a.id.caseInsensitiveCompare(b.id) == .orderedSame : a.id == b.id
    }

    /// Source buttons open web pages, never arbitrary application commands or local files.
    static func sourceURL(_ value: String) throws -> String {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw DeskStore.Failure(status: 400, message: "Give an http or https link to the source.")
        }
        return value
    }

    /// "clickup:<id or link>", "email:<message id>", or a bare ClickUp link.
    static func parse(_ ref: String) -> Companion.DeskOrigin? {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = clickUp(in: ref), !ref.lowercased().hasPrefix("email:") { return found }
        guard let colon = ref.firstIndex(of: ":") else { return nil }
        let kind = ref[..<colon].lowercased()
        let id = ref[ref.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.count <= 500 else { return nil }
        switch kind {
        case "clickup": return .init(kind: "clickup", id: id.hasPrefix("#") ? String(id.dropFirst()) : id)
        case "email", "mail", "outlook": return .init(kind: "email", id: id)
        default: return nil
        }
    }

    /// The first ClickUp task link in `text` (app.clickup.com/t/<id>, or /t/<team>/<custom id>).
    static func clickUp(in text: String) -> Companion.DeskOrigin? {
        guard let range = text.range(of: #"https?://app\.clickup\.com/t/[A-Za-z0-9_/-]+"#, options: .regularExpression) else { return nil }
        let url = String(text[range])
        guard let id = url.split(separator: "/").last.map(String.init), !id.isEmpty, id != "t" else { return nil }
        return .init(kind: "clickup", id: id, url: url)
    }

    /// Where the source disagrees with the board. `since` is when the task reached its column
    /// (added, linked, finished its reply, completed): an email reply after it is news.
    static func check(_ origin: Companion.DeskOrigin?, column: Column, since: Date) -> Companion.DeskOriginCheck? {
        guard let origin, let raw = origin.status?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let status = raw.lowercased()
        let shown = raw.prefix(1).uppercased() + raw.dropFirst()
        if origin.kind == "email" {
            guard status == "new reply", (origin.replyAt ?? origin.checkedAt ?? .distantPast) >= since else { return nil }
            let who = origin.replyFrom ?? "them"
            let when = column == .done ? " since this was marked Done" : column == .review ? " since this was ready for review" : ""
            return .init(warning: "New reply from \(who)\(when)", writeBack: "Draft the reply to \(who)")
        }
        let closed = ["complete", "completed", "closed", "done", "resolved", "shipped"].contains(status)
        let notStarted = ["to do", "todo", "open", "backlog", "new", "not started", "pending"].contains(status)
        if column == .done {
            return closed ? nil : .init(warning: "ClickUp still says \(shown)", writeBack: "Mark the ClickUp task complete")
        }
        if closed { return .init(warning: "ClickUp says \(shown)", match: "done") }
        if notStarted, column != .todo { return .init(warning: "ClickUp still says \(shown)", writeBack: "Set ClickUp to In progress") }
        return nil
    }
}
