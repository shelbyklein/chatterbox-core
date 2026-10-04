import Foundation

/// The Claude backend: the user's own Claude Code (`claude` CLI) in stream-json mode, one
/// process per chat. Claude Code runs the agent loop, tools, and history; this side sends
/// messages, answers permission prompts, and maps its stream onto the transcript.
extension ChatSession {
    // MARK: - Sending

    func claudeSend(_ message: UserMessage) {
        let steered = isRunning
        if !steered { setTitleIfNeeded(message) }
        let earlierItems = record.items.count
        appendUserItem(message, steered: steered)

        do {
            let process = try claudeEnsureProcess(earlierItems: earlierItems)
            var content: [JSON] = []
            if let shell = takeShellContext() { content.append(.text(shell)) }
            if let handoff = record.pendingHandoff {
                content.append(.text(handoff))
                record.pendingHandoff = nil
            }
            if record.sentPersonality != record.personality {
                content.append(.text(Prompts.personalitySpec(record.personality)))
                record.sentPersonality = record.personality
            }
            if (record.instructionsVersion ?? 1) < Prompts.instructionsVersion {
                content.append(.text(Prompts.instructionsUpdate))
                record.instructionsVersion = Prompts.instructionsVersion
            }
            let user = Prompts.userInstructions
            if user != (record.sentUserInstructions ?? "") {
                content.append(.text(Prompts.userInstructionsUpdate(user)))
                record.sentUserInstructions = user
            }
            if let studioUpdate = takeStudioInstructionsUpdate() { content.append(.text(studioUpdate)) }
            if let secrets = takeSecretsUpdate() { content.append(.text(secrets)) }
            if let computer = takeComputerUpdate() { content.append(.text(computer)) }
            // A resumed session keeps the name it started with, so a rename is said outright.
            if isDot, record.sentDotName != title {
                if record.sentDotName != nil {
                    content.append(.text("<app_note>\nThe user renamed you: your name is now \(title). Use it from here on.\n</app_note>"))
                }
                record.sentDotName = title
            }
            content += Attachments.claudeContent(for: message)
            claudeAwaitingEcho.append(message.text)
            process.sendUser(content)
            if !steered {
                isRunning = true
                claudeStopRequested = false
                claudePlanItem = nil
            }
        } catch {
            notice(error.localizedDescription)
        }
        onChange?(self)
    }

    /// Ends the Claude Code process (not the session) so the next message starts a fresh one
    /// with the current tools, resuming the same conversation. Waits for a reply in progress.
    func restartClaudeForNewTools() {
        if let remoteCommand {remoteCommand("restartTools",[:]);return}
        if isRunning { restartForToolsAfterTurn = true; return }
        guard let process = claudeProcess else { return }
        process.terminate()
        claudeProcess = nil
    }

    /// Relaunch the dedicated Claude process with --resume, without sending any user input.
    func claudeRestartThread() throws {
        let reconnect = claudeProcess != nil || record.claudeSessionID != nil
        preserveClaudeSessionOnResumeFailure = record.claudeSessionID != nil
        claudeProcess?.onMessage = nil
        claudeProcess?.terminate()
        claudeProcess = nil
        record.claudeHost = nil
        isRunning = false
        automaticTurn = false
        stoppingToSend = false
        markRunningToolsFailed()
        expirePendingApprovals()
        clearQueuedMessages()
        clearBackgroundTasks()
        remoteURL = nil
        restartForToolsAfterTurn = false
        claudeStopRequested = false
        claudeAwaitingEcho = []
        claudeRender = ResponseRender()
        claudeToolItems = [:]
        claudeToolCalls = [:]
        claudePlanItem = nil
        claudeStreamedMessages = []
        claudeCommands = nil
        onChange?(self)
        if reconnect { _ = try claudeEnsureProcess(earlierItems: record.items.count) }
    }

    /// Starts the Claude Code session without a message, for Remote Control.
    func claudeStartForRemoteControl() throws -> ClaudeCodeProcess {
        guard remoteCommand == nil else {throw RuntimeFailure("Provider execution belongs to the background service")}
        return try claudeEnsureProcess(earlierItems: record.items.count)
    }

    func claudeInterrupt() {
        guard isRunning, let process = claudeProcess else { return }
        claudeStopRequested = true
        process.controlNow("interrupt")
    }

    /// Starts this chat's Claude Code process if it isn't running, resuming its session.
    private func claudeEnsureProcess(earlierItems: Int) throws -> ClaudeCodeProcess {
        if let process = claudeProcess, process.isRunning { return process }

        let resuming = record.claudeSessionID != nil
        // A new session knows nothing of this chat yet (older chats, or a changed folder).
        if !resuming, record.pendingHandoff == nil, record.claudeSeenThrough == nil, earlierItems > 0 {
            let transcript = Self.transcript(record.items[0..<earlierItems])
            if !transcript.isEmpty {
                record.pendingHandoff = Prompts.handoff(from: "", transcript: transcript, isWholeConversation: true)
            }
        }
        let process = makeClaudeProcess()
        // A fresh id per process: a relaunch only ever reattaches to the one this chat recorded.
        try process.start(ClaudeCodeProcess.Config(
            cwd: claudeWorkingFolder,
            model: record.model,
            effort: record.effort,
            permissionMode: claudePermissionMode,
            appendSystemPrompt: Prompts.fullInstructions(record.personality, backend: .claude, projectFolder: record.boundFolder,
                                                         studio: studio) + (isDot ? "\n\n" + Prompts.dotInstructions(name: title) : ""),
            resumeSessionID: record.claudeSessionID,
            extraDirectories: [Attachments.directory.path],
            forkSession: record.claudeForkPending == true,
            mcpConfig: claudeMCPConfig,
            allowedTools: claudeAllowedTools,
            environment: claudeProxyEnvironment.merging(SecretVault.shared.environment(for: self)) { $1 },
            fastMode: record.claudeFastMode == true && supportsClaudeFastMode
        ), id: "claude-\(id.uuidString)-\(UUID().uuidString.prefix(8))")
        // A fresh session gets the current tone and instructions in its system prompt.
        if !resuming {
            record.sentPersonality = record.personality
            record.sentUserInstructions = Prompts.userInstructions
            record.sentStudioInstructions = studio?.noteKey ?? ""
            record.instructionsVersion = Prompts.instructionsVersion
        }
        // The branch gets its own session id in its first `init` message.
        record.claudeForkPending = nil
        claudeProcess = process
        claudeAwaitingEcho = []
        if wantsRemoteControl { Task { await enableRemoteControl() } }
        return process
    }

    /// A process wired to this chat, not yet started or attached.
    func makeClaudeProcess() -> ClaudeCodeProcess {
        let process = ClaudeCodeProcess()
        process.onMessage = { [weak self] message in
            guard let self else { return }
            self.handleClaude(message)
            self.onStreamed?(self)
        }
        process.onExit = { [weak self] status, detail in self?.claudeProcessExited(status: status, detail: detail) }
        return process
    }

    private var claudeWorkingFolder: String {
        if isDot { return RuntimePaths.assistantFolder }
        return record.boundFolder ?? AppPreferences.defaults.string(forKey: "codexFolder") ?? NSHomeDirectory()
    }

    private var claudePermissionMode: String { record.claudeModeID }

    // MARK: - Live settings

    var supportsClaudeFastMode: Bool {
        let model = ClaudeModels.shared.info(record.model).resolvedModel.lowercased().split(separator: "[").first.map(String.init) ?? ""
        return model == "opus" || ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"].contains {
            model == $0 || (model.hasPrefix($0 + "-") && model.dropFirst($0.count + 1).count == 8 && model.dropFirst($0.count + 1).allSatisfy(\.isNumber))
        }
    }

    var fastMode: Bool { record.backend == .codex ? record.codex?.fastMode == true : record.claudeFastMode == true && supportsClaudeFastMode }
    var supportsFastMode: Bool { record.backend == .codex || supportsClaudeFastMode }
    var fastModeNote: String {
        record.backend == .claude
            ? "Requires usage credits and account support; billed outside your subscription allowance. Applies after the current reply."
            : "Faster replies with higher usage. Applies to the next reply; availability depends on your model and plan."
    }

    func setFastMode(_ enabled: Bool) {
        if let remoteCommand {remoteCommand("settings",["fastMode":.bool(enabled)]);return}
        if record.backend == .codex { setCodexFastMode(enabled); return }
        guard !enabled || supportsClaudeFastMode, record.claudeFastMode != enabled else { return }
        record.claudeFastMode = enabled
        // Startup --settings is supported by this CLI. Resume the same conversation,
        // waiting for the current reply just as when its tool configuration changes.
        restartClaudeForNewTools()
        noteSettingsChange()
        onChange?(self)
    }

    func claudeApplyModel() {
        guard let process = claudeProcess, process.isRunning else { return }
        process.controlNow("set_model", ["model": .string(record.model)])
    }

    func claudeApplyEffort() {
        guard let process = claudeProcess, process.isRunning else { return }
        let effort: JSON = record.effort.isEmpty ? .null : .string(record.effort)
        process.controlNow("apply_flag_settings", ["settings": ["effortLevel": effort]])
    }

    func claudeApplyPermissionMode() {
        guard let process = claudeProcess, process.isRunning else { return }
        process.controlNow("set_permission_mode", ["mode": .string(claudePermissionMode)])
    }

    /// Claude Code keeps sessions per folder, so a new folder means a new session,
    /// caught up on the conversation so far.
    func claudeWorkingFolderChanged() {
        guard record.claudeSessionID != nil || claudeProcess != nil else { return }
        // A new session starts with no tasks.
        record.claudeTasks = nil
        claudeProcess?.terminate()
        claudeProcess = nil
        record.claudeSessionID = nil
        record.claudeSeenThrough = nil
        clearQueuedMessages()
        if isRunning { isRunning = false }
    }

    // MARK: - Stream

    private func handleClaude(_ message: JSON) {
        // Sub-agents report through their parent's tool call; only show the main thread.
        if case .string = message["parent_tool_use_id"] ?? .null { return }

        switch message["type"]?.string {
        case "system":
            if message["subtype"]?.string == "init" { preserveClaudeSessionOnResumeFailure = false }
            if message["subtype"]?.string == "init", let id = message["session_id"]?.string, id != record.claudeSessionID {
                record.claudeSessionID = id
                onChange?(self)
            }
            // Includes the project's own commands once Claude Code has started in its folder.
            if message["subtype"]?.string == "commands_changed", let list = message["commands"]?.array {
                claudeCommands = list.compactMap(SlashCommand.init(claude:))
            }
            if message["subtype"]?.string == "compact_boundary" { claudeCompacted(message) }
            claudeBackgroundEvent(message)

        case "stream_event":
            if let event = message["event"] { handleClaudeEvent(event) }

        case "assistant":
            // Output that never streamed (e.g. from a slash command like /context): show it whole.
            let messageID = message["message"]?["id"]?.string
            if messageID.map({ !claudeStreamedMessages.contains($0) }) ?? true {
                if let messageID { claudeStreamedMessages.insert(messageID) }
                for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "text" {
                    guard let text = block["text"]?.string, !text.isEmpty else { continue }
                    claudeRender.textItems.append(appendItem(DisplayItem(kind: .assistant, text: text, phase: .streaming)))
                }
            }
            // Complete blocks: tool inputs are only final here.
            for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
                guard let useID = block["id"]?.string, let name = block["name"]?.string else { continue }
                claudeToolCalls[useID] = (name, block["input"] ?? [:])
                if name == Tools.todoTool {
                    showPlan(Tools.planSteps(block["input"]))
                } else if Self.claudeTaskTools.contains(name) {
                    claudeTaskToolUsed(name, input: block["input"] ?? [:], useID: useID)
                } else if let item = claudeToolItems[useID] {
                    updateItem(item) { $0.text = Tools.label(name: name, input: block["input"]) }
                }
            }

        case "user":
            if message["isReplay"]?.bool == true {
                claudeMessageReplayed(message)
                break
            }
            for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                if let useID = block["tool_use_id"]?.string, let call = claudeToolCalls[useID], Self.claudeTaskTools.contains(call.name) {
                    let text = block["content"]?.string
                        ?? (block["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                    claudeTaskResult(call.name, input: call.input, result: text)
                    continue
                }
                guard let useID = block["tool_use_id"]?.string, let item = claudeToolItems[useID] else { continue }
                let failed = block["is_error"]?.bool == true
                updateItem(item) { $0.toolState = failed ? .failed : .done }
                if !failed { previewWrittenFile(useID) }
            }

        case "control_request":
            if message["request"]?["subtype"]?.string == "can_use_tool", let id = message["request_id"]?.string {
                showClaudeApproval(id: id, request: message["request"] ?? [:])
            }

        case "rate_limit_event":
            let info = message["rate_limit_info"]
            UsageLimits.shared.updateClaude(info)
            if let status = info?["status"]?.string, status != "allowed" {
                let reset = info?["resetsAt"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let when = reset.map { " It resets \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
                notice(status == "rejected" ? "You've hit your Claude usage limit.\(when)" : "You're close to your Claude usage limit.\(when)")
            }

        case "result":
            finishClaudeTurn(message)

        default:
            break
        }
    }

    private func handleClaudeEvent(_ event: JSON) {
        let index = event["index"]?.int ?? -1
        switch event["type"]?.string {
        case "message_start":
            claudeRender = ResponseRender()
            if let id = event["message"]?["id"]?.string { claudeStreamedMessages.insert(id) }
            claudeUpdateContext(usage: event["message"]?["usage"])
            // Claude Code may start a new turn on its own, e.g. for a message queued during the last one.
            if !isRunning { isRunning = true }

        case "content_block_start":
            let block = event["content_block"] ?? [:]
            switch block["type"]?.string {
            case "text":
                let id = appendItem(DisplayItem(kind: .assistant, text: block["text"]?.string ?? "", phase: .streaming))
                claudeRender.itemForIndex[index] = id
                claudeRender.textItems.append(id)
            case "thinking":
                claudeRender.itemForIndex[index] = appendItem(DisplayItem(kind: .thought))
            case "tool_use", "server_tool_use":
                // Anything said before a tool call was narration, not the answer.
                markClaudeTextAsCommentary()
                let name = block["name"]?.string ?? ""
                // The plan card and question card stand in for these rows.
                guard name != Tools.todoTool, name != "AskUserQuestion", !Self.claudeTaskTools.contains(name) else { break }
                let id = appendItem(DisplayItem(kind: .tool, text: Tools.label(name: name, input: nil)))
                claudeRender.itemForIndex[index] = id
                if let useID = block["id"]?.string { claudeToolItems[useID] = id }
            default:
                if let type = block["type"]?.string, type.hasSuffix("_tool_result"),
                   let useID = block["tool_use_id"]?.string, let item = claudeToolItems[useID] {
                    updateItem(item) { $0.toolState = .done }
                }
            }

        case "message_delta":
            claudeUpdateContext(usage: event["usage"])

        case "content_block_delta":
            guard let id = claudeRender.itemForIndex[index], let delta = event["delta"] else { break }
            switch delta["type"]?.string {
            case "text_delta": updateItem(id) { $0.text += delta["text"]?.string ?? "" }
            case "thinking_delta": updateItem(id) { $0.text += delta["thinking"]?.string ?? "" }
            default: break
            }

        default:
            break
        }
    }

    private func finishClaudeTurn(_ result: JSON) {
        for id in claudeRender.textItems {
            updateItem(id) { if $0.phase == .streaming { $0.phase = .final } }
        }
        record.items.removeAll {
            ($0.kind == .assistant || $0.kind == .thought) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let isError = result["is_error"]?.bool == true || result["subtype"]?.string != "success"
        if claudeStopRequested {
            notice(stoppingToSend ? "Stopped to take your message." : "Stopped.")
            stoppingToSend = false
        } else if isError {
            let errors = (result["errors"]?.array ?? []).compactMap(\.string).joined(separator: " ")
            let detail = result["result"]?.string ?? (errors.isEmpty ? result["subtype"]?.string ?? "" : errors)
            notice("Claude Code reported a problem: \(detail)")
        }
        if isError || claudeStopRequested { markRunningToolsFailed() }
        // A subagent the reply was waiting on is done with it. Background ones carry on.
        clearBackgroundTasks { !$0.detached }
        claudeUpdateContextWindow(result: result)
        // Anything still marked queued was taken in without an echo; nothing more is waiting.
        if (result["queued_turn_count"]?.int ?? 0) == 0 { clearQueuedMessages() }
        expirePendingApprovals()
        claudeStopRequested = false
        claudeRender = ResponseRender()
        claudeStreamedMessages = []
        isRunning = false
        record.updatedAt = Date()
        turnEnded()
        onChange?(self)
    }

    private func claudeProcessExited(status: Int32, detail: String) {
        claudeProcess = nil
        if preserveClaudeSessionOnResumeFailure {
            threadRestartStatus = "Couldn't restart: Claude ended before reconnecting to the original session (exit \(status)). History and draft are kept."
        }
        let lower = detail.lowercased()
        if lower.contains("no conversation found") || lower.contains("session") && lower.contains("not found") {
            // The saved session is gone; the next message starts a new one, caught up on the chat.
            if preserveClaudeSessionOnResumeFailure {
                threadRestartStatus = "Couldn't restart: Claude couldn't reopen the original session. History and draft are kept."
            } else {
                record.claudeSessionID = nil
                record.claudeSeenThrough = nil
                notice("Couldn't reopen the earlier Claude Code session. Send your message again to continue in a new one.")
            }
        } else if !preserveClaudeSessionOnResumeFailure, isRunning || status != 0 {
            notice("Claude Code stopped unexpectedly (exit \(status))\(detail.isEmpty ? "." : ": \(detail)")")
        }
        markRunningToolsFailed()
        expirePendingApprovals()
        clearQueuedMessages()
        clearBackgroundTasks()
        remoteURL = nil
        isRunning = false
        onChange?(self)
    }

    /// Claude Code reports each subagent and background command as a task: started, its
    /// progress, and when it ends. `background_tasks_changed` lists the background ones.
    private func claudeBackgroundEvent(_ message: JSON) {
        switch message["subtype"]?.string {
        case "task_started":
            // A subagent's own commands show as that subagent's progress instead.
            guard let id = message["task_id"]?.string, message["owned_by_subagent"]?.bool != true else { return }
            let isAgent = message["task_type"]?.string == "local_agent"
            let detached = message["is_backgrounded"]?.bool == true
            guard isAgent || detached else { return }
            addBackgroundTask(BackgroundTask(id: id, kind: isAgent ? .agent : .shell,
                                             title: message["description"]?.string ?? (isAgent ? "Subagent" : "Shell command"),
                                             detached: detached))
        case "task_progress":
            guard let id = message["task_id"]?.string, let detail = message["description"]?.string else { return }
            updateBackgroundTask(id) { $0.detail = detail }
        case "task_updated":
            guard let id = message["task_id"]?.string, let status = message["patch"]?["status"]?.string,
                  status != "running", status != "pending" else { return }
            finishBackgroundTask(id, failed: status == "failed")
        case "task_notification":
            guard let id = message["task_id"]?.string else { return }
            finishBackgroundTask(id, failed: message["status"]?.string == "failed")
        case "background_tasks_changed":
            let live = Set((message["tasks"]?.array ?? []).compactMap { $0["task_id"]?.string })
            clearBackgroundTasks { $0.detached && !live.contains($0.id) }
        default:
            break
        }
    }

    /// Files Claude writes that can be looked at (a web page, an SVG, an image) appear in the
    /// reply as a live preview, the way Codex's generated images do.
    private func previewWrittenFile(_ useID: String) {
        guard let call = claudeToolCalls.removeValue(forKey: useID),
              ["Write", "Edit", "MultiEdit"].contains(call.name),
              let path = call.input["file_path"]?.string else { return }
        showWrittenFile(path)
    }

    /// A page, picture, or animation an agent wrote, shown in the reply (or the preview from
    /// earlier this turn, refreshed). Used for Claude's writes and Codex's file changes.
    func showWrittenFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: path),
              ["html", "htm", "svg", "png", "jpg", "jpeg", "gif", "webp"].contains(ext) || MediaKind.of(url) != nil else { return }
        // An edit to a file already previewed this turn refreshes that preview instead of adding another.
        if let existing = record.items.lastIndex(where: { $0.kind == .image && $0.attachments?.first?.path == path }),
           record.items[existing...].allSatisfy({ $0.kind != .user }) {
            record.items[existing].text = "Updated \(url.lastPathComponent)"
            record.items[existing].attachments = [Attachments.reference(url)]
            return
        }
        appendItem(DisplayItem(kind: .image, text: url.lastPathComponent, attachments: [Attachments.reference(url)]))
    }

    private func markClaudeTextAsCommentary() {
        for id in claudeRender.textItems {
            updateItem(id) { if $0.phase == .streaming { $0.phase = .commentary } }
        }
    }

    func showPlan(_ steps: [PlanStep]?) {
        guard let steps else { return }
        if let item = claudePlanItem {
            updateItem(item) { $0.planSteps = steps }
        } else {
            claudePlanItem = appendItem(DisplayItem(kind: .plan, planSteps: steps))
        }
    }

    // MARK: - Permission prompts

    /// The card keeps the whole request, so answering it never depends on in-memory state.
    private func showClaudeApproval(id: String, request: JSON) {
        let tool = request["tool_name"]?.string ?? "a tool"
        let input = request["input"] ?? [:]
        let payload: JSON = ["id": .string(id), "tool": .string(tool), "input": input,
                             "suggestions": request["permission_suggestions"] ?? .null]
        if tool == "AskUserQuestion" {
            let questions = (input["questions"]?.array ?? []).enumerated().map { index, q in
                AgentQuestion(id: q["question"]?.string ?? "q\(index)", header: q["header"]?.string ?? "",
                              question: q["question"]?.string ?? "",
                              options: (q["options"]?.array ?? []).map { .init(label: $0["label"]?.string ?? "", detail: $0["description"]?.string ?? "") },
                              multiSelect: q["multiSelect"]?.bool ?? false, isSecret: false)
            }
            appendItem(DisplayItem(kind: .questions, requestID: payload, approvalState: .pending, questions: questions))
            onChange?(self)
            return
        }
        if tool == "ExitPlanMode" {
            appendItem(DisplayItem(kind: .approval, text: "Claude has a plan. Start building?",
                                   detail: input["plan"]?.string, requestID: payload, approvalState: .pending,
                                   approvalStyle: .plan))
        } else {
            let (title, detail) = Tools.approval(name: tool, input: input, description: request["description"]?.string)
            appendItem(DisplayItem(kind: .approval, text: title, detail: detail, requestID: payload, approvalState: .pending))
        }
        onChange?(self)
    }

    /// Sends your answers (or a skip) back to AskUserQuestion. Answers go keyed by question text.
    func claudeAnswer(_ itemID: UUID, answers: [String: [String]]?) {
        guard let item = record.items.first(where: { $0.id == itemID }), item.approvalState == .pending,
              let payload = item.requestID, let id = payload["id"]?.string else { return }
        guard let process = claudeProcess, process.isRunning else {
            updateItem(itemID) { $0.approvalState = .expired }
            onChange?(self)
            return
        }
        if let answers {
            var input = payload["input"]?.object ?? [:]
            input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            process.respond(to: id, ["behavior": "allow", "updatedInput": .object(input)])
        } else {
            process.respond(to: id, ["behavior": "deny", "message": "The user skipped these questions. Continue with sensible defaults, or ask in a message if you really need an answer."])
        }
        updateItem(itemID) {
            $0.answers = answers
            $0.approvalState = answers == nil ? .denied : .approved
        }
        onChange?(self)
    }

    func claudeResolveApproval(_ itemID: UUID, _ decision: DisplayItem.ApprovalState) {
        guard let item = record.items.first(where: { $0.id == itemID }), item.approvalState == .pending,
              let payload = item.requestID, let id = payload["id"]?.string else { return }
        guard let process = claudeProcess, process.isRunning else {
            updateItem(itemID) { $0.approvalState = .expired }
            notice("That request is no longer active, because Claude Code restarted. Ask again to continue.")
            onChange?(self)
            return
        }
        let tool = payload["tool"]?.string ?? ""
        let input = payload["input"] ?? [:]
        switch decision {
        case .approved, .approvedForSession:
            var response: [String: JSON] = ["behavior": "allow", "updatedInput": input]
            if tool == "ExitPlanMode" {
                // Leaving plan mode: "Start Building" asks before edits, the other accepts them.
                let next = decision == .approvedForSession ? "acceptEdits" : "default"
                response["updatedPermissions"] = [["type": "setMode", "mode": .string(next), "destination": "session"]]
                record.claudeMode = next
            } else if decision == .approvedForSession {
                // Claude Code's own suggestion (e.g. "allow edits this session"), or a rule for this tool.
                if let suggestions = payload["suggestions"], !(suggestions.array ?? []).isEmpty {
                    response["updatedPermissions"] = suggestions
                } else {
                    response["updatedPermissions"] = [["type": "addRules", "rules": [["toolName": .string(tool)]],
                                                       "behavior": "allow", "destination": "session"]]
                }
            }
            process.respond(to: id, .object(response))
        default:
            let message = tool == "ExitPlanMode" ? "The user wants to keep planning. Ask what to change." : "The user declined this."
            process.respond(to: id, ["behavior": "deny", "message": .string(message)])
        }
        updateItem(itemID) { $0.approvalState = decision }
        onChange?(self)
    }
}

extension ChatSession {
    /// EasyCLIProxyAPI for this chat's Claude Code, when it's on (never for the assistant).
    var claudeProxyEnvironment: [String: String] {
        guard !isDot, let proxy = EasyCLIProxy.shared.active(for: .claude) else { return [:] }
        return ["ANTHROPIC_BASE_URL": proxy.base, "ANTHROPIC_AUTH_TOKEN": proxy.key, "ANTHROPIC_API_KEY": ""]
    }
}
