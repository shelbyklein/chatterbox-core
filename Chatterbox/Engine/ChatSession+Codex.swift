import Foundation

/// The Codex backend. Codex runs its own agent loop and keeps the history, so this
/// side only starts turns, steers and interrupts them, answers approval requests,
/// and maps Codex's item events onto the same transcript rows Claude uses.
extension ChatSession {
    private var server: CodexAppServer { .shared }

    // MARK: - Settings

    func setCodexFolder(_ path: String) {
        if let remoteCommand {remoteCommand("settings",["codexFolder":.string(path)]);return}
        record.codex?.folder = path
        onChange?(self)
    }

    func setCodexModel(_ model: String?) {
        if let remoteCommand {remoteCommand("settings",["codexModel":model.map(JSON.string) ?? .null]);return}
        guard model != record.codex?.model else { return }
        record.codex?.model = model
        record.codex?.effort = nil
        noteSettingsChange()
        onChange?(self)
    }

    func setCodexEffort(_ effort: String?) {
        if let remoteCommand {remoteCommand("settings",["codexEffort":effort.map(JSON.string) ?? .null]);return}
        guard effort != record.codex?.effort else { return }
        record.codex?.effort = effort
        noteSettingsChange()
        onChange?(self)
    }

    // MARK: - Turns

    func setCodexFastMode(_ enabled: Bool) {
        if let remoteCommand {remoteCommand("settings",["fastMode":.bool(enabled)]);return}
        guard record.codex != nil, record.codex?.fastMode != enabled else { return }
        record.codex?.fastMode = enabled
        noteSettingsChange()
        onChange?(self)
    }

    func codexSend(_ message: UserMessage) {
        if isRunning {
            // Codex supports steering natively: the text joins the running turn.
            let item = appendUserItem(message, steered: true)
            if let turn = codexTurnID {
                Task { await codexSteer(message, turn: turn, item: item) }
            } else {
                pendingSteering.append(message)
                pendingSteeringItems.append(item)
            }
            return
        }
        setTitleIfNeeded(message)
        appendUserItem(message)
        beginCodexTurn(message)
    }

    /// `items` are queued rows this turn delivers, e.g. messages that missed the last turn.
    private func beginCodexTurn(_ message: UserMessage, items: [UUID] = []) {
        isRunning = true
        codexTurnID = nil
        codexStopRequested = false
        codexTurnMessageItems = []
        onChange?(self)
        Task { await codexStartTurn(message, items: items) }
    }

    func codexInterrupt() {
        guard let thread = record.codex?.threadId, let turn = codexTurnID else {
            codexStopRequested = true
            return
        }
        Task { try? await server.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)]) }
    }

    /// Codex's process is shared. Stop this turn and explicitly resume the same thread;
    /// do not terminate the server, archive it, or fall back to a different conversation.
    func codexRestartThread() async throws {
        guard let settings = record.codex else { throw CodexError(message: "This chat isn't set up for Codex.") }
        let deadline = Date().addingTimeInterval(10)
        while isRunning, codexTurnID == nil {
            guard Date() < deadline else { throw CodexError(message: "The current turn hasn't connected yet. Try Stop, then restart again.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        if isRunning, let thread = record.codex?.threadId, let turn = codexTurnID {
            _ = try await CodexAppServer.shared.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)], timeout: .seconds(10))
            let stopDeadline = Date().addingTimeInterval(10)
            while isRunning {
                guard Date() < stopDeadline else { throw CodexError(message: "The current reply hasn't stopped. Reconnection was cancelled to avoid overlapping replies.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard let thread = record.codex?.threadId else { return }
        codexRegisterHandler(thread)
        var params = codexThreadParams(settings)
        params["threadId"] = .string(thread)
        params["excludeTurns"] = true
        let result = try await CodexAppServer.shared.request("thread/resume", .object(params), timeout: .seconds(10))
        guard result["thread"]?["id"]?.string == thread else { throw CodexError(message: "Codex didn't reconnect to the original thread.") }
        CodexAppServer.shared.markLoaded(thread)
        codexDotConfiguration = codexConfigurationKey
    }

    private func codexStartTurn(_ message: UserMessage, items: [UUID]) async {
        guard let settings = record.codex else { return }
        do {
            let thread = try await codexEnsureThread()
            var input: [JSON] = []
            if record.sentPersonality != record.personality {
                input.append(Self.textInput(Prompts.personalitySpec(record.personality)))
                record.sentPersonality = record.personality
            }
            if let shell = takeShellContext() { input.append(Self.textInput(shell)) }
            if let handoff = record.pendingHandoff {
                input.append(Self.textInput(handoff))
                record.pendingHandoff = nil
            }
            if (record.instructionsVersion ?? 1) < Prompts.instructionsVersion {
                input.append(Self.textInput(Prompts.instructionsUpdate))
                record.instructionsVersion = Prompts.instructionsVersion
            }
            let user = Prompts.userInstructions
            if user != (record.sentUserInstructions ?? "") {
                input.append(Self.textInput(Prompts.userInstructionsUpdate(user)))
                record.sentUserInstructions = user
            }
            if let studioUpdate = takeStudioInstructionsUpdate() { input.append(Self.textInput(studioUpdate)) }
            if let secrets = takeSecretsUpdate() { input.append(Self.textInput(secrets)) }
            if let computer = takeComputerUpdate() { input.append(Self.textInput(computer)) }
            if let route = takeCodexRouteUpdate() { input.append(Self.textInput(route)) }
            input += inputs(for: message)

            var params: [String: JSON] = [
                "threadId": .string(thread),
                "input": .array(input),
                "cwd": .string(settings.folder),
                "approvalPolicy": approvalPolicy(settings),
                "approvalsReviewer": settings.modeID == "autoReview" ? "auto_review" : "user",
                "sandboxPolicy": sandboxPolicy(settings),
            ]
            if let model = settings.model { params["model"] = .string(model) }
            if let effort = settings.effort { params["effort"] = .string(effort) }
            // Explicit standard resets any tier inherited by a resumed/forked thread.
            params["serviceTier"] = .string(settings.fastMode == true ? "fast" : "default")

            let result = try await server.request("turn/start", .object(params))
            items.forEach(markPickedUp)
            if isRunning, codexTurnID == nil { codexTurnID = result["turn"]?["id"]?.string }
            codexTurnDidGetID()
        } catch {
            notice("Codex couldn't start: \(error.localizedDescription)")
            codexFinish(startQueued: false)
        }
    }

    private func codexEnsureThread() async throws -> String {
        guard let settings = record.codex else { throw CodexError(message: "This chat isn't set up for Codex.") }
        try await server.ensureStarted()

        // A forked chat branches its source thread, keeping everything Codex knew.
        if settings.threadId == nil, let source = settings.forkFrom {
            record.codex?.forkFrom = nil
            do {
                var params = codexThreadParams(settings)
                params["threadId"] = .string(source)
                params["excludeTurns"] = true
                let result = try await server.request("thread/fork", .object(params))
                if let id = result["thread"]?["id"]?.string {
                    record.codex?.threadId = id
                    codexRegisterHandler(id)
                    server.markLoaded(id)
                    codexDotConfiguration = codexConfigurationKey
                    onChange?(self)
                    return id
                }
            } catch {
                // Fall back to a new thread caught up on the conversation.
                let transcript = Self.transcript(record.items[...])
                if !transcript.isEmpty, record.pendingHandoff == nil {
                    record.pendingHandoff = Prompts.handoff(from: "", transcript: transcript, isWholeConversation: true)
                }
            }
        }

        if let existing = settings.threadId {
            codexRegisterHandler(existing)
            if server.loadedThreads.contains(existing), codexDotConfiguration == codexConfigurationKey { return existing }
            do {
                var params: [String: JSON] = [
                    "threadId": .string(existing), "cwd": .string(settings.folder), "excludeTurns": true,
                ]
                let threadParams = codexThreadParams(settings)
                params["config"] = threadParams["config"]
                if isDot { params["developerInstructions"] = threadParams["developerInstructions"] }
                _ = try await server.request("thread/resume", .object(params))
                server.markLoaded(existing)
                codexDotConfiguration = codexConfigurationKey
                return existing
            } catch {
                notice("Couldn't reopen the earlier Codex session, so this continues in a new one.")
                record.codex?.threadId = nil
            }
        }

        let result = try await server.request("thread/start", .object(codexThreadParams(settings)))
        guard let id = result["thread"]?["id"]?.string else { throw CodexError(message: "Codex didn't return a thread.") }
        record.codex?.threadId = id
        record.sentPersonality = record.personality
        record.sentUserInstructions = Prompts.userInstructions
        record.sentStudioInstructions = studio?.noteKey ?? ""
        record.instructionsVersion = Prompts.instructionsVersion
        codexRegisterHandler(id)
        server.markLoaded(id)
        codexDotConfiguration = codexConfigurationKey
        onChange?(self)
        return id
    }

    /// Settings for a new (or forked) thread.
    private func codexThreadParams(_ settings: CodexSettings) -> [String: JSON] {
        var params: [String: JSON] = [
            "cwd": .string(settings.folder),
            "approvalPolicy": approvalPolicy(settings),
            "sandbox": .string(["readOnly": "read-only", "fullAccess": "danger-full-access"][settings.modeID] ?? "workspace-write"),
            "developerInstructions": .string(Prompts.fullInstructions(record.personality, backend: .codex, projectFolder: record.boundFolder,
                                                                         studio: studio)),
        ]
        if let model = settings.model { params["model"] = .string(model) }
        if isDot {
            guard let instructions = params["developerInstructions"]?.string else { return params }
            params["developerInstructions"] = .string(instructions + "\n\n" + dotCodexInstructions)
            params["config"] = dotCodexConfig
        } else {
            // Always explicit, so a thread that used another connection switches cleanly.
            params["config"] = .object(codexConnection.config)
        }
        // The agent computer's tools, when this chat uses it.
        let computer = codexComputerConfig
        if !computer.isEmpty {
            var config = params["config"]?.object ?? [:]
            for (key, value) in computer { config[key] = value }
            params["config"] = .object(config)
        }
        // Saved secrets in scope, as variables for the commands this thread runs.
        let secrets = SecretVault.shared.environment(for: self)
        if !secrets.isEmpty {
            var config = params["config"]?.object ?? [:]
            config["shell_environment_policy.set"] = .object(secrets.mapValues { .string($0) })
            params["config"] = .object(config)
        }
        return params
    }

    /// What the thread was loaded with; a change (the proxy switched on or off) reloads it.
    var codexConfigurationKey: String {
        let secrets = "|secrets:" + SecretVault.shared.fingerprint(for: self)
        if isDot { return dotCodexConfigurationKey + secrets }
        let computer = computerConfigurationKey.isEmpty ? "" : "|" + computerConfigurationKey
        return codexConnection.key + secrets + computer
    }

    /// Routes the thread's events to this chat. After a relaunch, lines the saved transcript
    /// already reflects are skipped.
    func codexRegisterHandler(_ thread: String) {
        server.register(thread: thread) { [weak self] method, params, requestID in
            guard let self else { return }
            if let skipped = self.codexSkipProcess {
                if skipped == self.server.hostID, self.server.currentLineEnd <= self.codexSkipThrough { return }
                self.codexSkipProcess = nil
            }
            self.handleCodex(method: method, params: params, requestID: requestID)
            self.onStreamed?(self)
        }
    }

    private func codexSteer(_ message: UserMessage, turn: String, item: UUID) async {
        guard let thread = record.codex?.threadId else { return }
        do {
            _ = try await server.request("turn/steer", [
                "threadId": .string(thread), "input": .array(inputs(for: message)), "expectedTurnId": .string(turn),
            ])
            markPickedUp(item)
        } catch {
            // The turn most likely finished a moment ago; send the text as a new turn.
            if isRunning {
                pendingSteering.append(message)
                pendingSteeringItems.append(item)
            } else {
                beginCodexTurn(message, items: [item])
            }
        }
    }

    /// Images go to Codex as local images; other files are named by path so Codex can open them.
    /// A leading "/skill" becomes a skill input, which Codex loads before reading the text.
    private func inputs(for message: UserMessage) -> [JSON] {
        var input: [JSON] = message.attachments.filter { $0.kind == .image }.map {
            ["type": "localImage", "path": .string($0.path)]
        }
        let files = message.attachments.filter { $0.kind != .image }
        var text = message.text
        let skills = record.codex.map { server.skills[$0.folder] ?? [] } ?? []
        if let (skill, rest) = SlashCommand.leading(text, in: skills), let path = skill.codexSkillPath {
            input.append(["type": "skill", "name": .string(skill.name), "path": .string(path)])
            text = rest.isEmpty ? "Use the \(skill.name) skill." : rest
        }
        if !files.isEmpty {
            let list = files.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
            text += (text.isEmpty ? "" : "\n\n") + "Attached files (read them from these paths):\n" + list
        }
        if !text.isEmpty { input.append(Self.textInput(text)) }
        return input
    }

    private func codexTurnDidGetID() {
        guard isRunning, let turn = codexTurnID else { return }
        if codexStopRequested {
            codexInterrupt()
            return
        }
        let queued = zip(pendingSteering, pendingSteeringItems)
        pendingSteering.removeAll()
        pendingSteeringItems.removeAll()
        for (message, item) in queued { Task { await codexSteer(message, turn: turn, item: item) } }
    }

    private func codexFinish(startQueued: Bool) {
        record.items.removeAll {
            ($0.kind == .assistant || $0.kind == .thought) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Commands still running when the reply ends keep going in the background, watched
        // by their process in case Codex stopped them along with the reply.
        var carriedOn: Set<UUID> = []
        for (itemID, command) in codexRunningCommands {
            guard let row = codexItems[itemID], command.processID != nil else { continue }
            carriedOn.insert(row)
            addBackgroundTask(BackgroundTask(id: itemID, kind: .shell, title: command.command, detached: true,
                                             processID: command.processID, rowID: row))
        }
        codexRunningCommands = [:]
        for index in record.items.indices {
            if record.items[index].kind == .tool, record.items[index].toolState == .running,
               !carriedOn.contains(record.items[index].id) {
                record.items[index].toolState = .failed
            }
            if record.items[index].approvalState == .pending {
                record.items[index].approvalState = .expired
            }
        }
        isRunning = false
        codexTurnID = nil
        codexItems = [:]
        record.updatedAt = Date()
        turnEnded()
        let queued = UserMessage(text: pendingSteering.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                 attachments: pendingSteering.flatMap(\.attachments))
        let queuedItems = pendingSteeringItems
        pendingSteering.removeAll()
        pendingSteeringItems.removeAll()
        if startQueued, !isRestartingThread, !queued.text.isEmpty || !queued.attachments.isEmpty {
            onChange?(self)
            beginCodexTurn(queued, items: queuedItems)
        } else {
            queuedItems.forEach(markPickedUp)
            onChange?(self)
        }
    }

    // MARK: - Events

    private func handleCodex(method: String, params: JSON, requestID: JSON?) {
        if let requestID {
            handleCodexRequest(method: method, params: params, id: requestID)
            return
        }
        switch method {
        case "turn/started":
            if isRunning, codexTurnID == nil {
                codexTurnID = params["turn"]?["id"]?.string
                codexTurnDidGetID()
            }

        case "item/started":
            codexItemStarted(params["item"])

        case "item/agentMessage/delta":
            if let itemID = params["itemId"]?.string, let id = codexItems[itemID], let delta = params["delta"]?.string {
                updateItem(id) { $0.text += delta }
            }

        case "item/reasoning/summaryTextDelta":
            guard let itemID = params["itemId"]?.string, let delta = params["delta"]?.string else { break }
            let id = codexItems[itemID] ?? {
                let new = appendItem(DisplayItem(kind: .thought))
                codexItems[itemID] = new
                return new
            }()
            updateItem(id) { $0.text += delta }

        case "item/completed":
            codexItemCompleted(params["item"])

        case "turn/plan/updated":
            let steps = (params["plan"]?.array ?? []).compactMap { step -> PlanStep? in
                guard let text = step["step"]?.string else { return nil }
                let status = step["status"]?.string == "inProgress" ? "in_progress" : (step["status"]?.string ?? "pending")
                return PlanStep(step: text, status: status)
            }
            let turn = params["turnId"]?.string ?? ""
            if let id = codexPlanItems[turn] {
                updateItem(id) { $0.planSteps = steps }
            } else if !steps.isEmpty {
                codexPlanItems[turn] = appendItem(DisplayItem(kind: .plan, planSteps: steps))
            }

        case "serverRequest/resolved":
            if let requestID = params["requestId"],
               let index = record.items.lastIndex(where: { $0.requestID == requestID && $0.approvalState == .pending }) {
                record.items[index].approvalState = .expired
            }

        case "error":
            if params["willRetry"] != .bool(true), let message = params["error"]?["message"]?.string {
                notice("Codex: \(message)")
            }

        case "turn/completed":
            codexTurnCompleted(params["turn"])

        case "thread/tokenUsage/updated":
            codexUpdateContext(params)

        case "chatterbox/processExited":
            clearBackgroundTasks()
            if isRunning {
                notice(params["message"]?.string ?? "Codex stopped unexpectedly.")
                codexFinish(startQueued: false)
            }

        default:
            break
        }
    }

    private func codexItemStarted(_ item: JSON?) {
        guard let item, let type = item["type"]?.string, let itemID = item["id"]?.string else { return }
        codexTrackHelpers(item)
        if type == "commandExecution" {
            codexRunningCommands[itemID] = (Self.shortCommand(item["command"]?.string ?? ""),
                                            item["processId"]?.string.flatMap { Int32($0) })
        }
        switch type {
        case "agentMessage":
            let phase: DisplayItem.Phase = item["phase"]?.string == "commentary" ? .commentary : .streaming
            let id = appendItem(DisplayItem(kind: .assistant, text: item["text"]?.string ?? "", phase: phase))
            codexItems[itemID] = id
            codexTurnMessageItems.append(id)
        case "reasoning":
            if codexItems[itemID] == nil { codexItems[itemID] = appendItem(DisplayItem(kind: .thought)) }
        default:
            if let label = Self.label(for: item) {
                codexItems[itemID] = appendItem(DisplayItem(kind: .tool, text: label))
            }
        }
    }

    private func codexItemCompleted(_ item: JSON?) {
        guard let item, let type = item["type"]?.string, let itemID = item["id"]?.string else { return }
        codexTrackHelpers(item)
        codexRunningCommands[itemID] = nil
        // A background command from an earlier reply has ended.
        if let task = backgroundTasks.first(where: { $0.id == itemID }) {
            let failed = item["status"]?.string != "completed"
            if let row = task.rowID, let label = Self.label(for: item) { updateItem(row) { $0.text = label } }
            finishBackgroundTask(itemID, failed: failed)
            return
        }
        guard let id = codexItems[itemID] else {
            // A message can finish without a start event; show it anyway.
            if type == "agentMessage", let text = item["text"]?.string, !text.isEmpty {
                let phase: DisplayItem.Phase = item["phase"]?.string == "commentary" ? .commentary : .streaming
                let id = appendItem(DisplayItem(kind: .assistant, text: text, phase: phase))
                codexItems[itemID] = id
                codexTurnMessageItems.append(id)
            }
            if type == "imageGeneration", item["failure"].map({ $0 == .null }) ?? true { showGeneratedImage(item) }
            return
        }
        switch type {
        case "agentMessage":
            updateItem(id) {
                if let text = item["text"]?.string, !text.isEmpty { $0.text = text }
                switch item["phase"]?.string {
                case "commentary": $0.phase = .commentary
                case "final_answer": $0.phase = .final
                default: break
                }
            }
        case "reasoning":
            let summary = (item["summary"]?.array ?? []).compactMap(\.string).joined(separator: "\n\n")
            if !summary.isEmpty { updateItem(id) { $0.text = summary } }
        case "imageGeneration":
            let failed = item["failure"].map { $0 != .null } ?? false
            updateItem(id) { $0.toolState = failed ? .failed : .done }
            if !failed { showGeneratedImage(item) }
        case "fileChange":
            let status = item["status"]?.string
            updateItem(id) {
                if let label = Self.label(for: item) { $0.text = label }
                $0.toolState = (status == nil || status == "completed") ? .done : .failed
            }
            // Pages, pictures, and animations it wrote show in the reply, as with Claude.
            if status == nil || status == "completed" {
                for change in item["changes"]?.array ?? [] {
                    guard change["kind"]?["type"]?.string != "delete", let path = change["path"]?.string else { continue }
                    showWrittenFile(path)
                }
            }
        default:
            let status = item["status"]?.string
            updateItem(id) {
                if let label = Self.label(for: item) { $0.text = label }
                $0.toolState = (status == nil || status == "completed") ? .done : .failed
            }
        }
    }

    /// Copies a generated image into the attachment store and shows it in the chat.
    /// Codex saves it to disk (`savedPath`) and also returns it inline (`result`, base64).
    private func showGeneratedImage(_ item: JSON) {
        var attachment: Attachment?
        if let path = item["savedPath"]?.string, FileManager.default.fileExists(atPath: path) {
            attachment = try? Attachments.importFile(URL(fileURLWithPath: path))
        }
        if attachment == nil, let base64 = item["result"]?.string,
           let data = Data(base64Encoded: base64.replacingOccurrences(of: #"^data:image/\w+;base64,"#, with: "", options: .regularExpression)) {
            attachment = try? Attachments.importImageData(data, name: "Generated image")
        }
        guard let attachment else { return }
        appendItem(DisplayItem(kind: .image, text: item["revisedPrompt"]?.string ?? "", attachments: [attachment]))
        onChange?(self)
    }

    private func codexTurnCompleted(_ turn: JSON?) {
        // Messages without an explicit phase: the last one is the answer, the rest narration.
        let unresolved = codexTurnMessageItems.filter { id in record.items.contains { $0.id == id && $0.phase == .streaming } }
        for (index, id) in unresolved.enumerated() {
            updateItem(id) { $0.phase = index == unresolved.count - 1 ? .final : .commentary }
        }
        switch turn?["status"]?.string {
        case "interrupted":
            notice(stoppingToSend ? "Stopped to take your message." : "Stopped.")
            // "Send Now": the queued message starts the next turn right away.
            let sendQueued = stoppingToSend
            stoppingToSend = false
            codexFinish(startQueued: sendQueued)
        case "failed":
            notice("Codex hit an error: \(turn?["error"]?["message"]?.string ?? "unknown error")")
            codexFinish(startQueued: false)
        default:
            codexFinish(startQueued: true)
        }
    }

    // MARK: - Approvals

    private func handleCodexRequest(method: String, params: JSON, id: JSON) {
        switch method {
        case "item/tool/requestUserInput":
            let questions = (params["questions"]?.array ?? []).enumerated().map { index, q in
                AgentQuestion(id: q["id"]?.string ?? "q\(index)", header: q["header"]?.string ?? "",
                              question: q["question"]?.string ?? "",
                              options: (q["options"]?.array ?? []).map { .init(label: $0["label"]?.string ?? "", detail: $0["description"]?.string ?? "") },
                              multiSelect: false, isSecret: q["isSecret"]?.bool ?? false)
            }
            appendItem(DisplayItem(kind: .questions, requestID: id, approvalState: .pending, questions: questions))
        case "item/commandExecution/requestApproval":
            let reason = params["reason"]?.string
            appendItem(DisplayItem(
                kind: .approval,
                text: reason ?? "Codex wants to run a command",
                detail: params["command"]?.string,
                requestID: id,
                approvalState: .pending
            ))
        case "item/fileChange/requestApproval":
            let files = params["itemId"]?.string.flatMap { codexItems[$0] }
                .flatMap { itemID in record.items.first { $0.id == itemID }?.text }
            appendItem(DisplayItem(
                kind: .approval,
                text: params["reason"]?.string ?? "Codex wants to change files",
                detail: files,
                requestID: id,
                approvalState: .pending
            ))
        default:
            server.respondError(to: id, message: "Chatterbox can't answer \(method) yet.")
        }
        onChange?(self)
    }

    /// Sends answers keyed by question id; skipping sends none.
    func codexAnswer(_ itemID: UUID, answers: [String: [String]]?) {
        guard let item = record.items.first(where: { $0.id == itemID }),
              item.approvalState == .pending, let requestID = item.requestID else { return }
        let wire = (answers ?? [:]).mapValues { JSON.object(["answers": .array($0.map(JSON.string))]) }
        server.respond(to: requestID, result: ["answers": .object(wire)])
        updateItem(itemID) {
            $0.answers = answers
            $0.approvalState = answers == nil ? .denied : .approved
        }
        onChange?(self)
    }

    func codexResolveApproval(_ itemID: UUID, _ decision: DisplayItem.ApprovalState) {
        guard let item = record.items.first(where: { $0.id == itemID }),
              item.approvalState == .pending, let requestID = item.requestID else { return }
        let wire: String
        switch decision {
        case .approved: wire = "accept"
        case .approvedForSession: wire = "acceptForSession"
        default: wire = "decline"
        }
        server.respond(to: requestID, result: ["decision": .string(wire)])
        updateItem(itemID) { $0.approvalState = decision }
        onChange?(self)
    }

    // MARK: - Helpers

    private func sandboxPolicy(_ settings: CodexSettings) -> JSON {
        switch settings.modeID {
        case "fullAccess":
            return ["type": "dangerFullAccess"]
        case "readOnly":
            return ["type": "readOnly", "networkAccess": false]
        default:
            return [
                "type": "workspaceWrite",
                "writableRoots": [.string(settings.folder)],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            ]
        }
    }

    /// Full access never asks; every other mode asks (or lets the auto reviewer decide).
    private func approvalPolicy(_ settings: CodexSettings) -> JSON {
        settings.modeID == "fullAccess" ? "never" : "on-request"
    }

    private static func textInput(_ text: String) -> JSON {
        ["type": "text", "text": .string(text), "text_elements": []]
    }

    /// Status line for a Codex tool item, or nil for items that aren't shown.
    // MARK: - Helper agents

    /// Subagents show as background tasks while they work. Codex reports them two ways:
    /// `subAgentActivity` items, and the states in a `collabAgentToolCall` (spawnAgent, wait…).
    private func codexTrackHelpers(_ item: JSON) {
        switch item["type"]?.string {
        case "subAgentActivity":
            guard let thread = item["agentThreadId"]?.string else { return }
            switch item["kind"]?.string {
            case "started": codexHelperStarted(thread, name: Self.helperName(item))
            case "completed": finishBackgroundTask(thread)
            case "interrupted": finishBackgroundTask(thread, failed: true)
            default: break
            }
        case "collabAgentToolCall":
            for (thread, state) in item["agentsStates"]?.object ?? [:] {
                switch state["status"]?.string {
                case "pendingInit", "running":
                    let prompt = item["prompt"]?.string.map { $0.count > 60 ? String($0.prefix(59)) + "\u{2026}" : $0 }
                    codexHelperStarted(thread, name: prompt)
                case "completed": finishBackgroundTask(thread)
                case "errored", "interrupted", "shutdown", "notFound": finishBackgroundTask(thread, failed: true)
                default: break
                }
            }
        default:
            break
        }
    }

    /// Shows the helper and follows its own thread, whose events name what it's doing now.
    private func codexHelperStarted(_ thread: String, name: String?) {
        if !backgroundTasks.contains(where: { $0.id == thread }) {
            addBackgroundTask(BackgroundTask(id: thread, kind: .agent, title: name ?? "Helper agent", detached: true))
        }
        CodexAppServer.shared.register(thread: thread) { [weak self] method, params, requestID in
            self?.codexHelperEvent(thread, method: method, params: params, requestID: requestID)
        }
    }

    private func codexHelperEvent(_ thread: String, method: String, params: JSON, requestID: JSON?) {
        // A helper asking to run a command asks here, in the chat that started it.
        if requestID != nil {
            handleCodex(method: method, params: params, requestID: requestID)
            return
        }
        switch method {
        case "item/started":
            if let item = params["item"], let label = Self.label(for: item) {
                updateBackgroundTask(thread) { $0.detail = label }
            }
        case "turn/completed":
            finishBackgroundTask(thread, failed: params["turn"]?["status"]?.string == "failed")
        default:
            break
        }
    }

    /// "pong" for a helper at "/root/pong".
    private static func helperName(_ item: JSON) -> String? {
        guard let path = item["agentPath"]?.string, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    private static func shortCommand(_ command: String) -> String {
        // Codex wraps commands as `/bin/zsh -lc '…'`; the part inside is what was asked for.
        var text = command
        if let range = text.range(of: #"^/bin/(z|ba)?sh -lc '(.*)'$"#, options: .regularExpression) {
            text = String(text[range]).replacingOccurrences(of: #"^/bin/(z|ba)?sh -lc '"#, with: "", options: .regularExpression)
            text.removeLast()
        }
        return text.count > 80 ? String(text.prefix(79)) + "\u{2026}" : text
    }

    private static func label(for item: JSON) -> String? {
        switch item["type"]?.string {
        case "commandExecution":
            return "Running `\(shortCommand(item["command"]?.string ?? ""))`"
        case "fileChange":
            let paths = (item["changes"]?.array ?? []).compactMap { $0["path"]?.string }
            let names = paths.map { ($0 as NSString).lastPathComponent }
            if names.isEmpty { return "Editing files" }
            return "Editing " + (names.count > 3 ? names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more" : names.joined(separator: ", "))
        case "mcpToolCall":
            return "Using \(item["tool"]?.string ?? "a tool") from \(item["server"]?.string ?? "an MCP server")"
        case "dynamicToolCall":
            return "Using \(item["tool"]?.string ?? "a tool")"
        case "webSearch":
            if let query = item["query"]?.string, !query.isEmpty { return "Searching the web for \u{201C}\(query)\u{201D}" }
            return "Searching the web"
        case "imageGeneration":
            return "Generating an image"
        case "contextCompaction":
            return "Summarizing earlier conversation to make room"
        case "subAgentActivity":
            let name = helperName(item).map { " \u{201C}\($0)\u{201D}" } ?? ""
            switch item["kind"]?.string {
            case "started": return "Started helper agent\(name)"
            case "completed": return "Helper agent\(name) finished"
            case "interrupted": return "Helper agent\(name) stopped"
            default: return "Sent helper agent\(name) a message"
            }
        case "collabAgentToolCall":
            switch item["tool"]?.string {
            case "spawnAgent": return "Starting a helper agent"
            case "wait": return "Waiting on helper agents"
            case "closeAgent", "interruptAgent": return "Stopping a helper agent"
            case "listAgents": return "Checking on helper agents"
            default: return "Messaging a helper agent"
            }
        default:
            return nil
        }
    }
}
