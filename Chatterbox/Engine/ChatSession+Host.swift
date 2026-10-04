import Foundation

/// Replies that outlive the app. Agent processes run in ChatterboxHost; each save records how
/// far their output had been handled, together with the turn's bookkeeping, so a relaunch
/// reattaches and replays the rest into exactly the state the saved transcript was in.
extension ChatSession {
    /// Brings the saved links up to date just before the record is written.
    func prepareForSave() {
        guard !awaitingHostResume else { return }
        redactSecrets()
        if let process = claudeProcess, process.isRunning, let id = process.hostID {
            record.claudeHost = HostLink(processID: id, offset: process.offset,
                                         running: isRunning && record.backend == .claude, claude: claudeTurnState)
        } else {
            record.claudeHost = nil
        }
        let server = CodexAppServer.shared
        if record.codex?.threadId == nil {
            record.codexHost = nil
        } else if server.isRunning, let id = server.hostID {
            record.codexHost = HostLink(processID: id, offset: server.offset,
                                        running: isRunning && record.backend == .codex, codex: codexTurnState)
        }
        // Otherwise Codex isn't running: the old link is kept, and found gone on the next launch.
    }

    private var claudeTurnState: ClaudeTurnState {
        ClaudeTurnState(render: claudeRender, toolItems: claudeToolItems,
                        toolCalls: claudeToolCalls.mapValues { .init(name: $0.name, input: $0.input) },
                        planItem: claudePlanItem, streamedMessages: claudeStreamedMessages.sorted(),
                        stopRequested: claudeStopRequested)
    }

    private var codexTurnState: CodexTurnState {
        CodexTurnState(turnID: codexTurnID, items: codexItems, planItems: codexPlanItems,
                       turnMessageItems: codexTurnMessageItems, stopRequested: codexStopRequested)
    }

    /// True when this chat's saved record points at processes in the host.
    var hasHostLinks: Bool { record.claudeHost != nil || record.codexHost != nil }

    /// Reattaches to this chat's processes after launch. `processes` is the host's list (empty
    /// when no host is running). A process that ended while the app was closed still replays
    /// the rest of its log, so its final reply lands. Anything whose process is gone is settled.
    /// Codex's thread handler is registered here; the shared app-server is reattached after
    /// every chat has done this (`CodexAppServer.resume`).
    func resumeFromHost(_ processes: [HostProcess]) {
        awaitingHostResume = false
        defer { resumeBackgroundWatches() }
        let ids = Set(processes.map(\.id))
        var claudeAlive = false, codexAlive = false

        if let link = record.claudeHost {
            if ids.contains(link.processID) {
                if let state = link.claude {
                    claudeRender = state.render
                    claudeToolItems = state.toolItems
                    claudeToolCalls = state.toolCalls.mapValues { ($0.name, $0.input) }
                    claudePlanItem = state.planItem
                    claudeStreamedMessages = Set(state.streamedMessages)
                    claudeStopRequested = state.stopRequested
                }
                let process = makeClaudeProcess()
                claudeProcess = process
                if link.running { isRunning = true }
                do {
                    try process.attach(id: link.processID, from: link.offset)
                    claudeAlive = true
                } catch {
                    claudeProcess = nil
                    isRunning = false
                }
            }
            if !claudeAlive { record.claudeHost = nil }
        }

        if let link = record.codexHost, let thread = record.codex?.threadId {
            if ids.contains(link.processID), link.processID == CodexAppServer.savedProcessID {
                if let state = link.codex {
                    codexTurnID = state.turnID
                    codexItems = state.items
                    codexPlanItems = state.planItems
                    codexTurnMessageItems = state.turnMessageItems
                    codexStopRequested = state.stopRequested
                }
                codexSkipProcess = link.processID
                codexSkipThrough = link.offset
                codexRegisterHandler(thread)
                if link.running { isRunning = true }
                codexAlive = true
            } else {
                record.codexHost = nil
            }
        }

        if !(record.backend == .claude ? claudeAlive : codexAlive) { settleInterruptedWork() }
    }

    /// What a run that can't be continued left behind: requests nobody can answer anymore,
    /// tools that never finished, and text that was still streaming.
    func settleInterruptedWork() {
        // Nothing of the agent is left to report on them.
        record.backgroundTasks = nil
        for index in record.items.indices {
            if record.items[index].approvalState == .pending { record.items[index].approvalState = .expired }
            if record.items[index].kind == .tool, record.items[index].toolState == .running {
                record.items[index].toolState = .failed
            }
            if record.items[index].phase == .streaming { record.items[index].phase = .final }
        }
    }
}
