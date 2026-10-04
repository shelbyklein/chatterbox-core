import Foundation
import Darwin

/// A lock covers the entire writer lifetime, not just each individual JSON write.
final class RuntimeOwnership {
    private let fd: Int32
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fd = open(root.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw RuntimeFailure("Cannot open conversation ownership lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw RuntimeFailure("Conversation storage already has an active writer") }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
struct RuntimeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RuntimeEvent: Codable {
    var sequence: Int
    var chatID: UUID?
    var revision: Int
    var kind: String
    var date: Date = Date()
    var payload:JSON? = nil
}
struct RuntimeChatState: Codable {
    var record: ConversationRecord
    var running: Bool
    var revision: Int
    var draft: RuntimeDraft? = nil
    var totalCount: Int? = nil
    var pendingItems:[DisplayItem]? = nil
}
struct RuntimeState: Codable {
    var schema = 1
    var sequence = 0
    var events: [RuntimeEvent] = []
    var commands: [String: CommandReceipt] = [:]
    var revisions: [String:Int] = [:]
    var draftByChat: [String: RuntimeDraft] = [:]
    var assistantNotes: [JSON]? = []
    var integrationEnabled = true
}
struct RuntimeDraft: Codable { var text: String; var attachments: [Attachment] }
struct CommandReceipt: Codable {
    var operation: String
    var fingerprint: String
    var result: JSON?
    var state: String
    var date = Date()
}

/// The provider bridges are the same ChatSession code used by the legacy UI.
/// Only this owner saves records and acknowledges provider replay offsets.
@MainActor final class ConversationRuntime {
    private(set) var sessions: [ChatSession] = []
    private(set) var studios: [Studio] = []
    private(set) var state: RuntimeState
    var onEvent: ((RuntimeEvent) -> Void)?
    private let ownership: RuntimeOwnership
    private let root: URL
    private var dirty: Set<UUID> = []
    private var saveScheduled = false
    private var wasRunning: [UUID:Bool] = [:]
    private var pendingCards: Set<UUID> = []
    private let encoder: JSONEncoder = { let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;return e }()
    private let decoder: JSONDecoder = { let d=JSONDecoder();d.dateDecodingStrategy = .iso8601;return d }()

    init(root: URL = RuntimePaths.data) throws {
        self.root = root
        ownership = try RuntimeOwnership(root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Conversations"), withIntermediateDirectories: true)
        let stateFile = root.appendingPathComponent("runtime-state.json")
        if FileManager.default.fileExists(atPath: stateFile.path) {
            state = try decoder.decode(RuntimeState.self, from: Data(contentsOf: stateFile))
            guard state.schema == 1 else { throw RuntimeFailure("Unsupported runtime storage version") }
        } else { state = RuntimeState() }
        // A receipt interrupted around dispatch must remain explicit, never be sent twice.
        for key in state.commands.keys where state.commands[key]?.state == "dispatching" {
            state.commands[key]?.state = "delivery_uncertain"
        }
        let folder=root.appendingPathComponent("Conversations")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let record = try decoder.decode(ConversationRecord.self, from: Data(contentsOf: file))
            let session=ChatSession(record: record)
            session.awaitingHostResume=session.hasHostLinks
            if let draft=state.draftByChat[session.id.uuidString] { session.draft=draft.text;session.draftAttachments=draft.attachments }
            sessions.append(session)
        }
        sessions.sort { $0.record.updatedAt > $1.record.updatedAt }
        studios = (try? Data(contentsOf: root.appendingPathComponent("Studios.json"))).flatMap { try? decoder.decode([Studio].self,from:$0) } ?? []
        ChatSession.studioLookup = { [weak self] id in self?.studios.first { $0.id == id } }
        for session in sessions { attach(session);wasRunning[session.id]=session.isRunning;pendingCards.formUnion(session.items.filter { $0.approvalState == .pending }.map(\.id)) }
        try encoder.encode(["schema":1,"owner":"chatterboxd"] as JSON).write(to: root.appendingPathComponent("runtime-owner.json"), options: .atomic)
        try persistState()
    }
    func resume() async {
        let processes = (try? await HostClient.shared.list()) ?? []
        for session in sessions {
            if session.awaitingHostResume { session.resumeFromHost(processes) }
            else { session.settleInterruptedWork() }
        }
        CodexAppServer.shared.resume(processes)
        try? flush()
    }
    func session(_ id: UUID) -> ChatSession? { sessions.first { $0.id == id } }
    var assistant: ChatSession? { sessions.first { $0.isDot } }
    @discardableResult func ensureAssistant() throws -> ChatSession {
        if let assistant { return assistant }
        var r=ConversationRecord(model:"default",effort:"",personality:.friendly)
        r.title="Golem";r.isDot=true
        let d=AppPreferences.defaults
        if d.string(forKey:"dotDefaultBackend") == Backend.codex.rawValue {
            r.activeBackend = .codex
            r.codex=CodexSettings(model:d.string(forKey:"dotDefaultModel") ?? "gpt-6.1-sol",folder:RuntimePaths.assistantFolder,canEdit:false,mode:PermissionModes.defaultCodex)
        }
        return try insert(r)
    }
    @discardableResult func insert(_ record: ConversationRecord) throws -> ChatSession {
        guard session(record.id) == nil else { throw RuntimeFailure("Conversation already exists") }
        let s=ChatSession(record:record);sessions.insert(s,at:0);attach(s)
        dirty.insert(s.id);publish(s,kind:"chat.created");try flush();return s
    }
    func remove(_ id: UUID) throws {
        guard let s=session(id) else { throw RuntimeFailure("Conversation not found") }
        s.shutdown();sessions.removeAll { $0.id == id };dirty.remove(id)
        // Retain attachments: deletion can otherwise destroy files used by forks or a retry.
        try FileManager.default.removeItem(at: file(id))
        publish(s,kind:"chat.deleted");try persistState()
    }
    func updateDraft(_ s: ChatSession, text: String, attachments: [Attachment]) throws {
        s.draft=text;s.draftAttachments=attachments
        state.draftByChat[s.id.uuidString]=RuntimeDraft(text:text,attachments:attachments)
        publish(s,kind:"draft.changed");try persistState()
    }
    func snapshots() -> [RuntimeChatState] {
        sessions.map { s in
            var record=s.record;record.items=Array(record.items.suffix(40))
            return RuntimeChatState(record:record,running:s.isRunning,revision:state.revisions[s.id.uuidString] ?? 0,draft:RuntimeDraft(text:s.draft,attachments:s.draftAttachments),totalCount:s.items.count,pendingItems:s.items.filter{$0.approvalState == .pending})
        }
    }
    func events(after cursor: Int) -> (resync: Bool, events: [RuntimeEvent]) {
        let oldest=state.events.first?.sequence ?? state.sequence
        return (cursor < oldest-1 || cursor > state.sequence, state.events.filter { $0.sequence > cursor })
    }
    func flush() throws {
        for id in dirty {
            guard let session=session(id) else { continue }
            session.prepareForSave()
            try encoder.encode(session.record).write(to:file(id),options:.atomic)
            if let link=session.record.claudeHost, HostClient.shared.isConnected { HostClient.shared.ack(id:link.processID,offset:link.offset) }
        }
        dirty.removeAll()
        if CodexAppServer.shared.isRunning { CodexAppServer.shared.saveResumeState() }
        try persistState()
    }
    func execute(id: String, operation: String, fingerprint: String, body: () throws -> JSON) throws -> JSON {
        guard !id.isEmpty, id.count <= 128 else { throw RuntimeFailure("A bounded request ID is required") }
        if let prior=state.commands[id] {
            guard prior.operation==operation,prior.fingerprint==fingerprint else { throw RuntimeFailure("Request ID reused for a different command") }
            if let result=prior.result { return result }
            throw RuntimeFailure("Command delivery is uncertain after interruption; inspect the chat before explicitly retrying with a new request ID")
        }
        guard state.commands.count<100_000 else{throw RuntimeFailure("Command receipt storage is full; no action was applied")}
        state.commands[id]=CommandReceipt(operation:operation,fingerprint:fingerprint,state:"dispatching")
        try persistState()
        do {
            let result=try body();try flush()
            state.commands[id]?.result=result;state.commands[id]?.state="completed"
            try persistState();return result
        } catch {
            state.commands[id]?.state="delivery_uncertain";try? persistState();throw error
        }
    }
    func executeAsync(id: String, operation: String, fingerprint: String, body: () async throws -> JSON) async throws -> JSON {
        guard !id.isEmpty, id.count <= 128 else { throw RuntimeFailure("A bounded request ID is required") }
        if let prior=state.commands[id] {
            guard prior.operation==operation,prior.fingerprint==fingerprint else { throw RuntimeFailure("Request ID reused for a different command") }
            if let result=prior.result { return result }
            throw RuntimeFailure("Command delivery is uncertain after interruption; inspect the chat before explicitly retrying with a new request ID")
        }
        guard state.commands.count<100_000 else{throw RuntimeFailure("Command receipt storage is full; no action was applied")}
        state.commands[id]=CommandReceipt(operation:operation,fingerprint:fingerprint,state:"dispatching")
        try persistState()
        do {
            let result=try await body();try flush()
            state.commands[id]?.result=result;state.commands[id]?.state="completed"
            try persistState();return result
        } catch {
            state.commands[id]?.state="delivery_uncertain";try? persistState();throw error
        }
    }
    func recordAssistantNote(title:String,detail:String?,chat:UUID?) throws {
        var notes=state.assistantNotes ?? []
        notes.append(["id":.string(UUID().uuidString),"title":.string(title),"detail":detail.map(JSON.string) ?? .null,"chatID":chat.map{.string($0.uuidString)} ?? .null])
        state.assistantNotes=Array(notes.suffix(400));try persistState()
    }
    func ackAssistantNotes(_ ids:Set<String>) throws {
        state.assistantNotes=(state.assistantNotes ?? []).filter{!ids.contains($0["id"]?.string ?? "")}
        try persistState()
    }
    func updateStudios(_ studios:[Studio]) throws {
        try encoder.encode(studios).write(to:root.appendingPathComponent("Studios.json"),options:.atomic)
        self.studios=studios
        publishConfiguration()
    }
    func publishConfiguration() {
        state.sequence += 1
        let event=RuntimeEvent(sequence:state.sequence,revision:0,kind:"runtime.configuration")
        state.events.append(event)
        if state.events.count>4096{state.events.removeFirst(state.events.count-4096)}
        onEvent?(event)
    }
    func setIntegrationEnabled(_ enabled:Bool) throws {
        state.integrationEnabled=enabled
        state.sequence += 1
        let event=RuntimeEvent(sequence:state.sequence,revision:0,kind:"integration.changed")
        state.events.append(event)
        if state.events.count>4096{state.events.removeFirst(state.events.count-4096)}
        try persistState()
        onEvent?(event)
    }
    private func file(_ id: UUID) -> URL { root.appendingPathComponent("Conversations/\(id.uuidString).json") }
    func publishUIRequest(_ kind:String,payload:JSON) {
        state.sequence += 1
        onEvent?(RuntimeEvent(sequence:state.sequence,revision:0,kind:kind,payload:payload))
    }
    private func persistState() throws { try encoder.encode(state).write(to:root.appendingPathComponent("runtime-state.json"),options:.atomic) }
    private func attach(_ session: ChatSession) {
        session.onChange = { [weak self] s in self?.changed(s,streamed:false) }
        session.onStreamed = { [weak self] s in self?.changed(s,streamed:true) }
    }
    private func changed(_ s: ChatSession, streamed: Bool) {
        dirty.insert(s.id)
        let before=wasRunning[s.id] ?? false
        if before != s.isRunning { publish(s,kind:s.isRunning ? "turn.started":"turn.finished") }
        wasRunning[s.id]=s.isRunning
        for card in s.items where card.approvalState == .pending && !pendingCards.contains(card.id) {
            pendingCards.insert(card.id);publish(s,kind:card.kind == .questions ? "question.waiting":"approval.waiting")
        }
        for card in s.items where pendingCards.contains(card.id) && card.approvalState != .pending {
            pendingCards.remove(card.id);publish(s,kind:card.kind == .questions ? "question.resolved":"approval.resolved")
        }
        if !streamed { publish(s,kind:"chat.changed") }
        guard !saveScheduled else { return }
        saveScheduled=true
        DispatchQueue.main.asyncAfter(deadline:.now()+(streamed ? 0.1:0)) { [weak self] in
            guard let self else { return };self.saveScheduled=false
            if streamed { self.publish(s,kind:"turn.progress") }
            do { try self.flush() } catch { RuntimeHooks.note("Runtime save failed: \(error.localizedDescription)") }
        }
    }
    private func publish(_ s: ChatSession, kind: String) {
        state.sequence += 1;state.revisions[s.id.uuidString,default:0] += 1
        let e=RuntimeEvent(sequence:state.sequence,chatID:s.id,revision:state.revisions[s.id.uuidString]!,kind:kind)
        state.events.append(e);if state.events.count>4096 {state.events.removeFirst(state.events.count-4096)}
        onEvent?(e)
    }
}
