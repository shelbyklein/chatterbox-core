import Foundation
import Observation

/// Runs one conversation on Claude Code or Codex. Both agents run their own loop and keep
/// their own history; this maps what they do onto one transcript and adds the chat mechanics:
///
/// - Commentary vs. final: text written before a tool call is shown as a dim inline note;
///   only the text that ends a turn is shown as the reply.
/// - Steering: messages sent while a turn is running join that turn.
/// - Interrupt: stopping keeps what was said so far.
/// - Personality: sent as a tagged block only when it changes.
/// - Handoff: switching agents catches the new one up on what it missed.
@MainActor
@Observable
final class ChatSession: Identifiable {
    var record: ConversationRecord
    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning {
                if record.turnStartedAt == nil { record.turnStartedAt = Date() }
            } else {
                noteTurnDuration()
            }
        }
    }
    var isRestartingThread = false
    var threadRestartStatus: String?
    /// The "!" commands this chat is running (see ChatSession+Shell), by their transcript row. Not saved.
    var shellJobs: [UUID: ShellJob] = [:]
    /// How full each agent's context is, from its latest token counts. Not saved.
    var contextUsage: [Backend: ContextUsage] = [:] {
        didSet {
            guard contextUsage != oldValue else { return }
            record.savedContext = Dictionary(uniqueKeysWithValues: contextUsage.map { ($0.key.rawValue, $0.value) })
        }
    }

    @ObservationIgnored var remoteCommand: ((String, JSON) -> Void)?

    @ObservationIgnored var onChange: ((ChatSession) -> Void)?
    /// Called after agent output changed the transcript without `onChange` (streamed text),
    /// so it's saved soon, with how far the output was read (see ChatSession+Host).
    @ObservationIgnored var onStreamed: ((ChatSession) -> Void)?
    /// Set while this chat waits to reattach to its background processes after launch;
    /// saving leaves the saved links alone until then.
    @ObservationIgnored var awaitingHostResume = false
    /// Codex lines up to here (in `codexSkipProcess`) were already in the saved transcript.
    @ObservationIgnored var codexSkipThrough = 0
    @ObservationIgnored var codexSkipProcess: String?
    @ObservationIgnored var pendingSteering: [UserMessage] = []
    /// The transcript rows of `pendingSteering`, cleared from "Queued" once Codex takes them.
    @ObservationIgnored var pendingSteeringItems: [UUID] = []

    // Claude Code state (see ChatSession+Claude.swift).
    @ObservationIgnored var claudeProcess: ClaudeCodeProcess?
    @ObservationIgnored var claudeRender = ResponseRender()
    @ObservationIgnored var claudeToolItems: [String: UUID] = [:]
    /// Tool name and input per call, to preview files Claude writes once the write succeeds.
    @ObservationIgnored var claudeToolCalls: [String: (name: String, input: JSON)] = [:]
    @ObservationIgnored var claudePlanItem: UUID?
    /// Messages already shown from the live stream. Slash-command output arrives whole instead.
    @ObservationIgnored var claudeStreamedMessages: Set<String> = []
    /// Slash commands and skills this chat's Claude Code session offers (includes project ones).
    var claudeCommands: [SlashCommand]?
    @ObservationIgnored var claudeStopRequested = false
    /// An explicit restart must not silently replace a provider session that cannot resume.
    @ObservationIgnored var preserveClaudeSessionOnResumeFailure = false

    // Codex state (see ChatSession+Codex.swift).
    @ObservationIgnored var codexTurnID: String?
    @ObservationIgnored var codexItems: [String: UUID] = [:]
    @ObservationIgnored var codexPlanItems: [String: UUID] = [:]
    @ObservationIgnored var codexTurnMessageItems: [UUID] = []
    @ObservationIgnored var codexStopRequested = false
    /// Dot's per-thread tools/instructions last applied to the current Codex process.
    @ObservationIgnored var codexDotConfiguration: String?
    /// Stopping so a message can go straight in ("Send Now"), not a plain Stop.
    @ObservationIgnored var stoppingToSend = false
    /// What's typed in the message box but not sent yet, and files attached to it. Kept with
    /// the chat, so switching to another chat and back doesn't lose it.
    /// Not observed: only ChatView sets them, and it keeps its own copy while you type.
    @ObservationIgnored var applyingRemoteState=false
    @ObservationIgnored var draft = "" {didSet{syncRemoteDraft()}}
    /// The reply in progress answers a check-in Chatterbox sent (see DotActivity).
    @ObservationIgnored var automaticTurn = false
    /// Chatterbox's usual "finished" alert is skipped for this turn (Dot's quiet check-ins).
    @ObservationIgnored var skipFinishedAlert = false
    /// Restart Claude Code once this reply ends, so the next message gets new tools.
    @ObservationIgnored var restartForToolsAfterTurn = false

    /// Claude Code's commands and skills (including the project's), or Codex's skills.
    var availableSlashCommands: [SlashCommand] {
        if record.backend == .codex {
            return record.codex.map { CodexAppServer.shared.skills[$0.folder] ?? [] } ?? []
        }
        return claudeCommands ?? ClaudeModels.shared.commands
    }

    /// Called as a turn ends, before the change is saved: Dot's check-ins tidy up here.
    func turnEnded() {
        RuntimeHooks.note("Reply ended in \u{201C}\(title)\u{201D} (\(record.items.count) rows)")
        record.updatedAt = Date()
        if isRestartingThread {
            automaticTurn = false
            skipFinishedAlert = true
            return
        }
        if restartForToolsAfterTurn {
            // Tools changed during the reply (Dot turned its computer on or off).
            restartForToolsAfterTurn = false
            DispatchQueue.main.async { [weak self] in self?.restartClaudeForNewTools() }
        }
        RuntimeHooks.turnEnded(self)
    }
    @ObservationIgnored var draftAttachments: [Attachment] = [] {didSet{syncRemoteDraft()}}
    private func syncRemoteDraft(){
        guard !applyingRemoteState,let remoteCommand else{return}
        remoteCommand("setDraft",["text":.string(draft),"attachments":(try? .value(draftAttachments)) ?? []])
    }
    /// The chat's page on claude.ai while Remote Control is on (see ChatSession+Remote).
    var remoteURL: URL?
    /// Messages sent from here that Claude Code hasn't echoed yet, to tell them apart from
    /// ones typed on claude.ai or the Claude app.
    @ObservationIgnored var claudeAwaitingEcho: [String] = []
    /// Codex commands in progress this turn (item id → command and process), so any still
    /// running when the reply ends carry on as background tasks.
    @ObservationIgnored var codexRunningCommands: [String: (command: String, processID: Int32?)] = [:]

    /// Finds a chat's Studio (set by AppModel), for its instructions.
    static var studioLookup: (UUID) -> Studio? = { _ in nil }
    var studio: Studio? { record.studioID.flatMap(Self.studioLookup) }

    /// The Studio's instructions if they changed since the agent last saw them, and marks
    /// them seen. Moving into or out of a Studio counts as a change.
    func takeStudioInstructionsUpdate() -> String? {
        let current = studio?.noteKey ?? ""
        guard current != (record.sentStudioInstructions ?? "") else { return nil }
        record.sentStudioInstructions = current
        return Prompts.studioInstructionsUpdate(studio: studio)
    }

    nonisolated let id: UUID
    var items: [DisplayItem] { record.items }
    var title: String { record.title }
    /// The project's nickname, or else its folder's name.
    var projectName: String {
        record.projectNickname ?? record.projectFolder.map { ($0 as NSString).lastPathComponent } ?? ""
    }

    /// Your own title for the chat. Automatic titles only fill in a chat still called "New chat".
    func setTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.title else { return }
        record.title = trimmed
        onChange?(self)
    }

    /// An empty name goes back to the folder's name.
    func setProjectNickname(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = record.projectFolder.map { ($0 as NSString).lastPathComponent }
        record.projectNickname = trimmed.isEmpty || trimmed == folderName ? nil : trimmed
        onChange?(self)
    }

    init(record: ConversationRecord) {
        self.id = record.id
        self.record = record
        for (key, usage) in record.savedContext ?? [:] {
            if let backend = Backend(rawValue: key) { contextUsage[backend] = usage }
        }
        settleOrphanedShellRows()
    }

    // MARK: - Public API

    func send(_ raw: String, attachments: [Attachment] = []) {
        guard !isRestartingThread else { return }
        if let remoteCommand { remoteCommand("send", ["text":.string(raw),"attachments":(try? .value(attachments)) ?? []]);return }
        let message = UserMessage(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
        guard !message.text.isEmpty || !attachments.isEmpty else { return }
        RuntimeHooks.clearSuggestions(self)
        RuntimeHooks.note("Sent a message in \u{201C}\(title)\u{201D}\(isRunning ? " while it worked" : "")")
        // Sending counts as activity (a reply in progress doesn't, so rows don't jump around).
        record.updatedAt = Date()
        // Writing in an archived chat brings it back.
        if record.archivedAt != nil { setArchived(false) }
        // "!command" runs in the chat's folder instead of going to the agent.
        if message.text.hasPrefix("!"), attachments.isEmpty {
            runShell(String(message.text.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        switch record.backend {
        case .codex: codexSend(message)
        case .claude: claudeSend(message)
        }
    }

    /// ⌘↩ while the agent works: stop what it's doing and take this message right away,
    /// instead of waiting for its next step.
    func sendNow(_ raw: String, attachments: [Attachment] = []) {
        guard !isRestartingThread else { return }
        if let remoteCommand { remoteCommand("sendNow", ["text":.string(raw),"attachments":(try? .value(attachments)) ?? []]);return }
        let message = UserMessage(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
        guard !message.text.isEmpty || !attachments.isEmpty else { return }
        guard isRunning, !message.text.hasPrefix("!") else { return send(raw, attachments: attachments) }
        stoppingToSend = true
        switch record.backend {
        case .claude:
            // Claude Code runs a queued message as soon as the turn it's in stops.
            claudeSend(message)
            claudeInterrupt()
        case .codex:
            let item = appendUserItem(message, steered: true)
            pendingSteering.append(message)
            pendingSteeringItems.append(item)
            codexInterrupt()
        }
        onChange?(self)
    }

    /// "Send Now" on a message that's still queued.
    func sendQueuedNow(_ itemID: UUID) {
        guard !isRestartingThread else { return }
        if let remoteCommand {remoteCommand("sendQueuedNow",["itemID":.string(itemID.uuidString)]);return}
        guard isRunning, record.items.contains(where: { $0.id == itemID && $0.queued == true }) else { return }
        stoppingToSend = true
        switch record.backend {
        case .claude: claudeInterrupt()
        case .codex: codexInterrupt()
        }
    }

    /// Whether Stop has something to stop: a reply, or a "!" command.
    var canStop: Bool { isRunning || hasShellJobs }

    func interrupt() {
        if let remoteCommand {remoteCommand("stop",[:]);return}
        stopShellJobs()
        switch record.backend {
        case .codex: codexInterrupt()
        case .claude: claudeInterrupt()
        }
    }

    /// Reconnect only this conversation. Never clears provider IDs or resends a prompt.
    func restartThread() async {
        guard !isRestartingThread, !awaitingHostResume else { return }
        isRestartingThread = true
        threadRestartStatus = nil
        defer { isRestartingThread = false; onChange?(self) }
        do {
            #if !CHATTERBOX_HEADLESS
            if remoteCommand != nil {
                let result = try await RuntimeClient.shared.request("restartThread", body: ["chatID": .string(id.uuidString)])
                threadRestartStatus = result["status"]?.string
                return
            }
            #endif
            stopShellJobs()
            switch record.backend {
            case .claude: try claudeRestartThread()
            case .codex: try await codexRestartThread()
            }
            threadRestartStatus = "Thread restarted. History kept; send a message to continue."
        } catch {
            threadRestartStatus = "Couldn't restart: \(error.localizedDescription) History and draft are kept."
        }
    }

    func resolveApproval(_ itemID: UUID, _ decision: DisplayItem.ApprovalState) {
        if let remoteCommand {remoteCommand("approve",["itemID":.string(itemID.uuidString),"decision":.string(decision.rawValue)]);return}
        switch record.backend {
        case .codex: codexResolveApproval(itemID, decision)
        case .claude: claudeResolveApproval(itemID, decision)
        }
    }

    /// Stamps the turn's final reply with how long it took, when that was long enough to matter.
    private func noteTurnDuration() {
        guard let started = record.turnStartedAt else { return }
        record.turnStartedAt = nil
        let seconds = Int(Date().timeIntervalSince(started))
        guard seconds >= 10,
              let index = record.items.lastIndex(where: { $0.kind == .assistant && $0.phase == .final }),
              record.items[index...].allSatisfy({ $0.kind != .user || $0.steered }) else { return }
        record.items[index].workedSeconds = seconds
    }

    /// "4m 12s", "1h 3m", "45s".
    static func durationText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// Answers a question card; nil means you skipped it.
    func answerQuestions(_ itemID: UUID, answers: [String: [String]]?) {
        if let remoteCommand {remoteCommand("answer",["itemID":.string(itemID.uuidString),"answers":(try? .value(answers)) ?? .null]);return}
        if let item = record.items.first(where: { $0.id == itemID }), let suggested = item.suggested {
            RuntimeHooks.answered(self, item, suggested, answers)
        }
        switch record.backend {
        case .codex: codexAnswer(itemID, answers: answers)
        case .claude: claudeAnswer(itemID, answers: answers)
        }
    }

    /// Golem's suggested answers for a pending question card: checked against its questions,
    /// shown on the card, and sent only when you send them. Throws a reason it can't.
    func suggestAnswers(_ itemID: UUID, answers: [String: [String]], reason: String, by name: String) throws {
        guard let index = record.items.firstIndex(where: { $0.id == itemID }),
              record.items[index].kind == .questions, record.items[index].approvalState == .pending else {
            throw SuggestionError(message: "That chat has no pending question card with that id.")
        }
        let questions = record.items[index].questions ?? []
        var cleaned: [String: [String]] = [:]
        for (id, picks) in answers {
            guard let question = questions.first(where: { $0.id == id }) else {
                throw SuggestionError(message: "No question with id \u{201C}\(id)\u{201D} on that card.")
            }
            if question.isSecret { throw SuggestionError(message: "That question asks for a secret; only the user can answer it.") }
            let values = picks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !question.multiSelect, values.count > 1 { throw SuggestionError(message: "\u{201C}\(question.question)\u{201D} takes one answer.") }
            if !values.isEmpty { cleaned[id] = values }
        }
        guard !cleaned.isEmpty else { throw SuggestionError(message: "No answers to suggest.") }
        record.items[index].suggested = cleaned
        record.items[index].suggestedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        record.items[index].suggestedBy = name
        RuntimeHooks.suggested(self, record.items[index])
        onChange?(self)
    }

    struct SuggestionError: Error { let message: String }

    /// Stops any agent process this chat owns, e.g. when the chat is deleted.
    func shutdown() {
        if let remoteCommand {remoteCommand("stop",[:]);return}
        interrupt()
        killShellJobs()
        claudeProcess?.terminate()
        claudeProcess = nil
    }

    @discardableResult
    func appendUserItem(_ message: UserMessage, steered: Bool = false) -> UUID {
        // A message sent mid-turn waits until the agent picks it up (see ChatSession+Status).
        appendItem(DisplayItem(kind: .user, text: message.text, steered: steered, queued: steered ? true : nil,
                               attachments: message.attachments.isEmpty ? nil : message.attachments,
                               agent: record.backend))
    }

    /// Which agent each user message went to. Older rows didn't record it, so it's worked out
    /// from the agent-switch notes, walking back from the agent answering now.
    var agentsByItem: [UUID: Backend] { agents(forItemsFrom: 0) }

    /// The same, for the user messages from `start` on: walking back from the end, the tail
    /// alone gives the same answer.
    func agents(forItemsFrom start: Int) -> [UUID: Backend] {
        var result: [UUID: Backend] = [:]
        var current = record.backend
        for item in record.items[max(0, min(start, record.items.count))...].reversed() {
            let isOldSwitch = item.kind == .notice && item.text.hasPrefix("Switched to ")
            let isSwitch = item.isSettingsChange == true && Self.isAgentSwitchNote(item.text)
            if isOldSwitch || isSwitch {
                // Before this note, the other agent was answering.
                let toCodex = item.text.hasPrefix("Switched to Codex") || item.text.hasPrefix("Now using Codex")
                current = toCodex ? .claude : .codex
            }
            if item.kind == .user { result[item.id] = item.agent ?? current }
        }
        return result
    }

    /// Every attachment in this chat, for cleanup when the chat is deleted.
    var allAttachments: [Attachment] { record.items.flatMap { $0.attachments ?? [] } }

    func setTitleIfNeeded(_ message: UserMessage) {
        guard record.title == "New chat" else { return }
        let text = message.text.isEmpty ? message.attachments.map(\.name).joined(separator: ", ") : message.text
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        record.title = firstLine.count > 48 ? String(firstLine.prefix(47)) + "\u{2026}" : firstLine
    }

    // MARK: - Agent switching

    /// Switches which agent answers. Mid-chat, the incoming agent is handed a transcript of
    /// whatever it missed, since Claude and Codex keep separate histories.
    func setBackend(_ backend: Backend) {
        guard !isRestartingThread else { return }
        if let remoteCommand {remoteCommand("settings",["backend":.string(backend.rawValue)]);return}
        guard !isRunning, backend != record.backend else { return }
        let leaving = record.backend
        if !record.items.isEmpty {
            let last = record.items.last?.id
            if leaving == .claude { record.claudeSeenThrough = last } else { record.codexSeenThrough = last }
            let seen = backend == .claude ? record.claudeSeenThrough : record.codexSeenThrough
            let start = seen.flatMap { id in record.items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            let transcript = Self.transcript(record.items[start...])
            record.pendingHandoff = transcript.isEmpty ? nil
                : Prompts.handoff(from: leaving.label, transcript: transcript, isWholeConversation: seen == nil)
        }
        if backend == .codex, record.codex == nil {
            let defaults = AppPreferences.defaults
            record.codex = CodexSettings(
                folder: isDot ? RuntimePaths.assistantFolder : (record.boundFolder ?? defaults.string(forKey: "codexFolder") ?? NSHomeDirectory()),
                canEdit: false,
                mode: PermissionModes.defaultCodex
            )
            record.codex?.model = defaults.string(forKey: "codexDefaultModel").flatMap { $0.isEmpty ? nil : $0 }
            record.codex?.effort = defaults.string(forKey: "codexDefaultEffort").flatMap { $0.isEmpty ? nil : $0 }
        }
        if isDot, backend == .codex { record.codex?.folder = RuntimePaths.assistantFolder }
        record.activeBackend = backend
        // The incoming agent may not have seen the current tone.
        record.sentPersonality = nil
        noteSettingsChange(switchedAgent: true)
        onChange?(self)
    }

    /// The agent, model, and effort in words, e.g. "Claude · Opus 5.5 · Medium effort".
    var settingsDescription: String {
        switch record.backend {
        case .claude:
            let model = ClaudeModels.shared.info(record.model)
            let effort = record.effort.isEmpty ? "default effort" : "\(RuntimePaths.effortLabel(record.effort)) effort"
            return "Claude \u{00B7} \(model.displayName)" + (model.efforts.isEmpty ? "" : " \u{00B7} \(effort)") + (fastMode ? " \u{00B7} Fast mode" : "")
        case .codex:
            let models = CodexAppServer.shared.models
            let name = models.first { $0.model == record.codex?.model }?.displayName
                ?? models.first(where: \.isDefault).map { "\($0.displayName) (default)" } ?? "default model"
            let effort = record.codex?.effort.map { "\(RuntimePaths.effortLabel($0)) effort" } ?? "default effort"
            return "Codex \u{00B7} \(name) \u{00B7} \(effort) \u{00B7} \(record.codex?.fastMode == true ? "Fast mode" : "Standard speed")"
        }
    }

    /// Adds a line to the chat when the agent, model, or effort changes. Changes made in a row
    /// (a preset, dragging the effort slider) update the same line instead of adding more.
    /// Added when the agent changes: the transcript of what it missed goes with the next message.
    static let catchUpNote = " It'll be caught up with your next message."

    /// Whether a settings note marks a switch of agent (including the wording older chats used).
    static func isAgentSwitchNote(_ text: String) -> Bool {
        text.hasSuffix(catchUpNote) || text.hasSuffix(" It has been caught up on this chat.")
    }

    func noteSettingsChange(switchedAgent: Bool = false) {
        guard record.items.contains(where: { $0.kind == .user }) else { return }
        let caughtUp = Self.catchUpNote
        if let last = record.items.indices.last, record.items[last].isSettingsChange == true {
            let wasSwitch = Self.isAgentSwitchNote(record.items[last].text)
            record.items[last].text = "Now using \(settingsDescription)." + (switchedAgent || wasSwitch ? caughtUp : "")
        } else {
            record.items.append(DisplayItem(kind: .notice, text: "Now using \(settingsDescription)." + (switchedAgent ? caughtUp : ""),
                                            isSettingsChange: true))
        }
    }

    /// A plain-text record of the conversation for handing it to another agent.
    static func transcript(_ items: ArraySlice<DisplayItem>, limit: Int = 150_000) -> String {
        var parts: [String] = []
        for item in items {
            switch item.kind {
            case .user:
                var text = "User: " + item.text
                if let files = item.attachments, !files.isEmpty {
                    text += (item.text.isEmpty ? "" : "\n") + "[Attached: " + files.map { "\($0.name) (\($0.path))" }.joined(separator: ", ") + "]"
                }
                parts.append(text)
            case .assistant where item.phase == .final:
                parts.append("Assistant: " + item.text)
            case .plan:
                parts.append("Plan: " + item.planSteps.map { "[\($0.status)] \($0.step)" }.joined(separator: "; "))
            case .shell:
                parts.append("User ran: $ \(item.text)\n" + String((item.detail ?? "").suffix(4_000)))
            case .questions:
                let qa = (item.questions ?? []).map { q in
                    "Q: \(q.question) A: \((item.answers?[q.id] ?? ["(no answer)"]).joined(separator: ", "))"
                }
                parts.append("Assistant asked:\n" + qa.joined(separator: "\n"))
            case .image:
                let files = (item.attachments ?? []).map(\.path).joined(separator: ", ")
                parts.append("Assistant produced a file to look at" + (item.text.isEmpty ? "" : " (\(item.text))") + ": " + files)
            default:
                break
            }
        }
        let joined = parts.joined(separator: "\n\n")
        return joined.count > limit ? "(earlier messages omitted)\n\n" + String(joined.suffix(limit)) : joined
    }

    // MARK: - Settings

    /// Binds this chat to a folder. AppModel checks that no other chat owns it.
    func bindProject(_ folder: String) {
        guard folder != record.projectFolder else { return }
        record.projectFolder = folder
        record.convertedProjectFolder = nil
        record.studioWorkingFolder = nil
        if record.sidechatOf == nil { record.sidechatProjectFolder = nil }
        // A project chat isn't in a Studio.
        record.studioID = nil
        record.studioFolder = nil
        record.codex?.folder = folder
        claudeWorkingFolderChanged()
        onChange?(self)
    }

    /// Records the GitHub repo the folder's git remote points to.
    func updateGitHubRepo(from status: GitStatus?) {
        let repo = status?.remote(preferring: record.gitRemote)?.repo
        guard repo != record.githubRepo else { return }
        record.githubRepo = repo
        onChange?(self)
    }

    func setGitRemote(_ name: String) {
        record.gitRemote = name
        updateGitHubRepo(from: GitStatusStore.shared.status(for: record.projectFolder))
        onChange?(self)
    }

    /// Original project secret scope only while this thread still works in that folder.
    var convertedProjectScope: String? {
        record.convertedProjectFolder.flatMap { RuntimePaths.normalize($0) == RuntimePaths.normalize(workingFolder) ? $0 : nil }
    }

    /// Moves this chat into a Studio, where it works in the Studio's folder, or out of one
    /// with nil. A project chat leaves its project.
    func setStudio(_ studio: Studio?, keepingFolder: String? = nil, convertedProject: String? = nil) {
        guard studio?.id != record.studioID || keepingFolder != record.studioWorkingFolder else { return }
        let previousFolder = workingFolder
        if let original = record.convertedProjectFolder,
           studio.map({ RuntimePaths.normalize($0.folder) }) != RuntimePaths.normalize(original) {
            record.convertedProjectFolder = nil
        }
        record.studioWorkingFolder = studio == nil ? nil : keepingFolder
        if let convertedProject { record.convertedProjectFolder = convertedProject }
        record.studioID = studio?.id
        record.studioFolder = studio?.folder
        if studio != nil {
            record.projectFolder = nil
            record.githubRepo = nil
        }
        let folder = record.boundFolder ?? AppPreferences.defaults.string(forKey: "codexFolder") ?? NSHomeDirectory()
        record.codex?.folder = folder
        if RuntimePaths.normalize(previousFolder) != RuntimePaths.normalize(folder) {
            if record.sidechatOf == nil { record.sidechatProjectFolder = nil }
            claudeWorkingFolderChanged()
        }
        onChange?(self)
    }

    func unbindProject() {
        guard record.projectFolder != nil else { return }
        record.projectFolder = nil
        record.githubRepo = nil
        claudeWorkingFolderChanged()
        onChange?(self)
    }

    /// The active agent's permission mode.
    var mode: PermissionMode {
        record.backend == .codex
            ? PermissionModes.mode(record.codex?.modeID ?? PermissionModes.defaultCodex, for: .codex)
            : PermissionModes.mode(record.claudeModeID, for: .claude)
    }

    /// Sets the permission mode for the active agent. Takes effect right away, even mid-turn.
    func setMode(_ id: String) {
        if let remoteCommand {remoteCommand("settings",["mode":.string(id)]);return}
        switch record.backend {
        case .claude:
            record.claudeMode = id
            claudeApplyPermissionMode()
        case .codex:
            record.codex?.mode = id
        }
        onChange?(self)
    }

    var tags: [String] { record.tags ?? [] }

    func toggleTag(_ tag: String) {
        var tags = self.tags
        if let index = tags.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        record.tags = tags.isEmpty ? nil : tags
        onChange?(self)
    }

    func setArchived(_ archived: Bool) {
        if let remoteCommand {remoteCommand("archive",["archived":.bool(archived)]);return}
        record.archivedAt = archived ? Date() : nil
        onChange?(self)
    }

    func setPersonality(_ personality: Personality) {
        if let remoteCommand {remoteCommand("settings",["personality":.string(personality.rawValue)]);return}
        record.personality = personality
        onChange?(self)
    }

    func setModel(_ model: String) {
        if let remoteCommand {remoteCommand("settings",["model":.string(model)]);return}
        guard model != record.model else { return }
        record.model = model
        let efforts = ClaudeModels.shared.info(model).efforts
        if !record.effort.isEmpty, !efforts.contains(record.effort) { record.effort = "" }
        if record.claudeFastMode == true { restartClaudeForNewTools() } else { claudeApplyModel() }
        if record.backend == .claude { noteSettingsChange() }
        onChange?(self)
    }

    func setEffort(_ effort: String) {
        if let remoteCommand {remoteCommand("settings",["effort":.string(effort)]);return}
        guard effort != record.effort else { return }
        record.effort = effort
        claudeApplyEffort()
        if record.backend == .claude { noteSettingsChange() }
        onChange?(self)
    }

    // MARK: - Display items

    @discardableResult
    func appendItem(_ item: DisplayItem) -> UUID {
        record.items.append(item)
        return item.id
    }

    func updateItem(_ id: UUID, _ change: (inout DisplayItem) -> Void) {
        guard let index = record.items.lastIndex(where: { $0.id == id }) else { return }
        change(&record.items[index])
    }

    func notice(_ text: String) {
        record.items.append(DisplayItem(kind: .notice, text: text))
    }

    func markRunningToolsFailed() {
        for index in record.items.indices where record.items[index].kind == .tool && record.items[index].toolState == .running {
            record.items[index].toolState = .failed
        }
    }

    func expirePendingApprovals() {
        for index in record.items.indices where record.items[index].approvalState == .pending {
            record.items[index].approvalState = .expired
        }
    }
}

/// Per-response bookkeeping that maps streamed block indexes to transcript rows.
struct ResponseRender: Codable, Equatable {
    var itemForIndex: [Int: UUID] = [:]
    var textItems: [UUID] = []
}
