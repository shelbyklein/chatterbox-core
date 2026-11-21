import Foundation

/// The Gemini backend: Google's Antigravity CLI (`agy acp`), one process per chat, signed in
/// with the user's Google account. agy runs the agent loop, tools and history (its session,
/// `record.gemini.sessionId`); this side sends prompts, answers permission requests, and maps
/// its `session/update` stream onto the transcript. Protocol notes: plans/gemini-agent.md.
extension ChatSession {
    // MARK: - Sending

    func geminiSend(_ message: UserMessage) {
        if !isRunning { setTitleIfNeeded(message) }
        let earlierItems = record.items.count
        // agy takes one prompt at a time: a message sent mid-reply waits for the next turn.
        if isRunning {
            let item = appendUserItem(message, steered: true)
            geminiQueue.append((message, item))
            onChange?(self)
            return
        }
        appendUserItem(message, steered: false)
        isRunning = true
        geminiStopRequested = false
        claudePlanItem = nil
        onChange?(self)
        Task { await geminiDeliver(message, earlierItems: earlierItems) }
    }

    private func geminiDeliver(_ message: UserMessage, earlierItems: Int) async {
        do {
            let (process, sessionID) = try await geminiEnsureSession(earlierItems: earlierItems)
            geminiTurn += 1
            process.requestNow("session/prompt", ["sessionId": .string(sessionID), "prompt": .array(geminiContent(for: message))])
        } catch {
            isRunning = false
            notice(error.localizedDescription)
            sendNextQueuedGemini()
        }
        onChange?(self)
    }

    /// The prompt's blocks: what the agent should know first (a handoff, changed
    /// instructions), then the message and its pictures. Other files go as paths.
    func geminiContent(for message: UserMessage) -> [JSON] {
        var preamble: [String] = []
        if let shell = takeShellContext() { preamble.append(shell) }
        if let handoff = record.pendingHandoff {
            preamble.append(handoff)
            record.pendingHandoff = nil
        }
        if record.sentPersonality != record.personality {
            preamble.append(Prompts.personalitySpec(record.personality))
            record.sentPersonality = record.personality
        }
        if (record.instructionsVersion ?? 1) < Prompts.instructionsVersion {
            preamble.append(Prompts.instructionsUpdate(from: record.instructionsVersion ?? 1, workThreads: record.isInProject))
            record.instructionsVersion = Prompts.instructionsVersion
        }
        let user = Prompts.userInstructions
        if user != (record.sentUserInstructions ?? "") {
            preamble.append(Prompts.userInstructionsUpdate(user))
            record.sentUserInstructions = user
        }
        if let studioUpdate = takeStudioInstructionsUpdate() { preamble.append(studioUpdate) }
        if let brief = takeBriefUpdate() { preamble.append(brief) }
        if let secrets = takeSecretsUpdate() { preamble.append(secrets) }
        if let computer = takeComputerUpdate() { preamble.append(computer) }

        var blocks: [JSON] = preamble.map { ["type": "text", "text": .string($0)] }
        var text = message.text
        let files = message.attachments.filter { $0.kind != .image }
        if !files.isEmpty {
            let list = files.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
            text += (text.isEmpty ? "" : "\n\n") + "Attached files (read them from these paths):\n" + list
        }
        if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        for image in message.attachments where image.kind == .image {
            guard let data = try? Data(contentsOf: image.url) else { continue }
            blocks.append(["type": "image", "mimeType": .string(image.mediaType), "data": .string(data.base64EncodedString())])
        }
        return blocks
    }

    /// The next message that waited for the reply to end.
    private func sendNextQueuedGemini() {
        guard !geminiQueue.isEmpty, !isRunning else { return }
        let next = geminiQueue.removeFirst()
        markPickedUp(next.item)
        isRunning = true
        geminiStopRequested = false
        onChange?(self)
        Task { await geminiDeliver(next.message, earlierItems: record.items.count) }
    }

    // MARK: - Process and session

    var geminiWorkingFolder: String {
        record.boundFolder ?? AppPreferences.defaults.string(forKey: "codexFolder") ?? NSHomeDirectory()
    }

    /// This chat's agy process and an open session in it: started, initialized, and the
    /// chat's session resumed (or a new one, told the instructions and caught up on the chat).
    func geminiEnsureSession(earlierItems: Int) async throws -> (GeminiACPProcess, String) {
        if let starting = geminiStarting { try await starting.value }
        if let process = geminiProcess, process.isRunning, geminiSessionReady, let id = record.gemini?.sessionId {
            if ToolScopes.fingerprint(for: self) == geminiToolsFingerprint,
               SecretVault.shared.fingerprint(for: self) == geminiSecretsFingerprint {
                return (process, id)
            }
            // Tools or Secrets changed: restart agy so the resumed session gets the new MCP servers and env.
            releaseGeminiProcess()
        }
        let task = Task { @MainActor in try await self.geminiStartSession(earlierItems: earlierItems) }
        geminiStarting = task
        defer { geminiStarting = nil }
        try await task.value
        guard let process = geminiProcess, let id = record.gemini?.sessionId else {
            throw GeminiError(message: "Gemini didn't open a session.")
        }
        return (process, id)
    }

    private func geminiStartSession(earlierItems: Int) async throws {
        if record.gemini == nil { record.gemini = GeminiSettings.newChat() }
        let tools = ToolScopes.effective(for: self)
        let mcpServers = geminiToolsMCPServers(tools)
        geminiToolsFingerprint = ToolScopes.fingerprint(for: self)
        geminiSecretsFingerprint = SecretVault.shared.fingerprint(for: self)
        let process: GeminiACPProcess
        if let running = geminiProcess, running.isRunning {
            process = running
        } else {
            process = makeGeminiProcess()
            try process.start(cwd: geminiWorkingFolder, environment: geminiLaunchEnvironment,
                              id: "gemini-\(id.uuidString)-\(UUID().uuidString.prefix(8))")
            geminiProcess = process
            geminiSessionReady = false
            _ = try await process.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false,
                    "elicitation": ["form": [:]],
                ],
                "clientInfo": ["name": "Chatterbox", "version": "1"],
            ])
        }
        let cwd = geminiWorkingFolder
        var opened: JSON?
        if let saved = record.gemini?.sessionId {
            // Resume without replaying the conversation; older agy builds only load (replay).
            do {
                opened = try await process.request("session/resume", ["sessionId": .string(saved), "cwd": .string(cwd), "mcpServers": .array(mcpServers)])
            } catch {
                geminiReplaying = true
                defer { geminiReplaying = false }
                do {
                    opened = try await process.request("session/load", ["sessionId": .string(saved), "cwd": .string(cwd), "mcpServers": .array(mcpServers)])
                } catch {
                    // The saved session is gone: a new one, caught up on the chat.
                    record.gemini?.sessionId = nil
                    record.geminiSeenThrough = nil
                    notice("Couldn't reopen the earlier Gemini session; continuing in a new one, caught up on this chat.")
                }
            }
        }
        if record.gemini?.sessionId == nil {
            let result = try await process.request("session/new", ["cwd": .string(cwd), "mcpServers": .array(mcpServers)])
            guard let sessionID = result["sessionId"]?.string else { throw GeminiError(message: "Gemini didn't open a session.") }
            record.gemini?.sessionId = sessionID
            opened = result
            // A new session knows nothing of this chat yet: its instructions, and what came before.
            var intro = Prompts.fullInstructions(record.personality, backend: .gemini, projectFolder: record.boundFolder,
                                                 studio: studio, brief: record.brief, workThreads: record.isInProject)
            if record.pendingHandoff == nil, earlierItems > 0 {
                let transcript = Self.transcript(record.items[0..<earlierItems])
                if !transcript.isEmpty {
                    intro += "\n\n" + Prompts.handoff(from: "", transcript: transcript, isWholeConversation: true,
                                                      toolsUsed: Self.toolsUsed(record.items[0..<earlierItems]))
                }
            }
            record.pendingHandoff = intro + (record.pendingHandoff.map { "\n\n" + $0 } ?? "")
            record.sentPersonality = record.personality
            record.sentUserInstructions = Prompts.userInstructions
            record.sentStudioInstructions = studio?.noteKey ?? ""
            record.sentBrief = record.brief ?? ""
            record.instructionsVersion = Prompts.instructionsVersion
        }
        if let opened { GeminiModels.shared.update(from: opened) }
        geminiSessionReady = true
        geminiApplySettings(process)
    }

    /// The chat's model, effort and mode, set on the open session.
    func geminiApplySettings(_ process: GeminiACPProcess? = nil) {
        guard let process = process ?? geminiProcess, process.isRunning, geminiSessionReady,
              let session = record.gemini?.sessionId else { return }
        if let model = record.gemini?.model {
            process.requestNow("session/set_config_option", ["sessionId": .string(session), "configId": "model", "value": .string(model)])
        }
        if let effort = record.gemini?.effort {
            process.requestNow("session/set_config_option", ["sessionId": .string(session), "configId": "thought_level", "value": .string(effort)])
        }
        process.requestNow("session/set_mode", ["sessionId": .string(session), "modeId": .string(Self.geminiAgyMode(geminiModeID))])
    }

    var geminiModeID: String { record.gemini?.mode ?? PermissionModes.defaultGemini }

    /// Bypass is Chatterbox's own (it approves every request); agy runs it as Auto.
    static func geminiAgyMode(_ mode: String) -> String { mode == "bypass" ? "auto" : mode }

    /// A process wired to this chat, not yet started or attached.
    func makeGeminiProcess() -> GeminiACPProcess {
        let process = GeminiACPProcess()
        process.onMessage = { [weak self] message in
            guard let self else { return }
            self.handleGemini(message)
            self.onStreamed?(self)
        }
        process.onExit = { [weak self] status, detail in self?.geminiProcessExited(status: status, detail: detail) }
        return process
    }

    var geminiLaunchEnvironment: [String: String] {
        SecretVault.shared.environment(for: self).merging(["CHATTERBOX_CHAT_ID": id.uuidString]) { $1 }
    }

    /// How long agy gets to confirm a Stop before Chatterbox ends the reply itself.
    static var geminiStopGrace: Duration = .seconds(10)

    func geminiInterrupt() {
        guard isRunning else { return }
        geminiStopRequested = true
        if let process = geminiProcess, let session = record.gemini?.sessionId {
            process.notify("session/cancel", ["sessionId": .string(session)])
        }
        // agy can wedge and ignore every cancel (2026-11-20: a finished reply never closed,
        // and twenty Stops went unanswered). If it hasn't confirmed in time, the reply ends
        // here and its process is restarted; the session stays, for the next message.
        let turn = geminiTurn
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.geminiStopGrace)
            guard let self, self.isRunning, self.geminiStopRequested, self.geminiTurn == turn else { return }
            RuntimeHooks.note("Gemini didn't confirm Stop in \u{201C}\(self.title)\u{201D}; ended the reply and restarted its process")
            self.releaseGeminiProcess()
            self.finishGeminiTurn(stopReason: "cancelled", usage: nil)
        }
    }

    /// Ends the process (not the session); the next message starts a new one that resumes it.
    func geminiRestartThread() throws {
        geminiProcess?.onMessage = nil
        geminiProcess?.terminate()
        geminiProcess = nil
        geminiSessionReady = false
        record.geminiHost = nil
        isRunning = false
        automaticTurn = false
        stoppingToSend = false
        markRunningToolsFailed()
        expirePendingApprovals()
        clearQueuedMessages()
        geminiQueue = []
        geminiResetTurn()
        onChange?(self)
    }

    /// Ends an idle process; its session stays, for the next message's process to resume.
    func releaseGeminiProcess() {
        geminiProcess?.terminate()
        geminiProcess = nil
        geminiSessionReady = false
        record.geminiHost = nil
    }

    /// A new folder means a new agy session, caught up on the conversation so far.
    func geminiWorkingFolderChanged() {
        guard record.gemini?.sessionId != nil || geminiProcess != nil else { return }
        geminiProcess?.terminate()
        geminiProcess = nil
        geminiSessionReady = false
        record.gemini?.sessionId = nil
        record.geminiSeenThrough = nil
        if isRunning { isRunning = false }
    }

    // MARK: - Live settings

    func setGeminiModel(_ model: String) {
        if let remoteCommand { remoteCommand("settings", ["geminiModel": .string(model)]); return }
        guard model != record.gemini?.model else { return }
        if record.gemini == nil { record.gemini = GeminiSettings.newChat() }
        record.gemini?.model = model
        geminiApplySettings()
        if record.backend == .gemini { noteSettingsChange() }
        onChange?(self)
    }

    func setGeminiEffort(_ effort: String) {
        if let remoteCommand { remoteCommand("settings", ["geminiEffort": .string(effort)]); return }
        guard effort != record.gemini?.effort else { return }
        if record.gemini == nil { record.gemini = GeminiSettings.newChat() }
        record.gemini?.effort = effort.isEmpty ? nil : effort
        geminiApplySettings()
        if record.backend == .gemini { noteSettingsChange() }
        onChange?(self)
    }

    // MARK: - Stream

    private func handleGemini(_ message: JSON) {
        if let method = message["method"]?.string {
            switch method {
            case "session/update":
                guard !geminiReplaying, message["params"]?["sessionId"]?.string == record.gemini?.sessionId else { return }
                geminiUpdate(message["params"]?["update"] ?? [:])
            case "session/request_permission":
                guard let id = message["id"] else { return }
                geminiPermission(id: id, params: message["params"] ?? [:])
            case "elicitation/create":
                guard let id = message["id"] else { return }
                geminiElicitation(id: id, params: message["params"] ?? [:])
            default:
                // Requests we don't serve (files, terminals: not offered at initialize).
                if let id = message["id"] { geminiProcess?.respondError(to: id, code: -32601, message: "Not supported by Chatterbox.") }
            }
            return
        }
        // A reply. Only a prompt's carries a stop reason: the turn is over.
        if let stop = message["result"]?["stopReason"]?.string {
            finishGeminiTurn(stopReason: stop, usage: message["result"]?["usage"])
        } else if let error = message["error"], isRunning, message["id"] != nil, geminiTextItems.isEmpty, geminiToolItems.isEmpty {
            // A prompt agy refused outright (quota, sign-in).
            notice("Gemini reported a problem: \(error["message"]?.string ?? "unknown error")")
            finishGeminiTurn(stopReason: "error", usage: nil)
        }
    }

    private func geminiUpdate(_ update: JSON) {
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            guard let text = update["content"]?["text"]?.string else { return }
            if !isRunning { isRunning = true }
            geminiThoughtItem = nil
            if let item = geminiTextItem {
                updateItem(item) { $0.text += text }
            } else {
                let item = appendItem(DisplayItem(kind: .assistant, text: text, phase: .streaming))
                geminiTextItem = item
                geminiTextItems.append(item)
            }
        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.string else { return }
            if let item = geminiThoughtItem {
                updateItem(item) { $0.text += text }
            } else {
                geminiThoughtItem = appendItem(DisplayItem(kind: .thought, text: text))
            }
        case "tool_call":
            guard let callID = update["toolCallId"]?.string else { return }
            // Anything said before a tool call was narration, not the answer.
            markGeminiTextAsCommentary()
            geminiTextItem = nil
            geminiThoughtItem = nil
            if let item = geminiToolItems[callID] {
                updateItem(item) { Self.applyGeminiTool(update, to: &$0) }
            } else {
                var row = DisplayItem(kind: .tool, text: Self.geminiToolLabel(update))
                Self.applyGeminiTool(update, to: &row)
                geminiToolItems[callID] = appendItem(row)
            }
        case "tool_call_update":
            guard let callID = update["toolCallId"]?.string, let item = geminiToolItems[callID] else { return }
            updateItem(item) { Self.applyGeminiTool(update, to: &$0) }
            if update["status"]?.string == "completed", update["kind"]?.string == "edit",
               let path = update["locations"]?.array?.first?["path"]?.string {
                showWrittenFile(path)
            }
        case "plan":
            let steps = (update["entries"]?.array ?? []).compactMap { entry -> PlanStep? in
                guard let text = entry["content"]?.string else { return nil }
                return PlanStep(step: text, status: entry["status"]?.string ?? "pending")
            }
            showPlan(steps)
        case "usage_update":
            if let used = update["used"]?.int, used > 0 {
                contextUsage[.gemini] = ContextUsage(used: used, window: update["size"]?.int ?? contextUsage[.gemini]?.window)
            }
        default:
            break
        }
    }

    /// "Edit hello.txt", "Run npm test": agy's own title for the call.
    static func geminiToolLabel(_ call: JSON) -> String {
        let title = call["title"]?.string ?? call["name"]?.string ?? "Tool"
        // agy titles a file "File hello.txt", or by a path relative to where it ran from
        // ("File ../../../../tmp/…"): named here by what's done to it.
        if let path = call["locations"]?.array?.first?["path"]?.string {
            let name = URL(fileURLWithPath: path).lastPathComponent
            switch call["kind"]?.string {
            case "edit": return "Edit \(name)"
            case "read": return "Read \(name)"
            case "delete": return "Delete \(name)"
            default: break
            }
        }
        return title
    }

    private static func applyGeminiTool(_ call: JSON, to row: inout DisplayItem) {
        if call["title"] != nil { row.text = geminiToolLabel(call) }
        switch call["status"]?.string {
        case "completed": row.toolState = .done
        case "failed": row.toolState = .failed
        default: break
        }
    }

    private func markGeminiTextAsCommentary() {
        for id in geminiTextItems {
            updateItem(id) { if $0.phase == .streaming { $0.phase = .commentary } }
        }
    }

    func geminiResetTurn() {
        geminiTextItem = nil
        geminiThoughtItem = nil
        geminiTextItems = []
        geminiToolItems = [:]
        geminiStopRequested = false
    }

    func finishGeminiTurn(stopReason: String, usage: JSON?) {
        for id in geminiTextItems {
            updateItem(id) { if $0.phase != .final { $0.phase = .final } }
        }
        record.items.removeAll {
            ($0.kind == .assistant || $0.kind == .thought) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if geminiStopRequested || stopReason == "cancelled" {
            notice(stoppingToSend ? "Stopped to take your message." : "Stopped.")
            stoppingToSend = false
            markRunningToolsFailed()
        } else if stopReason == "refusal" {
            notice("Gemini declined to continue.")
        } else if stopReason == "max_tokens" || stopReason == "max_turn_requests" {
            notice("Gemini stopped at its limit for one reply. Send a message to continue.")
        }
        markRunningToolsFailed()
        expirePendingApprovals()
        geminiResetTurn()
        isRunning = false
        record.updatedAt = Date()
        turnEnded()
        onChange?(self)
        sendNextQueuedGemini()
    }

    private func geminiProcessExited(status: Int32, detail: String) {
        geminiProcess = nil
        geminiSessionReady = false
        let lower = detail.lowercased()
        if lower.contains("login") || lower.contains("sign in") || lower.contains("auth") {
            notice("Gemini needs you to sign in: run `agy` in Terminal and log in with Google, then send your message again.")
        } else if isRunning || status != 0 {
            notice("Gemini stopped unexpectedly (exit \(status))\(detail.isEmpty ? "." : ": \(detail)")")
        }
        markRunningToolsFailed()
        expirePendingApprovals()
        clearQueuedMessages()
        geminiQueue = []
        geminiResetTurn()
        isRunning = false
        onChange?(self)
    }

    // MARK: - Permission requests

    /// agy asks before an edit or command (per the mode). Bypass approves it here; otherwise
    /// a card asks you, keeping the whole request so answering never depends on memory.
    private func geminiPermission(id: JSON, params: JSON) {
        let options = params["options"]?.array ?? []
        let allowID = options.first { $0["kind"]?.string == "allow_once" }?["optionId"]?.string
            ?? options.first { $0["kind"]?.string?.hasPrefix("allow") == true }?["optionId"]?.string
        if geminiModeID == "bypass", let allowID {
            geminiProcess?.respond(to: id, ["outcome": ["outcome": "selected", "optionId": .string(allowID)]])
            return
        }
        let call = params["toolCall"] ?? [:]
        let title = "Gemini wants to " + Self.geminiToolLabel(call).prefix(1).lowercased() + Self.geminiToolLabel(call).dropFirst()
        var detail: [String] = []
        for content in call["content"]?.array ?? [] where content["type"]?.string == "diff" {
            let path = content["path"]?.string ?? ""
            detail.append(path + "\n" + (content["newText"]?.string ?? "").prefix(2000))
        }
        if detail.isEmpty, let input = call["rawInput"] ?? call["args"], let text = try? input.encoded() {
            detail.append(String(decoding: text, as: UTF8.self).prefix(2000).description)
        }
        let payload: JSON = ["id": id, "options": .array(options)]
        appendItem(DisplayItem(kind: .approval, text: title, detail: detail.isEmpty ? nil : detail.joined(separator: "\n\n"),
                               requestID: payload, approvalState: .pending))
        onChange?(self)
    }

    func geminiResolveApproval(_ itemID: UUID, _ decision: DisplayItem.ApprovalState) {
        guard let item = record.items.first(where: { $0.id == itemID }), item.approvalState == .pending,
              let payload = item.requestID, let requestID = payload["id"] else { return }
        guard let process = geminiProcess, process.isRunning else {
            updateItem(itemID) { $0.approvalState = .expired }
            notice("That request is no longer active, because Gemini restarted. Ask again to continue.")
            onChange?(self)
            return
        }
        let options = payload["options"]?.array ?? []
        func option(_ kinds: [String]) -> String? {
            for kind in kinds { if let id = options.first(where: { $0["kind"]?.string == kind })?["optionId"]?.string { return id } }
            return nil
        }
        let chosen: String?
        switch decision {
        case .approvedForSession: chosen = option(["allow_always", "allow_once"])
        case .approved: chosen = option(["allow_once", "allow_always"])
        default: chosen = option(["reject_once", "reject_always"])
        }
        if let chosen {
            process.respond(to: requestID, ["outcome": ["outcome": "selected", "optionId": .string(chosen)]])
        } else {
            process.respond(to: requestID, ["outcome": ["outcome": "cancelled"]])
        }
        updateItem(itemID) { $0.approvalState = decision }
        onChange?(self)
    }

    // MARK: - Questions (ACP elicitation/create)

    /// Maps an ACP `elicitation/create` form schema (such as agy's `ask_question` tool) onto a
    /// standard question card, keeping the field metadata on the item so answering never depends
    /// on in-memory state.
    private func geminiElicitation(id: JSON, params: JSON) {
        let properties = params["requestedSchema"]?["properties"]?.object ?? [:]
        // Pair `<key>` with `<key>_other` (agy's optional free-form companion field).
        let primaryKeys = properties.keys
            .filter { key in
                guard key.hasSuffix("_other") else { return true }
                let base = String(key.dropLast("_other".count))
                return properties[base] == nil
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var questions: [AgentQuestion] = []
        var fieldsMeta: [String: JSON] = [:]

        for key in primaryKeys {
            guard let prop = properties[key] else { continue }
            let isArray = prop["type"]?.string == "array"
            let rawChoices = isArray
                ? (prop["items"]?["anyOf"]?.array ?? prop["items"]?["oneOf"]?.array ?? [])
                : (prop["oneOf"]?.array ?? prop["anyOf"]?.array ?? [])
            var options: [AgentQuestion.Option] = []
            var valueMap: [String: JSON] = [:]
            if !rawChoices.isEmpty {
                for choice in rawChoices {
                    let const = choice["const"]?.string ?? choice["title"]?.string ?? ""
                    let title = choice["title"]?.string ?? const
                    guard !title.isEmpty else { continue }
                    options.append(.init(label: title, detail: choice["description"]?.string ?? ""))
                    valueMap[title] = .string(const)
                }
            } else {
                let enumValues = (isArray ? prop["items"]?["enum"]?.array : prop["enum"]?.array) ?? []
                for entry in enumValues {
                    guard let value = entry.string, !value.isEmpty else { continue }
                    options.append(.init(label: value, detail: ""))
                    valueMap[value] = .string(value)
                }
            }
            let promptText = prop["title"]?.string ?? prop["description"]?.string ?? key
            let otherKey = properties[key + "_other"] != nil ? (key + "_other") : nil
            questions.append(AgentQuestion(id: key, header: "", question: promptText, options: options,
                                           multiSelect: isArray, isSecret: false))
            var meta: [String: JSON] = ["isArray": .bool(isArray), "map": .object(valueMap)]
            if let otherKey { meta["otherKey"] = .string(otherKey) }
            fieldsMeta[key] = .object(meta)
        }

        guard !questions.isEmpty else {
            geminiProcess?.respond(to: id, ["action": "decline"])
            return
        }
        let payload: JSON = ["id": id, "fields": .object(fieldsMeta)]
        appendItem(DisplayItem(kind: .questions, requestID: payload, approvalState: .pending, questions: questions))
        onChange?(self)
    }

    /// Sends answers (or a decline when skipped) back to an ACP `elicitation/create` request.
    func geminiAnswer(_ itemID: UUID, answers: [String: [String]]?) {
        guard let item = record.items.first(where: { $0.id == itemID }), item.approvalState == .pending,
              let payload = item.requestID, let requestID = payload["id"] else { return }
        guard let process = geminiProcess, process.isRunning else {
            updateItem(itemID) { $0.approvalState = .expired }
            notice("That request is no longer active, because Gemini restarted. Ask again to continue.")
            onChange?(self)
            return
        }
        if let answers {
            let fields = payload["fields"]?.object ?? [:]
            var content: [String: JSON] = [:]
            for (key, selected) in answers where !selected.isEmpty {
                let meta = fields[key]?.object ?? [:]
                let isArray = meta["isArray"]?.bool ?? false
                let otherKey = meta["otherKey"]?.string
                let valueMap = meta["map"]?.object ?? [:]
                var mapped: [String] = []
                var custom: [String] = []
                for choice in selected {
                    if let const = valueMap[choice]?.string {
                        mapped.append(const)
                    } else {
                        custom.append(choice)
                    }
                }
                if isArray {
                    if !mapped.isEmpty { content[key] = .array(mapped.map(JSON.string)) }
                    if !custom.isEmpty {
                        if let otherKey { content[otherKey] = .string(custom.joined(separator: ", ")) }
                        else { content[key] = .array((mapped + custom).map(JSON.string)) }
                    }
                } else {
                    if let first = mapped.first { content[key] = .string(first) }
                    if !custom.isEmpty {
                        if let otherKey { content[otherKey] = .string(custom.joined(separator: ", ")) }
                        else { content[key] = .string(custom.joined(separator: ", ")) }
                    }
                }
            }
            process.respond(to: requestID, ["action": "accept", "content": .object(content)])
        } else {
            process.respond(to: requestID, ["action": "decline"])
        }
        updateItem(itemID) {
            $0.answers = answers
            $0.approvalState = answers == nil ? .denied : .approved
        }
        onChange?(self)
    }
}
