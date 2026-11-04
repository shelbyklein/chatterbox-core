import AppKit
import Observation
import SwiftUI

// The Desk on the Mac: what needs you, incoming work to place, what is working. plans/front-desk.md
//
// Home's first page: Desk at the top of its left column, the toolbar's Desk button, and
// Go > Desk (⌘0). Needs you and Working come from the sessions this Mac already has (the same
// pending approvals, plans and questions their cards show), so Approve here is the chat's own
// Approve. Requests waiting to be placed, the places they can go, replies that ask you
// something, and what was silenced come from the background service: socket operation "desk"
// (action get, add, start, ignore, silence or places, with the HTTP API's bodies and replies),
// which sends "desk.changed" when they change.

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

/// What the Desk shows, in order. A section with nothing in it takes no space.
struct DeskSections: Equatable {
    enum Section: String, CaseIterable { case needsYou = "Needs you", incoming = "Incoming", working = "Working" }

    var needsYou: [DeskNeed] = []
    var incoming: [Companion.DeskRequest] = []
    var working: [Companion.DeskWorking] = []

    var visible: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .needsYou: return !needsYou.isEmpty
            case .incoming: return !incoming.isEmpty
            case .working: return !working.isEmpty
            }
        }
    }
    /// Nothing waits on you and nothing waits to be placed: "Nothing else needs you."
    var isCalm: Bool { needsYou.isEmpty && incoming.isEmpty }
    var summary: String { Self.summary(needsYou: needsYou.count, incoming: incoming.count, working: working.count) }
    /// What needs acting on: the toolbar's Desk badge.
    var actionCount: Int { needsYou.count + incoming.count }

    /// The header's line: "2 need you · 1 incoming · 3 working".
    static func summary(needsYou: Int, incoming: Int, working: Int) -> String {
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if incoming > 0 { parts.append("\(incoming) incoming") }
        if working > 0 { parts.append("\(working) working") }
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
    /// A place chosen with Change place, by request, until it starts.
    private(set) var chosen: [UUID: Companion.DeskPlace] = [:]
    /// Requests being started or ignored.
    private(set) var busy: Set<UUID> = []
    /// Waiting things being silenced here (DeskNeed.silenceKey), hidden until the service answers.
    private(set) var silencing: Set<String> = []
    private(set) var adding = false
    /// What last went wrong, shown under the header.
    var problem: String?
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

    /// Needs you and Working from this Mac's sessions; Incoming, replies that ask you
    /// something, and what was silenced, from the service's Desk. As the service has it for the
    /// phone: a session's oldest request not silenced, newest sessions first; Needs you wins
    /// over Working, and a session waiting only on what was silenced is in neither.
    func sections(in model: AppModel, now: Date = Date()) -> DeskSections {
        let sessions = model.activeSessions
        var needs: [(date: Date, need: DeskNeed)] = []
        var waiting = Set<UUID>()
        // Silenced on any device: the service keeps them (its replies already leave them out).
        let silenced = Set((snapshot?.silenced ?? []).filter { $0.kind != "reply" }.map(\.id))
        for session in sessions {
            let pending = session.pendingRequests
            guard !pending.isEmpty else { continue }
            waiting.insert(session.id)
            // One answered here hides while the session catches up; the next one shows.
            if let item = pending.first(where: { item in
                !recentlyAnswered(item.id, now: now) && !silenced.contains(item.id)
                    && !silencing.contains(DeskNeed.silenceKey(chatID: session.id, id: item.id))
            }) {
                needs.append((item.timestamp ?? session.record.updatedAt, Self.need(item, in: session, model: model)))
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
                waiting.insert(session.id)
                let need = DeskNeed(waiting: reply)
                guard !silencing.contains(need.silenceKey) else { continue }
                needs.append((session.lastActivity, need))
            }
        }
        needs.sort { $0.date == $1.date ? $0.need.id.uuidString < $1.need.id.uuidString : $0.date > $1.date }
        let working = Attention.shared.workingChats(in: model).filter { !waiting.contains($0.id) }.map { session in
            let name = CompanionMapper.heading(session)
            return Companion.DeskWorking(id: session.id, title: name.title, place: Self.placeName(of: session, in: model), subtitle: name.subtitle)
        }
        return DeskSections(needsYou: needs.map(\.need), incoming: snapshot?.incoming ?? [], working: working)
    }

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

    /// Silence can reach the service (a test's transport, or the background service).
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
        } catch let error where error.localizedDescription.contains("unsupported_operation") {
            // The rest of the Desk still works with an older service.
            problem = "Silence works once the background service restarts with this version of Chatterbox."
        } catch { note(error, "silence it") }
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

    /// Start there: the service starts a session in the place shown (its first message is the
    /// request's text) and this opens it.
    func start(_ request: Companion.DeskRequest, in model: AppModel) async {
        guard let place = place(for: request), !busy.contains(request.id) else { return }
        busy.insert(request.id)
        defer { busy.remove(request.id) }
        var body: [String: JSON] = ["action": "start", "id": .string(request.id.uuidString)]
        // The place you saw, proposed or chosen, goes with it.
        if let value = try? JSON.value(place) { body["place"] = value }
        do {
            let result = try await send(body, timeout: .seconds(60))
            problem = nil
            chosen[request.id] = nil
            if var desk = snapshot { desk.incoming.removeAll { $0.id == request.id }; snapshot = desk }
            refresh()
            if let id = Self.startedSessionID(result) { await openWhenListed(id, in: model) }
        } catch { note(error, "start it") }
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
        case "questions": "questionmark.bubble"
        case "reply": "text.bubble"
        default: "hand.raised"
        }
    }

    static func label(kind: String) -> String {
        switch kind {
        case "plan": "Plan"
        case "questions": "Question"
        case "reply": "Asked you"
        default: "Approval"
        }
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

struct DeskView: View {
    @Environment(AppModel.self) private var model
    var desk: DeskModel = .shared
    @State private var ask = ""
    /// The page's width, for two columns when it's wide.
    @State private var width: CGFloat = 0

    /// Two columns of cards once the content area is wider than this; one readable column below.
    static let twoColumnWidth: CGFloat = 1100
    static func columns(for width: CGFloat) -> Int { width - 56 > twoColumnWidth ? 2 : 1 }

    var body: some View {
        let sections = desk.sections(in: model)
        let columns = Self.columns(for: width)
        VStack(spacing: 0) {
            header(sections).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !sections.needsYou.isEmpty {
                        section("Needs you", "\(sections.needsYou.count) waiting", key: "needsYou", columns: columns) {
                            ForEach(sections.needsYou) { DeskNeedRow(need: $0, desk: desk, fill: columns > 1) }
                        }
                    }
                    if !sections.incoming.isEmpty {
                        section("Incoming", "\(sections.incoming.count) to place", key: "incoming", columns: columns) {
                            ForEach(sections.incoming) { DeskRequestRow(request: $0, desk: desk, fill: columns > 1) }
                        }
                    }
                    if sections.isCalm { calm }
                    if !sections.working.isEmpty { DeskWorkingLine(working: sections.working, desk: desk) }
                }
                .frame(maxWidth: columns > 1 ? 1480 : 920, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: sections.needsYou.map(\.id))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .onAppear { desk.appeared() }
        .onDisappear { desk.disappeared() }
        .accessibilityLabel("Desk, \(sections.summary)")
    }

    private func header(_ sections: DeskSections) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Desk").font(.largeTitle.weight(.bold)).lineLimit(1)
                Text(sections.summary).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    .deskFrame("summary")
                Spacer()
            }
            askField
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
            Image(systemName: "plus.bubble").foregroundStyle(.secondary)
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

    private func section<Content: View>(_ title: String, _ detail: String, key: String, columns: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            if columns > 1 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
                          alignment: .leading, spacing: 10) { content() }
            } else {
                VStack(alignment: .leading, spacing: 10) { content() }
            }
        }
        .deskFrame("section:" + key)
    }

    /// A healthy Desk takes little room.
    private var calm: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.title2.weight(.light))
            Text("Nothing else needs you.").font(.title3)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .deskFrame("calm")
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Needs you

private struct DeskNeedRow: View {
    @Environment(AppModel.self) private var model
    let need: DeskNeed
    let desk: DeskModel
    /// In two columns: as tall as its row.
    var fill = false
    @State private var hovered = false

    private var waiting: Companion.DeskWaiting { need.waiting }
    private var isPlan: Bool { waiting.kind == "plan" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: DeskText.icon(kind: waiting.kind))
                .font(.title3).foregroundStyle(.orange).frame(width: 24).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(waiting.title).font(.headline).lineLimit(1)
                    if let place = waiting.place, place != waiting.title { DeskPlaceLabel(name: place) }
                    Text(DeskText.label(kind: waiting.kind)).font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                // A project's session: its own title under the project's name.
                if let subtitle = waiting.subtitle {
                    Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(1)
                        .deskFrame("subtitle:\(need.id)")
                }
                Text(waiting.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = need.detail {
                    Text(detail).font(.system(.caption, design: .monospaced)).lineLimit(2)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                }
            }
            actions
        }
        .padding(14)
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(hovered ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.75), lineWidth: 1.5))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open Session") { desk.open(waiting.chatID, in: model) }
            if desk.canSilence {
                Divider()
                Button("Silence", systemImage: "bell.slash") { Task { await desk.silence(need) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(waiting.title)\(waiting.subtitle.map { ", " + $0 } ?? ""), \(DeskText.label(kind: waiting.kind)): \(waiting.text)")
        .accessibilityAction(named: "Silence") { Task { await desk.silence(need) } }
        .deskFrame("needs:\(need.id)")
    }

    /// Off the Desk without answering it; it shows again when something new waits.
    private var silenceButton: some View {
        Button { Task { await desk.silence(need) } } label: { Image(systemName: "bell.slash") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(need.canDecide
                  ? "Silence: take this off the Desk on every device without answering it. It stays waiting in the session."
                  : "Silence: take this off the Desk on every device. A new question from this session shows again.")
            .accessibilityLabel("Silence")
            .deskFrame("silence:\(need.id)")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if need.canDecide {
                Button("Approve") { desk.decide(need, .approved, in: model) }
                    .buttonStyle(.borderedProminent)
                    .help(isPlan ? "Start building, asking before edits (the plan card's Start Building)" : "Allow it this once")
                    .deskFrame("approve:\(need.id)")
                Button("Deny") { desk.decide(need, .denied, in: model) }
                    .help(isPlan ? "Keep planning" : "Don't allow it")
                    .deskFrame("deny:\(need.id)")
                Button { desk.open(waiting.chatID, in: model) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless).help("Open the session").accessibilityLabel("Open \(waiting.title)")
                    .deskFrame("open:\(need.id)")
            } else {
                Button("Open") { desk.open(waiting.chatID, in: model) }
                    .help(waiting.kind == "questions" ? "Answer in the session" : "Reply in the session")
                    .deskFrame("open:\(need.id)")
            }
            if desk.canSilence { silenceButton }
        }
        .fixedSize()
    }
}

/// A session's Studio or project, quietly.
private struct DeskPlaceLabel: View {
    let name: String
    var body: some View {
        Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

// MARK: - Incoming

private struct DeskRequestRow: View {
    @Environment(AppModel.self) private var model
    let request: Companion.DeskRequest
    let desk: DeskModel
    /// In two columns: as tall as its row.
    var fill = false
    @State private var choosing = false

    var body: some View {
        let place = desk.place(for: request)
        let busy = desk.busy.contains(request.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(request.text).font(.body.weight(.medium)).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Text(DeskText.origin(request)).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            if let note = request.note, !note.isEmpty {
                Label { Text(note) } icon: { Image(systemName: "text.quote") }
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                Button { choosing = true } label: { DeskPlaceChip(place: place) }
                    .buttonStyle(.plain)
                    .help(place == nil ? "Nothing clearly fits: choose where this goes" : "Where it starts. Click to choose another place.")
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        DeskPlacePicker(request: request, desk: desk) { choosing = false }
                    }
                    .deskFrame("chip:\(request.id)")
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? "Starting\u{2026}" : "Start there") { Task { await desk.start(request, in: model) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(place == nil || busy)
                    .help(place.map { "Start a session in \($0.name) with this as its first message" } ?? "Choose a place first")
                    .deskFrame("start:\(request.id)")
                if place != nil {
                    Button("Change place") { choosing = true }
                        .disabled(busy)
                        .deskFrame("change:\(request.id)")
                }
                Button("Ignore") { Task { await desk.ignore(request) } }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help("Take it off the Desk")
                    .deskFrame("ignore:\(request.id)")
            }
        }
        .padding(14)
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .contain)
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
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(place == nil ? Color.orange : Color.primary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(place == nil ? Color.orange.opacity(0.12) : Color.primary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(place == nil ? Color.orange.opacity(0.5) : Color.primary.opacity(0.14)))
        .contentShape(Capsule())
    }
}

/// Change place: every Studio and project, with what belongs in each.
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

// MARK: - Working

/// One quiet line of what's working; a click opens it.
private struct DeskWorkingLine: View {
    @Environment(AppModel.self) private var model
    let working: [Companion.DeskWorking]
    let desk: DeskModel
    private let appearance = ReaderStyleSettings()

    var body: some View {
        HStack(spacing: 10) {
            Text("Working").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(working) { item in chip(item) }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
        }
        .deskFrame("section:working")
    }

    private func chip(_ item: Companion.DeskWorking) -> some View {
        let session = model.sessions.first { $0.id == item.id }
        return Button { desk.openWorking(item.id, in: model) } label: {
            HStack(spacing: 6) {
                ActivitySpinner(color: session.map { appearance.style.color(for: $0) } ?? .blue)
                    .frame(width: 10, height: 10)
                Text(item.title).lineLimit(1)
                if let place = item.place, place != item.title {
                    Text(place).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(item.title)\(item.subtitle.map { " · " + $0 } ?? "")\(item.place.flatMap { $0 != item.title ? " · " + $0 : nil } ?? "") is working. Click to open it.")
        .deskFrame("working:\(item.id)")
    }
}
