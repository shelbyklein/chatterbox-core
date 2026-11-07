import AppKit
import Observation
import SwiftUI

// The Desk on the Mac, a board: To do · Working · Needs you · Review · Done.
// plans/front-desk.md, plans/desk-board.md
//
// Home's first page: Desk at the top of its left column, the toolbar's Desk button, and
// Go > Desk (⌘0). Needs you and Working come from the sessions this Mac already has (the same
// pending approvals, plans and questions their cards show), so Approve here is the chat's own
// Approve. Requests waiting to be placed (To do), the places they can go, replies that ask you
// something, what was silenced, sessions ready to mark complete and those done come from the
// background service: socket operation "desk" (action get, add, start, ignore, silence,
// complete, reopen, places, threads or options, with the HTTP API's bodies and replies), which
// sends "desk.changed" when they change. Start opens a step
// (DeskStartPopover): the place, a session already there doing the same work to continue, or
// the agent and model for a new one (in a project, a work thread of its session). What starts
// runs in the background, with a note to open it.
//
// Tasks (plans/work-threads.md): a request stays a task once started, linked to its thread.
// Working, Ready and Done show only threads carrying a task (the service's `linked`); Needs you
// shows every thread, marking those that aren't tasks, with Make this a task. To do cards can
// Link a thread; task cards Unlink.

/// A session waiting on you, with what it asks.
struct DeskNeed: Identifiable, Equatable {
    var waiting: Companion.DeskWaiting
    /// An approval's command or files, shown under what it asks.
    var detail: String? = nil
    var id: UUID { waiting.id }
    /// Approvals and plans are answered here; questions and replies open the session.
    var canDecide: Bool { waiting.kind == "approval" || waiting.kind == "plan" }
    /// What silencing it hides: the item, or for a reply (its id is the session's) the question it asks.
    var silenceKey: String { Self.silenceKey(chatID: waiting.chatID, id: waiting.id, reply: waiting.kind == "reply" ? waiting.text : nil) }
    static func silenceKey(chatID: UUID, id: UUID, reply text: String? = nil) -> String {
        "\(chatID.uuidString)|\(id.uuidString)" + (text.map { "|" + $0 } ?? "")
    }
}

/// What the Desk shows: the board's columns (plans/desk-board.md). A column with nothing in it
/// says so in one quiet line.
struct DeskSections: Equatable {
    /// The columns, left to right.
    enum Section: String, CaseIterable, Identifiable {
        case todo = "To do", working = "Working", needsYou = "Needs you", ready = "Review", onHold = "On hold", done = "Done"
        var id: String { key }
        /// For DeskDebug's frames ("section:needsYou").
        var key: String {
            switch self {
            case .todo: "todo"
            case .working: "working"
            case .needsYou: "needsYou"
            case .ready: "ready"
            case .onHold: "onHold"
            case .done: "done"
            }
        }
        var empty: String {
            switch self {
            case .todo: "Nothing waiting to start."
            case .working: "Nothing running."
            case .needsYou: "Nothing needs you."
            case .ready: "Nothing finished to mark complete."
            case .onHold: "Put a task on hold from its menu."
            case .done: "Nothing completed this week."
            }
        }
    }

    var needsYou: [DeskNeed] = []
    var incoming: [Companion.DeskRequest] = []
    var working: [Companion.DeskWorking] = []
    var ready: [Companion.DeskReady] = []
    var onHold: [Companion.DeskHeld] = []
    var done: [Companion.DeskDone] = []
    /// Silenced (on any device), still waiting in their sessions: the quiet row at the foot of
    /// Needs you, each with Unsilence. Not counted in Needs you.
    var silenced: [Companion.DeskWaiting] = []

    func count(_ section: Section) -> Int {
        switch section {
        case .todo: incoming.count
        case .working: working.count
        case .needsYou: needsYou.count
        case .ready: ready.count
        case .onHold: onHold.count
        case .done: done.count
        }
    }
    var summary: String {
        let active = Self.summary(needsYou: needsYou.count, incoming: incoming.count, working: working.count, ready: ready.count)
        guard !onHold.isEmpty else { return active }
        return (active == "All clear" ? "" : active + " · ") + "\(onHold.count) on hold"
    }
    /// What needs acting on: the toolbar's Desk badge. Not what's ready to mark complete:
    /// nothing waits on that.
    var actionCount: Int { needsYou.count + incoming.count }

    /// The header's line: "2 need you · 1 to do · 3 working · 4 ready".
    static func summary(needsYou: Int, incoming: Int, working: Int, ready: Int = 0) -> String {
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if incoming > 0 { parts.append("\(incoming) to do") }
        if working > 0 { parts.append("\(working) working") }
        if ready > 0 { parts.append("\(ready) ready") }
        return parts.isEmpty ? "All clear" : parts.joined(separator: " · ")
    }
}

/// The Desk's state: the service's Desk, and the Desk's actions. One for the app (`shared`);
/// tests make their own with a stand-in Desk and transport.
@MainActor
@Observable
final class DeskModel {
    static let shared = DeskModel()
    /// Sends one "desk" request (its body) and returns the reply.
    typealias Transport = @MainActor (_ body: JSON, _ timeout: Duration) async throws -> JSON

    /// The service's Desk: requests to place, and replies that ask you something.
    private(set) var snapshot: Companion.Desk?
    /// Where requests can go (the "places" action), loaded when a place is being chosen.
    private(set) var places: [Companion.DeskPlace] = []
    private(set) var loadingPlaces = false
    /// A place chosen from the place chip, by request, until it starts.
    private(set) var chosen: [UUID: Companion.DeskPlace] = [:]
    /// Requests being started or ignored.
    private(set) var busy: Set<UUID> = []
    /// Waiting things being silenced here (DeskNeed.silenceKey, readyKey), hidden until the service answers.
    private(set) var silencing: Set<String> = []
    /// Sessions being marked complete or reopened here, hidden until the service answers.
    private(set) var completing: Set<UUID> = []
    private(set) var reopening: Set<UUID> = []
    /// Silenced things being put back (DeskNeed.silenceKey), off the silenced list until the service answers.
    private(set) var unsilencing: Set<String> = []
    /// Tasks being unlinked here, and threads being made tasks, until the service answers.
    private(set) var unlinking: Set<UUID> = []
    private(set) var tasking: Set<UUID> = []
    /// The last thing silenced here: a few seconds to Undo it.
    var silencedNote: DeskNeed?
    private(set) var adding = false
    private(set) var checkingSources = false
    /// What last went wrong, shown under the header.
    var problem: String?
    /// The last request started (or continued) here: it runs in the background, with a note to open it.
    var startedNote: (name: String, chat: UUID, continued: Bool)?
    /// The service is older than the Desk: no requests until it restarts.
    private(set) var unsupported = false
    /// Approvals and plans answered here, hidden while the session catches up.
    private var answered: [UUID: Date] = [:]

    /// Where "desk" requests go: the background service unless a test gives its own.
    @ObservationIgnored var transport: Transport?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var soon: Task<Void, Never>?

    init(snapshot: Companion.Desk? = nil, places: [Companion.DeskPlace] = [], transport: Transport? = nil) {
        self.snapshot = snapshot
        self.places = places
        self.transport = transport
    }

    // MARK: Loading

    func checkSources() async {
        guard !checkingSources, snapshot?.sourcePull?.isRunning != true else { return }
        checkingSources = true
        defer { checkingSources = false }
        do {
            load(try await send(["action": "checkSources"]).decode(Companion.Desk.self))
            problem = nil
        } catch { note(error, "check source updates") }
    }

    /// The service's Desk as it is now (a reply, an event, or a test's stand-in).
    func load(_ desk: Companion.Desk) {
        snapshot = desk
        let ids = Set(desk.incoming.map(\.id))
        if chosen.keys.contains(where: { !ids.contains($0) }) { chosen = chosen.filter { ids.contains($0.key) } }
    }

    private var canReachService: Bool { transport != nil || (RuntimeClient.usesDaemon && RuntimeClient.shared.connected) }

    /// Asks the service for its Desk; one request at a time, again once if asked meanwhile.
    func refresh() {
        guard canReachService, !unsupported else { return }
        guard refreshing == nil else { refreshAgain = true; return }
        refreshing = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshAgain = false
                do {
                    load(try await send(["action": "get"]).decode(Companion.Desk.self))
                    if problem != nil, !unsupported { problem = nil }
                } catch { note(error, "load the Desk") }
            } while refreshAgain && !unsupported
            refreshing = nil
        }
    }

    /// While the Desk shows, a changed session can change what it asks (a reply's question).
    func appeared() { watchers += 1; refresh() }
    func disappeared() { watchers = max(0, watchers - 1) }

    /// From AppModel.runtimeEvent: every event the service sends the app.
    func runtimeEvent(_ event: RuntimeEvent) {
        switch event.kind {
        case "desk.changed":
            if let desk = try? event.payload?.decode(Companion.Desk.self) { load(desk) } else { refresh() }
        case "runtime.resync":
            // Connected (again): the service may have restarted with the Desk.
            unsupported = false
            refresh()
        case "chat.changed", "chat.created", "chat.deleted":
            if watchers > 0 { refreshSoon() }
        default:
            break
        }
    }

    private func refreshSoon() {
        guard soon == nil else { return }
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.soon = nil
            self?.refresh()
        }
    }

    private func send(_ body: [String: JSON], timeout: Duration = .seconds(15)) async throws -> JSON {
        if let transport { return try await transport(.object(body), timeout) }
        return try await RuntimeClient.shared.request("desk", body: .object(body), timeout: timeout)
    }

    private func note(_ error: Error, _ doing: String) {
        let text = error.localizedDescription
        if text.contains("unsupported_operation") {
            unsupported = true
            problem = "Requests to place show here once the background service restarts with this version of Chatterbox."
        } else {
            problem = "Couldn't \(doing): \(text)"
        }
    }

    // MARK: What it shows

    /// Needs you and Working from this Mac's sessions; To do (incoming requests), replies that
    /// ask you something, what was silenced, Review and Done from the service's
    /// Desk. As the service has it for the phone: a session's oldest request not silenced,
    /// newest sessions first; Needs you wins over Working, and a session waiting only on what
    /// was silenced is in neither. A ready session this Mac sees working, waiting or archived
    /// again leaves Ready before the service says so; a done one unarchived leaves Done.
    func sections(in model: AppModel, now: Date = Date()) -> DeskSections {
        let sessions = model.activeSessions
        let carried = openTasks
        let heldChats = Set((snapshot?.onHold ?? []).compactMap(\.chatID))
        var needs: [(date: Date, need: DeskNeed)] = []
        var waiting = Set<UUID>()
        // Silenced on any device: the service keeps them (its replies already leave them out).
        let silenced = Set((snapshot?.silenced ?? []).filter { $0.kind != "reply" }.map(\.id))
        for session in sessions where !heldChats.contains(session.id) {
            let pending = session.pendingRequests
            guard !pending.isEmpty else { continue }
            waiting.insert(session.id)
            // One answered here hides while the session catches up; the next one shows.
            if let item = pending.first(where: { item in
                !recentlyAnswered(item.id, now: now) && !silenced.contains(item.id)
                    && !silencing.contains(DeskNeed.silenceKey(chatID: session.id, id: item.id))
            }) {
                var need = Self.need(item, in: session, model: model)
                need.waiting.task = carried?[session.id]?.id
                need.waiting.taskText = carried?[session.id]?.text
                needs.append((item.timestamp ?? session.record.updatedAt, need))
            }
        }
        // The service decides which replies ask you something, as it does for the phone.
        if let replies = snapshot?.needsYou.filter({ $0.kind == "reply" }), !replies.isEmpty {
            let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for var reply in replies {
                guard let session = byID[reply.chatID], !session.isRunning, !waiting.contains(session.id) else { continue }
                let name = CompanionMapper.heading(session)
                reply.title = name.title
                reply.subtitle = name.subtitle
                reply.place = Self.placeName(of: session, in: model)
                reply.task = carried?[session.id]?.id
                reply.taskText = carried?[session.id]?.text
                waiting.insert(session.id)
                let need = DeskNeed(waiting: reply)
                guard !silencing.contains(need.silenceKey) else { continue }
                needs.append((session.lastActivity, need))
            }
        }
        needs.sort { $0.date == $1.date ? $0.need.id.uuidString < $1.need.id.uuidString : $0.date > $1.date }
        // Only threads carrying a task (all of them from a service older than tasks).
        let working = Attention.shared.workingChats(in: model).filter { !heldChats.contains($0.id) && !waiting.contains($0.id) && (carried == nil || carried?[$0.id] != nil) }.map { session in
            let name = CompanionMapper.heading(session)
            return Companion.DeskWorking(id: session.id, title: name.title, place: Self.placeName(of: session, in: model), subtitle: name.subtitle,
                                         activity: session.lastActionSummary, since: session.record.turnStartedAt,
                                         task: carried?[session.id]?.id, taskText: carried?[session.id]?.text)
        }
        let all = Dictionary(model.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ready = (snapshot?.ready ?? []).filter { item in
            guard !completing.contains(item.id), !silencing.contains(Self.readyKey(item)) else { return false }
            guard let session = all[item.id] else { return true }
            return session.record.archivedAt == nil && !session.isRunning && !waiting.contains(session.id)
        }
        let done = (snapshot?.done ?? []).filter { item in
            !reopening.contains(item.id) && all[item.id].map { $0.record.archivedAt != nil } ?? true
        }
        let silencedNow = (snapshot?.silenced ?? []).filter { !unsilencing.contains(DeskNeed.silenceKey(chatID: $0.chatID, id: $0.id, reply: $0.kind == "reply" ? $0.text : nil)) }
        return DeskSections(needsYou: needs.map(\.need), incoming: snapshot?.incoming ?? [], working: working, ready: ready, onHold: snapshot?.onHold ?? [], done: done, silenced: silencedNow)
    }

    /// What silencing a ready session hides: the session, as its last reply says.
    static func readyKey(_ item: Companion.DeskReady) -> String { "ready|\(item.id.uuidString)|\(item.text)" }

    /// The open task each thread carries, by thread; nil from a service older than tasks.
    var openTasks: [UUID: Companion.DeskTask]? {
        guard let linked = snapshot?.linked else { return nil }
        var tasks: [UUID: Companion.DeskTask] = [:]
        for task in linked where task.completedAt == nil && !unlinking.contains(task.id) { tasks[task.chatID] = tasks[task.chatID] ?? task }
        return tasks
    }

    /// The open task a thread carries (its menu's Unlink), if the service has tasks.
    func task(of chatID: UUID) -> Companion.DeskTask? { openTasks?[chatID] }

    /// Whether the service keeps tasks (Make this a task, Link, Unlink).
    var hasTasks: Bool { snapshot?.linked != nil && !unsupported }

    private func recentlyAnswered(_ id: UUID, now: Date) -> Bool {
        answered[id].map { now.timeIntervalSince($0) < 15 } ?? false
    }

    /// A pending approval, plan or questions card, as the Desk says it.
    static func need(_ item: DisplayItem, in session: ChatSession, model: AppModel) -> DeskNeed {
        let kind = item.kind == .questions ? "questions" : item.approvalStyle == .plan ? "plan" : "approval"
        var text = item.text
        var detail: String?
        switch kind {
        case "questions":
            let questions = item.questions ?? []
            let first = questions.first.map { $0.question.isEmpty ? $0.header : $0.question } ?? ""
            text = !first.isEmpty ? first : item.text.isEmpty ? "Has a question for you" : item.text
            if questions.count > 1 { text += " (and \(questions.count - 1) more)" }
        case "plan":
            text = item.detail.flatMap { ChatSession.firstSentence(of: $0, limit: 220) } ?? item.text
        default:
            let lines = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            detail = lines.isEmpty ? nil : lines
            if text.isEmpty { text = "Waiting for your approval" }
        }
        // Named as the session lists name it: a project's session by its project.
        let name = CompanionMapper.heading(session)
        let waiting = Companion.DeskWaiting(id: item.id, chatID: session.id, title: name.title,
                                            place: placeName(of: session, in: model), kind: kind, text: text, subtitle: name.subtitle)
        return DeskNeed(waiting: waiting, detail: detail)
    }

    /// The session's Studio or project, if it has one (a Sidechat's or sidequest's, its parent's).
    static func placeName(of session: ChatSession, in model: AppModel) -> String? {
        func own(_ session: ChatSession) -> String? {
            if let studio = model.studio(for: session) { return studio.name }
            if session.record.projectFolder != nil { return session.projectName }
            return nil
        }
        if let place = own(session) { return place }
        if let parentID = session.record.sidechatOf ?? session.record.sidequestOf,
           let parent = model.sessions.first(where: { $0.id == parentID }) { return own(parent) }
        return session.record.sidechatProjectFolder.map { ($0 as NSString).lastPathComponent }
    }

    /// The toolbar's Desk badge.
    func badgeCount(in model: AppModel) -> Int { sections(in: model).actionCount }

    // MARK: Actions

    /// Approve or Deny, as the chat's own card does.
    func decide(_ need: DeskNeed, _ decision: DisplayItem.ApprovalState, in model: AppModel) {
        guard need.canDecide, let session = model.sessions.first(where: { $0.id == need.waiting.chatID }) else { return }
        answered[need.id] = Date()
        session.resolveApproval(need.id, decision)
    }

    /// Silence, Mark complete and Reopen can reach the service (a test's transport, or the
    /// background service).
    var canSilence: Bool { canReachService && !unsupported }

    /// Silence: off the Desk on every device, without answering it (an approval stays pending
    /// in its session). A new approval, plan or questions, or a newer reply that asks, shows again.
    func silence(_ need: DeskNeed) async {
        let key = need.silenceKey
        guard canSilence, silencing.insert(key).inserted else { return }
        defer { silencing.remove(key) }
        var body: [String: JSON] = ["action": "silence", "chatID": .string(need.waiting.chatID.uuidString), "id": .string(need.id.uuidString)]
        // A reply's id is its session's: what it asks says which reply.
        if need.waiting.kind == "reply" { body["text"] = .string(need.waiting.text) }
        do {
            load(try await send(body).decode(Companion.Desk.self))
            problem = nil
            // A few seconds to take it back; it's also listed under "silenced".
            silencedNote = need
        } catch let error where error.localizedDescription.contains("unsupported_operation") {
            // The rest of the Desk still works with an older service.
            problem = "Silence works once the background service restarts with this version of Chatterbox."
        } catch { note(error, "silence it") }
    }

    /// Unsilence (Undo, or the silenced list): back on the Desk on every device, named as it
    /// was silenced.
    func unsilence(_ item: Companion.DeskWaiting) async {
        let reply = item.kind == "reply" ? item.text : nil
        let key = DeskNeed.silenceKey(chatID: item.chatID, id: item.id, reply: reply)
        guard canSilence, unsilencing.insert(key).inserted else { return }
        defer { unsilencing.remove(key) }
        if silencedNote?.silenceKey == key { silencedNote = nil }
        var body: [String: JSON] = ["action": "unsilence", "chatID": .string(item.chatID.uuidString), "id": .string(item.id.uuidString)]
        if let reply { body["text"] = .string(reply) }
        await change(body, doing: "unsilence it", older: "Unsilence works once the background service restarts with this version of Chatterbox.")
    }

    /// Silence a session ready to mark complete: off the board on every device until something
    /// new happens in it.
    func silence(_ item: Companion.DeskReady) async {
        let key = Self.readyKey(item)
        guard canSilence, silencing.insert(key).inserted else { return }
        defer { silencing.remove(key) }
        await change(["action": "silence", "chatID": .string(item.id.uuidString), "id": .string(item.id.uuidString), "text": .string(item.text)],
                     doing: "silence it", older: "Silence works once the background service restarts with this version of Chatterbox.")
    }

    /// Mark complete: the service archives the session and lists it in Done for a week.
    func complete(_ item: Companion.DeskReady) async {
        guard canSilence, completing.insert(item.id).inserted else { return }
        defer { completing.remove(item.id) }
        await change(["action": "complete", "chatID": .string(item.id.uuidString)],
                     doing: "mark it complete", older: "Mark complete works once the background service restarts with this version of Chatterbox.")
    }

    /// Reopen: the service unarchives it, and it leaves Done.
    func reopen(_ item: Companion.DeskDone) async {
        guard canSilence, reopening.insert(item.id).inserted else { return }
        defer { reopening.remove(item.id) }
        await change(["action": "reopen", "chatID": .string(item.id.uuidString)],
                     doing: "reopen it", older: "Reopen works once the background service restarts with this version of Chatterbox.")
    }

    /// Make this a task: a new task, already linked to the thread, named for it (or `text`).
    func makeTask(_ chatID: UUID, text: String? = nil) async {
        guard canSilence, tasking.insert(chatID).inserted else { return }
        defer { tasking.remove(chatID) }
        var body: [String: JSON] = ["action": "makeTask", "chatID": .string(chatID.uuidString)]
        if let text { body["text"] = .string(text) }
        await change(body, doing: "make it a task", older: "Tasks work once the background service restarts with this version of Chatterbox.")
    }

    /// Put on the Desk, as a new thread is made: a task linked to it, named from its first
    /// message (or `name`). The new thread may reach the service a moment after this does.
    func putOnDesk(_ chatID: UUID, name: String?) async {
        var body: [String: JSON] = ["action": "makeTask", "chatID": .string(chatID.uuidString), "follow": true]
        if let name, !name.isEmpty { body["text"] = .string(name) }
        for attempt in 0..<6 {
            do {
                load(try await send(body).decode(Companion.Desk.self))
                problem = nil
                return
            } catch where attempt < 5 && error.localizedDescription.contains("gone") {
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                note(error, "put it on the Desk")
                return
            }
        }
    }

    var canHold: Bool { snapshot?.onHold != nil }

    func hold(_ task: UUID, resume: Bool = false) async {
        guard canHold, busy.insert(task).inserted else { return }
        defer { busy.remove(task) }
        await change(["action": .string(resume ? "resume" : "hold"), "id": .string(task.uuidString)],
                     doing: resume ? "resume the task" : "put it on hold",
                     older: "On hold needs the newest background service.")
    }

    /// Unlink: the task goes back to To do; its thread carries on.
    func unlink(_ task: UUID) async {
        guard canSilence, unlinking.insert(task).inserted else { return }
        defer { unlinking.remove(task) }
        await change(["action": "unlink", "id": .string(task.uuidString)], doing: "unlink it",
                     older: "Tasks work once the background service restarts with this version of Chatterbox.")
    }

    /// Link a thread to a task (a To do card's Link, or a thread's Link to a Task). With
    /// `replace`, a task the thread already carries goes back to To do; without it, that's
    /// refused and false comes back, for the caller to ask first.
    @discardableResult func link(_ task: UUID, to chatID: UUID, replace: Bool = false) async -> Bool {
        guard canSilence, !busy.contains(task) else { return false }
        busy.insert(task)
        defer { busy.remove(task) }
        var body: [String: JSON] = ["action": "link", "id": .string(task.uuidString), "chatID": .string(chatID.uuidString)]
        if replace { body["replace"] = true }
        do {
            load(try await send(body).decode(Companion.Desk.self))
            problem = nil
            return true
        } catch let error where error.localizedDescription.contains("already carries a task") {
            return false
        } catch let error where error.localizedDescription.contains("unsupported_operation") {
            problem = "Tasks work once the background service restarts with this version of Chatterbox."
        } catch { note(error, "link it") }
        return false
    }

    /// Link a thread's choices: every open thread in `place`, best matches first, each with the
    /// task it already carries.
    func allThreads(for request: Companion.DeskRequest, in place: Companion.DeskPlace) async -> [Companion.DeskThread] {
        guard canReachService, !unsupported else { return [] }
        var body: [String: JSON] = ["action": "threads", "id": .string(request.id.uuidString), "all": true]
        if let value = try? JSON.value(place) { body["place"] = value }
        return (try? await send(body).decode([Companion.DeskThread].self)) ?? []
    }

    /// Sends a change the service answers with the Desk. From an older service, `older` says
    /// so; the rest of the Desk still works.
    private func change(_ body: [String: JSON], doing: String, older: String) async {
        do {
            load(try await send(body).decode(Companion.Desk.self))
            problem = nil
        } catch let error where error.localizedDescription.contains("unsupported_operation") {
            problem = older
        } catch { note(error, doing) }
    }

    func open(_ chatID: UUID, in model: AppModel) {
        guard model.sessions.contains(where: { $0.id == chatID }) else { return }
        model.showingSettings = false
        model.selectedID = chatID
    }

    func openWorking(_ chatID: UUID, in model: AppModel) {
        if !Attention.shared.openWorkingChat(chatID, in: model) { open(chatID, in: model) }
    }

    /// The ask box: a new request from you, for the Desk to propose a place for.
    @discardableResult func add(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return false }
        adding = true
        defer { adding = false }
        do {
            load(try await send(["action": "add", "text": .string(text), "source": "you"]).decode(Companion.Desk.self))
            problem = nil
            return true
        } catch {
            note(error, "add it to the Desk")
            return false
        }
    }

    /// Where a request goes: the place chosen for it, else the Desk's proposal.
    func place(for request: Companion.DeskRequest) -> Companion.DeskPlace? { chosen[request.id] ?? request.proposed }

    func choose(_ place: Companion.DeskPlace, for request: Companion.DeskRequest) { chosen[request.id] = place }

    /// Start, as its step chose: the service starts a session in the place shown (its
    /// first message is the request's text), or sends the request to `continuing`, a session
    /// already there; on `settings`' agent and model when given (a session continued switches
    /// to them first). It runs in the background.
    func start(_ request: Companion.DeskRequest, continuing: Companion.DeskThread? = nil, settings: Companion.SettingsRequest? = nil) async {
        guard let place = place(for: request), !busy.contains(request.id) else { return }
        busy.insert(request.id)
        defer { busy.remove(request.id) }
        var body: [String: JSON] = ["action": "start", "id": .string(request.id.uuidString)]
        // The place you saw, proposed or chosen, goes with it.
        if let value = try? JSON.value(place) { body["place"] = value }
        if let continuing {
            body["continueChat"] = .string(continuing.id.uuidString)
            // Its step said so: the task it carries goes back to To do.
            if continuing.task != nil { body["replace"] = true }
        }
        if let settings {
            for (key, value) in [("agent", settings.backend), ("model", settings.model), ("effort", settings.effort), ("openModel", settings.openModel)] {
                if let value, !value.isEmpty { body[key] = .string(value) }
            }
        }
        do {
            let result = try await send(body, timeout: .seconds(60))
            problem = nil
            chosen[request.id] = nil
            if var desk = snapshot { desk.incoming.removeAll { $0.id == request.id }; snapshot = desk }
            refresh()
            // It runs in the background; the Desk stays, with a note to open it.
            if let id = Self.startedSessionID(result) { startedNote = (continuing?.title ?? place.name, id, continuing != nil) }
        } catch { note(error, "start it") }
    }

    /// Sessions already in `place` that look like the same work, best first; none from a
    /// service older than continuing.
    func threads(for request: Companion.DeskRequest, in place: Companion.DeskPlace) async -> [Companion.DeskThread] {
        guard canReachService, !unsupported else { return [] }
        var body: [String: JSON] = ["action": "threads", "id": .string(request.id.uuidString)]
        if let value = try? JSON.value(place) { body["place"] = value }
        return (try? await send(body).decode([Companion.DeskThread].self)) ?? []
    }

    /// What a new session in `place` would start with, given the picks so far, or with `chat`,
    /// what that session would run on with them (it isn't changed); nil from an older service
    /// (it starts as a new session there would).
    func options(in place: Companion.DeskPlace, picks: Companion.SettingsRequest, chat: UUID? = nil) async -> Companion.ChatOptions? {
        guard canReachService, !unsupported else { return nil }
        var body: [String: JSON] = ["action": "options"]
        if let chat { body["chat"] = .string(chat.uuidString) }
        if let value = try? JSON.value(place) { body["place"] = value }
        if let value = try? JSON.value(picks) { body["picks"] = value }
        return try? await send(body).decode(Companion.ChatOptions.self)
    }

    func ignore(_ request: Companion.DeskRequest) async {
        guard !busy.contains(request.id) else { return }
        busy.insert(request.id)
        defer { busy.remove(request.id) }
        do {
            load(try await send(["action": "ignore", "id": .string(request.id.uuidString)]).decode(Companion.Desk.self))
            problem = nil
        } catch { note(error, "ignore it") }
    }

    /// Write-back (plans/source-linked-tasks.md): an agent makes the change the card offers in
    /// its source (ClickUp, or drafts the email reply); the session it went to opens.
    func writeBack(_ task: UUID, in model: AppModel) async {
        guard busy.insert(task).inserted else { return }
        defer { busy.remove(task) }
        do {
            let detail = try await send(["action": "writeBack", "id": .string(task.uuidString)]).decode(Companion.ChatDetail.self)
            problem = nil
            open(detail.summary.id, in: model)
        } catch { note(error, "ask for that change") }
    }

    /// Move to match: the source is finished, so the thread is marked complete (archived, into Done).
    func completeChat(_ chatID: UUID) async {
        guard canSilence, completing.insert(chatID).inserted else { return }
        defer { completing.remove(chatID) }
        await change(["action": "complete", "chatID": .string(chatID.uuidString)],
                     doing: "mark it complete", older: "Mark complete works once the background service restarts with this version of Chatterbox.")
    }

    /// Done outside Chatterbox: straight to Done, no thread.
    func markDone(_ request: Companion.DeskRequest) async {
        guard !busy.contains(request.id) else { return }
        busy.insert(request.id)
        defer { busy.remove(request.id) }
        do {
            load(try await send(["action": "markDone", "id": .string(request.id.uuidString)]).decode(Companion.Desk.self))
            problem = nil
        } catch { note(error, "mark it done") }
    }

    func loadPlaces() async {
        guard canReachService, !loadingPlaces, !unsupported else { return }
        loadingPlaces = true
        defer { loadingPlaces = false }
        do { places = try await send(["action": "places"]).decode([Companion.DeskPlace].self) }
        catch { note(error, "load the places") }
    }

    /// The places to choose from, and a loose session last when the service lists none.
    var placeOptions: [Companion.DeskPlace] {
        guard !places.contains(where: { $0.kind == "loose" }) else { return places }
        return places + [Companion.DeskPlace(kind: "loose", id: nil, name: "Loose session", detail: "Not in a Studio or project")]
    }

    /// The started session's id from start's reply: a ChatDetail (its summary's id), or
    /// just the id.
    static func startedSessionID(_ result: JSON) -> UUID? {
        let candidates: [JSON?] = [result["summary"]?["id"], result["chatID"], result["id"], result["chat"]?["id"], result]
        return candidates.lazy.compactMap { $0?.string.flatMap(UUID.init(uuidString:)) }.first
    }

    /// Opens the session once the app has it (a new one arrives with the next list update).
    func openWhenListed(_ id: UUID, in model: AppModel, timeout: Duration = .seconds(15)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !model.sessions.contains(where: { $0.id == id }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        open(id, in: model)
    }
}

extension AppModel {
    /// Home is open on the Desk.
    var showingDesk: Bool { showingHome && StudioSelection.saved == .desk }

    /// The toolbar's Desk button and Go > Desk (⌘0).
    func showDesk() {
        StudioSelection.save(.desk)
        showingSettings = false
        showingHome = true
    }

    /// Home on its Studios page rather than the Desk (Command Center's Studios button).
    func showStudiosOverview() {
        if StudioSelection.saved == .desk { StudioSelection.save(.pinned) }
        showingHome = true
    }
}

/// How the Desk words and marks things.
enum DeskText {
    static func icon(kind: String) -> String {
        switch kind {
        case "plan": "list.bullet.clipboard"
        case "questions": "questionmark.bubble.fill"
        case "reply": "text.bubble.fill"
        default: "hand.raised.fill"
        }
    }

    /// One word per kind, as the phone and the session's cards say it.
    static func label(kind: String) -> String {
        switch kind {
        case "plan": "Plan"
        case "questions", "reply": "Question"
        default: "Permission"
        }
    }

    /// Where a waiting session is, as its approval card says it everywhere: "USA Archery ›
    /// Deploy the site", or "Chatterbox › Mac Desk page" for a project's session.
    static func context(title: String, place: String?, subtitle: String?) -> String {
        [place.flatMap { $0 == title ? nil : $0 }, title, subtitle].compactMap { $0 }.joined(separator: " \u{203A} ")
    }

    @MainActor static func context(of session: ChatSession, in model: AppModel) -> String {
        let name = CompanionMapper.heading(session)
        return context(title: name.title, place: DeskModel.placeName(of: session, in: model), subtitle: name.subtitle)
    }

    static func icon(place: Companion.DeskPlace) -> String {
        switch place.kind {
        case "studio": "paintpalette"
        case "project": "folder"
        default: "bubble.left"
        }
    }

    /// "From Claude · 5m", "From you · 1m".
    static func origin(_ request: Companion.DeskRequest, now: Date = Date()) -> String {
        let source = request.source == "you" ? "you" : request.source.prefix(1).uppercased() + request.source.dropFirst()
        let age = ShortAge.string(since: request.createdAt, now: now)
        return age.isEmpty ? "From \(source)" : "From \(source) · \(age)"
    }

    /// "5m ago", "just now".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let age = ShortAge.string(since: date, now: now)
        return age.isEmpty || age == "now" ? "just now" : "\(age) ago"
    }

    /// A place's instructions or brief, as a line or two of plain text.
    static func detailLine(_ text: String?) -> String? {
        guard let text else { return nil }
        var inCode = false
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            if line.hasPrefix("```") { inCode.toggle(); return false }
            return !inCode && !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("|") && !line.hasPrefix(">") && line != "---"
        }
        var line = lines.prefix(3).map { $0.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression) }
            .joined(separator: " ")
        line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
        guard !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(199)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : line
    }

    static func matches(_ place: Companion.DeskPlace, _ filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || place.name.localizedCaseInsensitiveContains(needle) || (place.detail ?? "").localizedCaseInsensitiveContains(needle)
    }
}

#if DEBUG
/// For tests: where the Desk's rows and buttons are, by "kind:id".
@MainActor enum DeskDebug {
    static var frames: [String: CGRect] = [:]
}
#endif

private extension View {
    func deskFrame(_ key: String) -> some View {
        #if DEBUG
        return onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DeskDebug.frames[key] = $0 }
        #else
        return self
        #endif
    }
}

// MARK: - The page

/// The Desk as a board: To do · Working · Needs you · Review · Done, side by
/// side at a fixed width, each scrolling on its own; the board scrolls sideways when they don't
/// all fit (shown at Needs you when something does).
struct DeskView: View {
    @Environment(AppModel.self) private var model
    var desk: DeskModel = .shared
    @State private var ask = ""
    /// The board has been scrolled to Needs you once.
    @State private var showedNeedsYou = false

    /// A column's width.
    static let columnWidth: CGFloat = 320

    var body: some View {
        let sections = desk.sections(in: model)
        VStack(spacing: 0) {
            header(sections).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(DeskSections.Section.allCases.filter { $0 != .onHold || desk.canHold }) { section in
                            column(section, sections).id(section)
                        }
                    }
                    .padding(20)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .onChange(of: sections.needsYou.isEmpty, initial: true) { _, empty in
                    guard !empty, !showedNeedsYou else { return }
                    showedNeedsYou = true
                    proxy.scrollTo(DeskSections.Section.needsYou, anchor: .center)
                }
            }
        }
        .onAppear { desk.appeared() }
        .onDisappear { desk.disappeared() }
        .accessibilityLabel("Desk, \(sections.summary)")
    }

    private func header(_ sections: DeskSections) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Desk").font(.largeTitle.weight(.bold)).lineLimit(1)
                Text(sections.summary).font(.title3).foregroundStyle(Color.metadata).lineLimit(1)
                    .deskFrame("summary")
                Spacer()
                Button { Task { await desk.checkSources() } } label: {
                    HStack(spacing: 6) {
                        if desk.checkingSources || desk.snapshot?.sourcePull?.isRunning == true { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text(desk.snapshot?.sourcePull?.needsYou == true ? "Check needs you" : desk.snapshot?.sourcePull?.isRunning == true ? "Checking…" : "Check for updates")
                    }
                }
                .disabled(desk.checkingSources || desk.snapshot?.sourcePull?.isRunning == true)
                .deskFrame("checkSources")
            }
            askField.frame(maxWidth: 760, alignment: .leading)
            if let pull = desk.snapshot?.sourcePull {
                HStack(spacing: 10) {
                    if let date = pull.lastRequestedAt { Text("Last requested \(date.formatted(.relative(presentation: .numeric)))").foregroundStyle(Color.metadata) }
                    if let id = pull.threadID {
                        Button(pull.needsYou ? "Needs you · Open check" : "Open check") { desk.open(id, in: model) }
                            .buttonStyle(.link).deskFrame("sourcePullOpen")
                    }
                }.font(.callout)
            }
            if let started = desk.startedNote {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(started.continued ? "Continued" : "Started") in \(started.name)").lineLimit(1)
                    Button("Open") { Task { await desk.openWhenListed(started.chat, in: model) }; desk.startedNote = nil }
                        .buttonStyle(.link)
                    Button { desk.startedNote = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
                .font(.callout)
                .deskFrame("startedNote")
                .task(id: started.chat) { try? await Task.sleep(for: .seconds(8)); if desk.startedNote?.chat == started.chat { desk.startedNote = nil } }
            }
            // Silenced: a few seconds to take it back.
            if let silenced = desk.silencedNote {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.indigo)
                    Text("Silenced \(DeskText.context(title: silenced.waiting.title, place: silenced.waiting.place, subtitle: silenced.waiting.subtitle))").lineLimit(1)
                    Button("Undo") { Task { await desk.unsilence(silenced.waiting) } }
                        .buttonStyle(.link)
                        .deskFrame("undoSilence")
                    Button { desk.silencedNote = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
                .font(.callout)
                .deskFrame("silencedNote")
                .task(id: silenced.silenceKey) {
                    try? await Task.sleep(for: .seconds(8))
                    if desk.silencedNote?.silenceKey == silenced.silenceKey { desk.silencedNote = nil }
                }
            }
            if let problem = desk.problem {
                HStack(spacing: 6) {
                    Image(systemName: desk.unsupported ? "info.circle" : "exclamationmark.triangle")
                    Text(problem).lineLimit(2)
                    Button { desk.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
                .font(.caption).foregroundStyle(desk.unsupported ? Color.secondary : Color.orange)
            }
        }
    }

    private var askField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.bubble").foregroundStyle(Color.metadata)
            TextField("What needs doing?", text: $ask).textFieldStyle(.plain)
                .onSubmit(submit)
                .disabled(desk.adding)
                .accessibilityLabel("What needs doing?")
            if desk.adding {
                ProgressView().controlSize(.small)
            } else if !ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add to Desk", action: submit).controlSize(.small)
            }
        }
        .padding(9).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .help("Type what needs doing. The Desk suggests a Studio or project for it before anything starts.")
        .deskFrame("ask")
    }

    private func submit() {
        let text = ask
        Task { if await desk.add(text), ask == text { ask = "" } }
    }

    /// One column: its name and count, then its cards (or one quiet line), scrolling on its own.
    private func column(_ section: DeskSections.Section, _ sections: DeskSections) -> some View {
        let count = sections.count(section)
        let urgent = section == .needsYou && count > 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(section.rawValue).font(.headline).lineLimit(1)
                Text("\(count)").font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(urgent ? Color(nsColor: .windowBackgroundColor) : Color.metadata)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(urgent ? Color.attention : Color.primary.opacity(0.08)))
                    .deskFrame("count:" + section.key)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if count == 0 {
                        Text(section.empty).font(.callout).foregroundStyle(Color.metadata)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4).padding(.vertical, 6)
                            .deskFrame("empty:" + section.key)
                    }
                    cards(section, sections)
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
                .animation(.easeOut(duration: 0.2), value: ids(section, sections))
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: Self.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        .deskFrame("section:" + section.key)
    }

    @ViewBuilder private func cards(_ section: DeskSections.Section, _ sections: DeskSections) -> some View {
        switch section {
        case .todo: ForEach(sections.incoming) { DeskRequestRow(request: $0, desk: desk) }
        case .working: ForEach(sections.working) { DeskWorkingCard(item: $0, desk: desk) }
        case .needsYou:
            ForEach(sections.needsYou) { DeskNeedRow(need: $0, desk: desk) }
            if !sections.silenced.isEmpty { DeskSilencedRows(items: sections.silenced, desk: desk) }
        case .ready: ForEach(sections.ready) { DeskReadyRow(item: $0, desk: desk) }
        case .onHold: ForEach(sections.onHold) { DeskHeldRow(item: $0, desk: desk) }
        case .done: ForEach(sections.done) { DeskDoneRow(item: $0, desk: desk) }
        }
    }

    private func ids(_ section: DeskSections.Section, _ sections: DeskSections) -> [UUID] {
        switch section {
        case .todo: sections.incoming.map(\.id)
        case .working: sections.working.map(\.id)
        case .needsYou: sections.needsYou.map(\.id)
        case .ready: sections.ready.map(\.id)
        case .onHold: sections.onHold.map(\.id)
        case .done: sections.done.map(\.id)
        }
    }
}

/// A card on the board: a raised fill with a hairline, or the colour it's marked with.
private extension View {
    func deskCard(fill: Color = Color(nsColor: .controlBackgroundColor), stroke: Color = Color.primary.opacity(0.1), width: CGFloat = 1) -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stroke, lineWidth: width))
    }
}

// MARK: - Needs you

/// A session waiting on you. An approval or plan is the one approval card (ApprovalPanel):
/// Allow, Allow for Session or Deny right here. Questions and a reply that asks: Open. The bell
/// silences it (with Undo); the square opens its session.
private struct DeskNeedRow: View {
    @Environment(AppModel.self) private var model
    let need: DeskNeed
    let desk: DeskModel
    @State private var hovered = false

    private var waiting: Companion.DeskWaiting { need.waiting }
    private var context: String { DeskText.context(title: waiting.title, place: waiting.place, subtitle: waiting.subtitle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if need.canDecide {
                ApprovalPanel(context: context, ask: waiting.text, command: need.detail, isPlan: waiting.kind == "plan",
                              frame: { name, rect in
                                  #if DEBUG
                                  DeskDebug.frames["\(name):\(need.id)"] = rect
                                  #endif
                              }) { desk.decide(need, $0, in: model) }
            } else {
                Label(DeskText.label(kind: waiting.kind), systemImage: DeskText.icon(kind: waiting.kind))
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.attention)
                Text(context).font(.headline).lineLimit(2)
                Text(waiting.text).font(.callout).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open") { desk.open(waiting.chatID, in: model) }
                    .help(waiting.kind == "questions" ? "Answer in the session" : "Reply in the session")
                    .padding(.top, 4)
                    .deskFrame("open:\(need.id)")
            }
            DeskTaskLine(chatID: waiting.chatID, task: waiting.task, text: waiting.taskText, desk: desk)
            if waiting.autoStarted == true { DeskAutoStartedTag().deskFrame("auto:\(need.id)") }
            DeskSourceLine(id: waiting.task ?? waiting.chatID, origin: waiting.origin, check: waiting.check, matchLabel: "Mark complete",
                           match: { Task { await desk.completeChat(waiting.chatID) } },
                           writeBack: waiting.task.map { task in { Task { await desk.writeBack(task, in: model) } } })
        }
        .deskCard(fill: Color.attention.opacity(hovered ? 0.08 : 0.045), stroke: Color.attention.opacity(0.8), width: 1.5)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                if desk.canSilence { silenceButton }
                if need.canDecide {
                    Button { desk.open(waiting.chatID, in: model) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless).foregroundStyle(Color.metadata)
                        .help("Open the session").accessibilityLabel("Open \(waiting.title)")
                        .deskFrame("open:\(need.id)")
                }
            }
            .padding(12)
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open Session") { desk.open(waiting.chatID, in: model) }
            DeskTaskMenuItems(chatID: waiting.chatID, task: waiting.task, desk: desk)
            if desk.canSilence {
                Divider()
                Button("Silence", systemImage: "bell.slash") { Task { await desk.silence(need) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(context), \(DeskText.label(kind: waiting.kind)): \(waiting.text)")
        .accessibilityAction(named: "Silence") { Task { await desk.silence(need) } }
        .deskFrame("needs:\(need.id)")
    }

    /// Off the Desk without answering it; it shows again when something new waits.
    private var silenceButton: some View {
        Button { Task { await desk.silence(need) } } label: { Image(systemName: "bell.slash") }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.metadata)
            .help(need.canDecide
                  ? "Silence: take this off the Desk on every device without answering it. It stays waiting in the session."
                  : "Silence: take this off the Desk on every device. A new question from this session shows again.")
            .accessibilityLabel("Silence")
            .deskFrame("silence:\(need.id)")
    }
}

/// The foot of Needs you: what was silenced (on any device), folded into one quiet row ("2
/// silenced"); opened, each with Unsilence, which puts it back on the Desk everywhere.
private struct DeskSilencedRows: View {
    let items: [Companion.DeskWaiting]
    let desk: DeskModel
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                    Text("\(items.count) silenced")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.callout.weight(.medium)).foregroundStyle(Color.metadata)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Taken off the Desk, still waiting in their sessions")
            .accessibilityValue(open ? "Shown" : "Hidden")
            .deskFrame("silencedRow")
            if open {
                ForEach(items) { item in
                    Divider().padding(.leading, 12)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DeskText.context(title: item.title, place: item.place, subtitle: item.subtitle)).font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(DeskText.label(kind: item.kind)): \(item.text)").font(.caption).foregroundStyle(Color.metadata).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Unsilence") { Task { await desk.unsilence(item) } }
                            .controlSize(.small)
                            .help("Put it back on the Desk, on every device")
                            .deskFrame("unsilence:\(item.id)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .padding(.top, 4)
    }
}

/// A session's Studio or project, quietly.
private struct DeskPlaceLabel: View {
    let name: String
    var body: some View {
        Text(name).font(.caption.weight(.medium)).foregroundStyle(Color.metadata).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

// MARK: - To do

private struct DeskRequestRow: View {
    @Environment(AppModel.self) private var model
    let request: Companion.DeskRequest
    let desk: DeskModel
    @State private var choosing = false
    @State private var starting = false
    @State private var linking = false

    var body: some View {
        let place = desk.place(for: request)
        let busy = desk.busy.contains(request.id)
        VStack(alignment: .leading, spacing: 8) {
            Text(request.text).font(.body.weight(.medium)).lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(DeskText.origin(request)).font(.caption).foregroundStyle(Color.metadata)
            if let confidence = request.confidence { DeskConfidenceLine(confidence: confidence).deskFrame("confidence:\(request.id)") }
            if let note = request.note, !note.isEmpty {
                Label { Text(note) } icon: { Image(systemName: "text.quote") }
                    .font(.subheadline).foregroundStyle(Color.metadata).lineLimit(3)
            }
            // Mark done is already on the card: the warning is enough.
            DeskSourceLine(id: request.id, origin: request.origin, check: request.check,
                           writeBack: { Task { await desk.writeBack(request.id, in: model) } })
            Button { choosing = true } label: { DeskPlaceChip(place: place) }
                .buttonStyle(.plain)
                .help(place == nil ? "Nothing clearly fits: choose where this goes" : "Where it starts. Click to choose another place.")
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    DeskPlacePicker(request: request, desk: desk) { choosing = false }
                }
                .deskFrame("chip:\(request.id)")
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                // The place chip above changes the place; with none yet, Start asks for one first.
                Button(busy ? "Starting\u{2026}" : "Start") { if place == nil { choosing = true } else { starting = true } }
                    .buttonStyle(.accent)
                    .disabled(busy)
                    .help(place.map { "Start in \($0.name): choose the model, or continue a session already there" } ?? "Choose a place, then start")
                    .popover(isPresented: $starting, arrowEdge: .bottom) {
                        DeskStartPopover(step: DeskStartStep(request: request, desk: desk)) { starting = false }
                    }
                    .deskFrame("start:\(request.id)")
                if desk.hasTasks, let place {
                    Button("Link\u{2026}") { linking = true }
                        .disabled(busy)
                        .help("Link a thread already in \(place.name): this task is done there")
                        .popover(isPresented: $linking, arrowEdge: .bottom) {
                            DeskLinkPopover(request: request, place: place, desk: desk) { linking = false }
                        }
                        .deskFrame("link:\(request.id)")
                }
                Spacer(minLength: 0)
                Button("Mark done") { Task { await desk.markDone(request) } }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help("Done outside Chatterbox: move it to Done without starting a thread")
                    .deskFrame("markDone:\(request.id)")
                Button("Remove") { Task { await desk.ignore(request) } }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help("Take it off the Desk")
                    .deskFrame("ignore:\(request.id)")
            }
            .padding(.top, 2)
        }
        .deskCard()
        .accessibilityElement(children: .contain)
        .contextMenu {
            if desk.canHold {
                Button("Put on hold", systemImage: "pause.circle") { Task { await desk.hold(request.id) } }
            }
        }
        .accessibilityLabel("Request: \(request.text)")
        .deskFrame("request:\(request.id)")
    }
}

/// Where a request will start, or "Choose a place" when nothing clearly fits.
private struct DeskPlaceChip: View {
    let place: Companion.DeskPlace?
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: place.map(DeskText.icon(place:)) ?? "mappin.and.ellipse")
            Text(place?.name ?? "Choose a place").lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Color.metadata)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(place == nil ? Color.attention : Color.primary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(place == nil ? Color.attention.opacity(0.12) : Color.primary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(place == nil ? Color.attention.opacity(0.6) : Color.primary.opacity(0.14)))
        .contentShape(Capsule())
    }
}

/// Start's step, for one request: the model it runs on, and sessions already in its place
/// doing the same work (a clear match is chosen). The model shows the chosen session's own (or
/// a new session's, as New Chat would start one there) until one is picked here; continuing on
/// another switches that session to it. Tests drive it directly.
@MainActor
@Observable
final class DeskStartStep {
    let request: Companion.DeskRequest
    @ObservationIgnored let desk: DeskModel
    /// Sessions in the place like this work; nil while they load.
    private(set) var threads: [Companion.DeskThread]?
    /// The session to continue; nil: a new one. `choose` changes it.
    private(set) var continuing: UUID?
    /// The model shown: the choice's own, or with the picks made here; nil from an older service.
    private(set) var options: Companion.ChatOptions?
    /// The chosen session's own model (or a new session's), to tell a switch.
    private(set) var base: Companion.ChatOptions?
    /// Picked here by hand; then choosing another session keeps them.
    private(set) var picks = Companion.SettingsRequest()
    private(set) var loaded = false

    init(request: Companion.DeskRequest, desk: DeskModel) {
        self.request = request
        self.desk = desk
    }

    var place: Companion.DeskPlace? { desk.place(for: request) }
    var continued: Companion.DeskThread? { threads?.first { $0.id == continuing } }
    /// Starting new: in a project, a work thread of its session (plans/work-threads.md).
    var newTitle: String { place?.kind == "project" ? "New work thread for \(place?.name ?? "the project")" : "New session" }
    var newDetail: String {
        place?.kind == "project" ? "A fresh thread in \(place?.name ?? "the project"); its result goes back to the project's session"
            : "In \(place?.name ?? "this place")"
    }
    /// The provider in use: an open model's, or the agent's.
    var provider: String { options.map { $0.openModel != nil ? "open" : $0.backend } ?? "claude" }

    /// Picked here, and not what the chosen session (or a new one) runs on already.
    var switching: Bool {
        guard !picks.isEmpty, let options, let base else { return false }
        return !options.sameModel(as: base)
    }
    /// Continuing on another agent waits until the session's reply is done.
    var blocked: Bool {
        guard let continued, continued.isRunning, switching else { return false }
        return options?.backend != base?.backend
    }
    /// What Continue does: the session's next message, on its model or switched to the one picked.
    var continueNote: String? {
        guard let continued else { return nil }
        let said = "It goes to that session as its next message"
        guard switching else { return "\(said), on its own model (\(Self.chip(base) ?? continued.settings ?? "as it is"))." }
        if blocked { return "\(said). It's working now, so its agent can change only once it's done." }
        return "\(said), switching it to \(Self.chip(options) ?? "the model picked")."
    }

    /// The model as its chip reads: "Opus 5.5 · Medium" (with none chosen, the model's default).
    static func chip(_ options: Companion.ChatOptions?) -> String? {
        guard let options else { return nil }
        if let open = options.openModel { return "\(open) \u{00B7} PC" }
        guard let model = options.currentModel else { return nil }
        guard !model.efforts.isEmpty else { return model.name }
        let level = options.effort.isEmpty ? model.defaultEffort.map(EffortNames.label) ?? "Default effort" : EffortNames.label(options.effort)
        return "\(model.name) \u{00B7} \(level)"
    }

    /// The place's sessions like this work, and the model; picks start over.
    func load() async {
        guard let place else { return }
        picks = .init()
        let found = await desk.threads(for: request, in: place)
        threads = found
        continuing = found.first { $0.match == "clear" }?.id
        await follow()
        loaded = true
    }

    /// Continue in a session already there, or (nil) start a new one; the model follows the
    /// choice unless one was picked here.
    func choose(_ chat: UUID?) async {
        guard chat != continuing else { return }
        continuing = chat
        await follow()
    }

    private func follow() async {
        guard let place else { return }
        let target = continuing
        let own = await desk.options(in: place, picks: .init(), chat: target)
        // Chosen again meanwhile: that one's answer counts.
        guard target == continuing else { return }
        base = own
        if picks.isEmpty { options = own }
    }

    /// One change to the agent, model or effort, as New Chat takes it.
    func pick(_ change: Companion.SettingsRequest) async {
        guard let place else { return }
        picks.add(change, backend: options?.backend)
        if let fresh = await desk.options(in: place, picks: picks, chat: continuing) { options = fresh }
    }

    /// A model of `provider`'s ("claude", "codex" or "open"), as picking it would change things.
    func change(picking id: String, of provider: String) -> Companion.SettingsRequest {
        switch provider {
        case "open": .init(openModel: id)
        case options?.backend: .init(model: id)
        default: .init(backend: provider, model: id)
        }
    }

    func models(of provider: String) -> [Companion.ModelOption] {
        switch provider {
        case "open": options?.openModels ?? []
        case "codex": options?.codexModels ?? []
        default: options?.claudeModels ?? []
        }
    }

    func start() async {
        // Only what was picked: otherwise it starts as a new session there would, or the
        // session continues on its own model. Continuing, the session switches to it.
        var settings: Companion.SettingsRequest?
        if !picks.isEmpty, let options {
            let open = options.openModel
            settings = .init(backend: options.backend, model: open == nil ? options.model : nil, effort: open == nil ? options.effort : nil, openModel: open)
        }
        await desk.start(request, continuing: continued, settings: settings)
    }
}

/// Start: the place (Change picks another), the agent, model and effort, then "Continue in"
/// sessions already there doing the same work, or a new session. Start sends the choice.
struct DeskStartPopover: View {
    @State var step: DeskStartStep
    let done: () -> Void
    @State private var changingPlace = false
    /// Which provider's models the model menu lists; nil: the one in use.
    @State private var browsing: String?

    private var placeKey: String { step.place.map { "\($0.kind)|\($0.id?.uuidString ?? $0.name)" } ?? "" }

    var body: some View {
        Group {
            if changingPlace {
                DeskPlacePicker(request: step.request, desk: step.desk) { changingPlace = false }
            } else {
                content.frame(width: 400)
            }
        }
        .task(id: placeKey) { browsing = nil; await step.load() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start").font(.headline)
                Text(step.request.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if let place = step.place {
                HStack(spacing: 8) {
                    Image(systemName: DeskText.icon(place: place)).foregroundStyle(.secondary).frame(width: 18)
                    Text(place.name).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Change") { changingPlace = true }.controlSize(.small)
                        .deskFrame("startChange")
                }
            }
            modelChoice
            threadChoices
            if step.threads?.isEmpty != false, step.place?.kind == "project" {
                Label(step.newDetail, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = step.continueNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .deskFrame("startContinueNote")
            }
            HStack {
                if !step.loaded { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(step.continuing == nil ? "Start" : "Continue") {
                    let step = step
                    done()
                    Task { await step.start() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.accent)
                .disabled(!step.loaded || step.blocked)
                .deskFrame("startConfirm")
            }
        }
        .padding(14)
    }

    /// Continue in each session like this work, or a new session; nothing when there are none.
    @ViewBuilder private var threadChoices: some View {
        if let threads = step.threads, !threads.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Already in \(step.place?.name ?? "this place")").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(threads) { thread in
                    DeskStartChoice(title: "Continue in \(thread.title)",
                                    detail: [thread.task.map { "Its task \u{201C}\($0)\u{201D} goes back to To do" },
                                             thread.isRunning ? "Working now; it goes next" : nil, thread.settings].compactMap { $0 }.joined(separator: " \u{00B7} "),
                                    selected: step.continuing == thread.id) { Task { await step.choose(thread.id) } }
                        .deskFrame("thread:\(thread.id)")
                }
                DeskStartChoice(title: step.newTitle, detail: step.newDetail, selected: step.continuing == nil) { Task { await step.choose(nil) } }
                    .deskFrame("thread:new")
            }
        }
    }

    /// The provider, then its models in a menu, as the phone has them.
    @ViewBuilder private var modelChoice: some View {
        if let options = step.options {
            let shown = browsing ?? step.provider
            let models = step.models(of: shown)
            let current = shown == step.provider ? models.first { $0.id == (options.openModel ?? options.model) } : nil
            VStack(alignment: .leading, spacing: 6) {
                Picker("Agent", selection: Binding(get: { shown }, set: { browsing = $0 == step.provider ? nil : $0 })) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                    if options.openModels != nil { Text("Open models").tag("open") }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .deskFrame("startProvider")
                Picker("Model", selection: Binding(get: { current?.id }, set: { id in
                    guard let id else { return }
                    let change = step.change(picking: id, of: shown)
                    browsing = nil
                    Task { await step.pick(change) }
                })) {
                    if current == nil { Text("Choose a model").tag(String?.none) }
                    ForEach(models) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .disabled(models.isEmpty)
                .deskFrame("startModel")
                if let detail = current?.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                } else if current == nil, shown != step.provider {
                    Text("Picking one switches to \(shown == "open" ? "an open model" : shown == "codex" ? "Codex" : "Claude").").font(.caption).foregroundStyle(.secondary)
                }
                if shown == step.provider, options.openModel == nil, let model = current, !model.efforts.isEmpty {
                    Picker("Effort", selection: Binding(get: { options.effort.isEmpty ? model.defaultEffort ?? "" : options.effort }, set: { effort in
                        Task { await step.pick(.init(effort: effort)) }
                    })) {
                        ForEach(model.efforts, id: \.self) { Text(EffortNames.label($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .deskFrame("startEffort")
                }
            }
        }
    }
}

/// One choice in the start step: a radio-style row.
private struct DeskStartChoice: View {
    let title: String
    let detail: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The place chip's list: every Studio and project, with what belongs in each.
struct DeskPlacePicker: View {
    let request: Companion.DeskRequest
    let desk: DeskModel
    let done: () -> Void
    @State private var filter = ""

    var body: some View {
        let current = desk.place(for: request)
        let places = desk.placeOptions.filter { DeskText.matches($0, filter) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Where should this go?").font(.headline).padding(.horizontal, 14).padding(.top, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter places", text: $filter).textFieldStyle(.plain)
            }
            .padding(7).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)
            Divider()
            if desk.loadingPlaces && desk.places.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else if places.isEmpty {
                Text("No matching places").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(places, id: \.self) { place in
                            DeskPlaceOption(place: place, selected: place == current) {
                                desk.choose(place, for: request)
                                done()
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 380)
        .task { await desk.loadPlaces() }
    }
}

private struct DeskPlaceOption: View {
    let place: Companion.DeskPlace
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: DeskText.icon(place: place)).frame(width: 18).foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.body.weight(.medium)).lineLimit(1)
                    if let detail = DeskText.detailLine(place.detail) {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Tasks (plans/work-threads.md)

/// What a card's thread is doing, as its task says it, when that says more than its name.
private struct DeskTaskText: View {
    let text: String?
    let title: String
    let subtitle: String?
    var quiet = false

    var body: some View {
        if let text, ![title, subtitle].contains(where: { $0?.caseInsensitiveCompare(text) == .orderedSame }) {
            Label { Text(text).lineLimit(2) } icon: { Image(systemName: "checklist") }
                .font(quiet ? .caption : .subheadline).foregroundStyle(Color.metadata)
        }
    }
}

/// Under a Needs you card: its task, or that it isn't one, with Make this a task.
private struct DeskTaskLine: View {
    let chatID: UUID
    let task: UUID?
    let text: String?
    let desk: DeskModel

    var body: some View {
        if desk.hasTasks {
            HStack(spacing: 6) {
                if let text, task != nil {
                    Label { Text(text).lineLimit(1) } icon: { Image(systemName: "checklist") }
                        .font(.caption).foregroundStyle(Color.metadata)
                } else {
                    Text("Not a task").font(.caption).foregroundStyle(Color.metadata)
                    Button("Make this a task") { Task { await desk.makeTask(chatID) } }
                        .buttonStyle(.link).font(.caption)
                        .disabled(desk.tasking.contains(chatID))
                        .help("Put this thread on the board as a task, so it moves across it until you mark it complete")
                        .deskFrame("makeTask:\(chatID)")
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A card's menu: Unlink its task, or Make this a task.
private struct DeskTaskMenuItems: View {
    let chatID: UUID
    let task: UUID?
    let desk: DeskModel
    var canHoldHere = true

    var body: some View {
        if desk.hasTasks {
            if let task {
                if desk.canHold && canHoldHere {
                    Button("Put on hold", systemImage: "pause.circle") { Task { await desk.hold(task) } }
                }
                Button("Unlink Task", systemImage: "link.badge.plus") { Task { await desk.unlink(task) } }
            } else {
                Button("Make This a Task", systemImage: "checklist") { Task { await desk.makeTask(chatID) } }
            }
        }
    }
}

/// A To do card's Link: every thread already in its place, best matches first; picking one
/// links the task to it. One carrying another task asks first (that task goes back to To do).
struct DeskLinkPopover: View {
    let request: Companion.DeskRequest
    let place: Companion.DeskPlace
    let desk: DeskModel
    let done: () -> Void
    @State private var threads: [Companion.DeskThread]?
    /// A thread carrying another task, waiting for Link Anyway.
    @State private var confirming: Companion.DeskThread?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Link a thread").font(.headline)
                Text("In \(place.name). This task moves with the thread you pick.").font(.caption).foregroundStyle(.secondary)
            }
            if let threads {
                if threads.isEmpty {
                    Text("No threads in \(place.name) yet.").foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(threads) { thread in
                                DeskStartChoice(title: thread.title,
                                                detail: [thread.match == "clear" ? "Best match" : thread.match == "possible" ? "Similar work" : nil,
                                                         thread.task.map { "Has a task: \($0)" }, thread.isRunning ? "Working now" : nil]
                                                    .compactMap { $0 }.joined(separator: " \u{00B7} "),
                                                selected: confirming?.id == thread.id) { pick(thread) }
                                    .deskFrame("linkThread:\(thread.id)")
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(16)
            }
            if let confirming {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\u{201C}\(confirming.title)\u{201D} already carries a task\(confirming.task.map { ": \u{201C}\($0)\u{201D}" } ?? ""). Linking this one sends that back to To do.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { self.confirming = nil }
                        Button("Link Anyway") { link(confirming, replace: true) }.buttonStyle(.accent)
                            .deskFrame("linkAnyway")
                    }
                }
                .padding(8).background(Color.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .frame(width: 380)
        .task { threads = await desk.allThreads(for: request, in: place) }
    }

    private func pick(_ thread: Companion.DeskThread) {
        if thread.task != nil { confirming = thread } else { link(thread, replace: false) }
    }

    private func link(_ thread: Companion.DeskThread, replace: Bool) {
        Task {
            if await desk.link(request.id, to: thread.id, replace: replace) { done() } else { confirming = thread }
        }
    }
}

// MARK: - Working, Review, Done

/// A session working now: its name, place and what it's doing; a click opens it.
private struct DeskWorkingCard: View {
    @Environment(AppModel.self) private var model
    let item: Companion.DeskWorking
    let desk: DeskModel
    private let appearance = ReaderStyleSettings()
    @State private var hovered = false

    var body: some View {
        let session = model.sessions.first { $0.id == item.id }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ActivitySpinner(color: session.map { appearance.style.color(for: $0) } ?? .blue)
                    .frame(width: 10, height: 10)
                Text(item.since.map { "Working · \(DeskText.ago($0))" } ?? "Working").font(.caption.weight(.semibold)).foregroundStyle(Color.metadata)
                if let place = item.place, place != item.title { DeskPlaceLabel(name: place) }
                Spacer(minLength: 0)
            }
            Text(item.title).font(.headline).lineLimit(2)
            if let subtitle = item.subtitle { Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(2) }
            DeskTaskText(text: item.taskText, title: item.title, subtitle: item.subtitle)
            if let activity = item.activity, !activity.isEmpty {
                Text(activity).font(.subheadline).foregroundStyle(Color.metadata).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.autoStarted == true { DeskAutoStartedTag().deskFrame("auto:\(item.id)") }
            // Working can't be completed mid-reply: only the write-back.
            DeskSourceLine(id: item.task ?? item.id, origin: item.origin, check: item.check,
                           writeBack: item.task.map { task in { Task { await desk.writeBack(task, in: model) } } })
            Button("Open") { desk.openWorking(item.id, in: model) }
                .padding(.top, 4)
                .deskFrame("workingOpen:\(item.id)")
        }
        .deskCard(fill: Color(nsColor: .controlBackgroundColor).opacity(hovered ? 0.8 : 1))
        .contentShape(Rectangle())
        .onTapGesture { desk.openWorking(item.id, in: model) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open Session") { desk.openWorking(item.id, in: model) }
            DeskTaskMenuItems(chatID: item.id, task: item.task, desk: desk, canHoldHere: false)
        }
        .help("\(item.title)\(item.subtitle.map { " · " + $0 } ?? "")\(item.place.flatMap { $0 != item.title ? " · " + $0 : nil } ?? "") is working. Click to open it.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), working\(item.activity.map { ": " + $0 } ?? "")")
        .deskFrame("working:\(item.id)")
    }
}

/// A session that finished and asks nothing: Mark complete archives it into Done; the bell
/// (or right-click) silences it until something new happens in it.
private struct DeskReadyRow: View {
    @Environment(AppModel.self) private var model
    let item: Companion.DeskReady
    let desk: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("Finished \(DeskText.ago(item.finishedAt))").font(.caption.weight(.semibold)).foregroundStyle(Color.metadata).lineLimit(1)
                if let place = item.place, place != item.title { DeskPlaceLabel(name: place) }
                Spacer(minLength: 4)
                if desk.canSilence {
                    Button { Task { await desk.silence(item) } } label: { Image(systemName: "bell.slash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.metadata)
                        .help("Silence: take this off the Desk on every device until something new happens in the session.")
                        .accessibilityLabel("Silence")
                        .deskFrame("readySilence:\(item.id)")
                }
            }
            Text(item.title).font(.headline).lineLimit(2)
            if let subtitle = item.subtitle { Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(2) }
            DeskTaskText(text: item.taskText, title: item.title, subtitle: item.subtitle)
            Text(item.text).font(.subheadline).foregroundStyle(Color.metadata).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let assets = item.assets, !assets.isEmpty { DeskAssetLinks(assets: assets) }
            if item.autoStarted == true { DeskAutoStartedTag().deskFrame("auto:\(item.id)") }
            // Mark complete is already on the card.
            DeskSourceLine(id: item.task ?? item.id, origin: item.origin, check: item.check,
                           writeBack: item.task.map { task in { Task { await desk.writeBack(task, in: model) } } })
            HStack(spacing: 8) {
                Button("Mark complete") { Task { await desk.complete(item) } }
                    .buttonStyle(.accent)
                    .disabled(!desk.canSilence)
                    .help("Archive the session, completing its task. It shows in Done for a week, where Reopen brings it back.")
                    .deskFrame("complete:\(item.id)")
                Button("Open") { desk.open(item.id, in: model) }
                    .deskFrame("readyOpen:\(item.id)")
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .deskCard()
        .contextMenu {
            Button("Open Session") { desk.open(item.id, in: model) }
            if desk.canSilence {
                Button("Mark Complete", systemImage: "checkmark.circle") { Task { await desk.complete(item) } }
                DeskTaskMenuItems(chatID: item.id, task: item.task, desk: desk)
                Divider()
                Button("Silence", systemImage: "bell.slash") { Task { await desk.silence(item) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), finished: \(item.text)")
        .accessibilityAction(named: "Mark Complete") { Task { await desk.complete(item) } }
        .deskFrame("ready:\(item.id)")
    }
}

/// A session marked complete this week (archived): Reopen brings it back.
private struct DeskDoneRow: View {
    @Environment(AppModel.self) private var model
    let item: Companion.DeskDone
    let desk: DeskModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Completed \(DeskText.ago(item.completedAt))").lineLimit(1)
                }
                .font(.caption.weight(.medium)).foregroundStyle(Color.metadata)
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.metadata).lineLimit(2)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.metadata).lineLimit(1) }
                DeskTaskText(text: item.taskText, title: item.title, subtitle: item.subtitle, quiet: true)
                if let place = item.place, place != item.title { DeskPlaceLabel(name: place).padding(.top, 2) }
                if item.autoStarted == true { DeskAutoStartedTag() }
                DeskSourceLine(id: item.task ?? item.id, origin: item.origin, check: item.check,
                               writeBack: item.task.map { task in { Task { await desk.writeBack(task, in: model) } } })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reopen") { Task { await desk.reopen(item) } }
                .controlSize(.small)
                .disabled(!desk.canSilence || desk.reopening.contains(item.id))
                .help("Unarchive the session and reopen its task")
                .deskFrame("reopen:\(item.id)")
        }
        .deskCard(fill: Color.primary.opacity(0.03), stroke: Color.primary.opacity(0.07))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), completed")
        .deskFrame("done:\(item.id)")
    }
}


/// What a finished thread made or points to, under its Review card: files and images open in
/// their app (Quick Look-able), links in the browser.
private struct DeskAssetLinks: View {
    let assets: [Companion.DeskAsset]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(assets, id: \.self) { asset in
                Button { open(asset) } label: {
                    Label(asset.title, systemImage: asset.kind == "image" ? "photo" : asset.kind == "link" ? "link" : "doc")
                        .font(.subheadline).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help(asset.path ?? asset.url ?? "")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What it made")
    }

    private func open(_ asset: Companion.DeskAsset) {
        if let path = asset.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else if let link = asset.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
    }
}

/// Where a task came from (plans/source-linked-tasks.md): a ClickUp or email badge (a click opens
/// it), and in amber what disagrees with the board, with the offers: the change in the source
/// (an agent makes it; nothing changes there without this tap) and moving the task to match.
private struct DeskSourceLine: View {
    let id: UUID
    let origin: Companion.DeskOrigin?
    let check: Companion.DeskOriginCheck?
    var matchLabel: String? = nil
    var match: (() -> Void)? = nil
    var writeBack: (() -> Void)? = nil

    var body: some View {
        if let origin {
            VStack(alignment: .leading, spacing: 6) {
                Button { origin.url.flatMap(URL.init(string:)).map { _ = NSWorkspace.shared.open($0) } } label: {
                    Label(DeskSourceText.badge(origin), systemImage: origin.kind == "email" ? "envelope" : "checklist")
                        .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.metadata)
                .disabled(origin.url == nil)
                .help(DeskSourceText.help(origin))
                .deskFrame("source:\(id)")
                if let check {
                    Label(check.warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Color.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .deskFrame("sourceWarning:\(id)")
                    HStack(spacing: 8) {
                        if let offer = check.writeBack, let writeBack {
                            Button(offer, action: writeBack)
                                .controlSize(.small)
                                .help("Asks an agent to do this with its connector. Nothing changes in \(origin.kind == "email" ? "your email" : "ClickUp") until it does; an email is only drafted.")
                                .deskFrame("writeBack:\(id)")
                        }
                        if check.match == "done", let match, let matchLabel {
                            Button(matchLabel, action: match)
                                .controlSize(.small)
                                .help("Move it to Done here, to match its source")
                                .deskFrame("match:\(id)")
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

enum DeskSourceText {
    /// "ClickUp · In progress · Camp schedule", "Email · New reply from Lauren".
    static func badge(_ origin: Companion.DeskOrigin) -> String {
        var parts = [origin.kind == "email" ? "Email" : "ClickUp"]
        if let status = origin.status, !status.isEmpty {
            let shown = status.prefix(1).uppercased() + status.dropFirst()
            parts.append(origin.kind == "email" && status.lowercased() == "new reply" ? shown + (origin.replyFrom.map { " from " + $0 } ?? "") : shown)
        }
        if let title = origin.title, !title.isEmpty { parts.append(title) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func help(_ origin: Companion.DeskOrigin) -> String {
        let checked = origin.checkedAt.map { " Checked \($0.formatted(.relative(presentation: .named)))." } ?? " Not checked yet."
        return (origin.url.map { "Open \($0)." } ?? "\(origin.kind == "email" ? "Message" : "Task") id \(origin.id).") + checked
    }
}

/// The rubric's answer on a To do card (plans/desk-confidence.md): Yes, an agent can finish it
/// without you (it starts by itself), or what needs you.
private struct DeskConfidenceLine: View {
    let confidence: Companion.DeskConfidence

    var body: some View {
        Label {
            Text(confidence.canRunAlone ? "Can run without you" : "Needs you").fontWeight(.semibold)
                + Text(" \u{00B7} " + confidence.reason)
        } icon: {
            Image(systemName: confidence.canRunAlone ? "checkmark.seal.fill" : "person.fill.questionmark")
                .foregroundStyle(confidence.canRunAlone ? Color.green : Color.attention)
        }
        .font(.subheadline)
        .foregroundStyle(Color.metadata)
        .fixedSize(horizontal: false, vertical: true)
        .help(confidence.canRunAlone
              ? "Scored Yes\(confidence.by.map { " by \($0)" } ?? ""): it starts by itself when it has a place (Settings \u{2192} Background service)."
              : "Scored No\(confidence.by.map { " by \($0)" } ?? ""): it waits for you.")
    }
}

/// On a card whose task started by itself because it scored Yes.
private struct DeskAutoStartedTag: View {
    var body: some View {
        Label("Started automatically", systemImage: "bolt.fill")
            .font(.caption.weight(.medium)).foregroundStyle(Color.metadata)
            .help("Its task was scored able to run without you, so it started by itself. Open it to check on it or stop it.")
    }
}

/// A held task keeps its conversation and finished work; Resume restores its derived lane.
private struct DeskHeldRow: View {
    @Environment(AppModel.self) private var model
    let item: Companion.DeskHeld
    let desk: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("On hold", systemImage: "pause.circle").font(.caption).foregroundStyle(Color.metadata)
                Spacer(minLength: 4)
                if let place = item.place { DeskPlaceLabel(name: place) }
            }
            Text(item.text).font(.headline).lineLimit(3)
            Text("Held " + DeskText.ago(item.heldAt)).font(.caption).foregroundStyle(Color.metadata)
            if let note = item.note { Text(note).font(.callout).foregroundStyle(Color.metadata).lineLimit(3) }
            HStack {
                Button("Resume") { Task { await desk.hold(item.id, resume: true) } }
                    .deskFrame("resume:\(item.id)")
                if let chat = item.chatID {
                    Button("Open") { desk.open(chat, in: model) }.deskFrame("heldOpen:\(item.id)")
                }
            }
        }
        .deskCard()
        .disabled(desk.busy.contains(item.id))
        .accessibilityElement(children: .contain)
        .deskFrame("held:\(item.id)")
    }
}
