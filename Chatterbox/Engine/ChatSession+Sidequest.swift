import Foundation

/// Sidequests: hand a task from a chat to the other agent (Claude ↔ Codex). The sidequest is a
/// Sidechat on that agent, caught up on the chat it came from; when its turn finishes, its
/// final reply goes back to that chat, whose agent carries on from it. The background service
/// runs both ends, so the return happens even with the app closed.
extension ChatSession {
    var isSidequest: Bool { record.sidequestOf != nil }

    /// A sidequest from `parent` on `backend`, under `anchor` like any Sidechat of it.
    static func sidequestRecord(of parent: ChatSession, anchor: ChatSession, number: Int, backend: Backend, task: String) -> ConversationRecord {
        var record = sidechatRecord(of: parent, anchor: anchor, number: number)
        record.title = "Sidequest \u{00B7} " + (task.count > 40 ? String(task.prefix(39)) + "\u{2026}" : task)
        record.activeBackend = backend
        record.sidequestOf = parent.id
        record.sidequestTask = task
        if backend == .codex, record.codex == nil {
            let defaults = AppPreferences.defaults
            record.codex = CodexSettings(folder: parent.workingFolder, canEdit: false, mode: PermissionModes.defaultCodex)
            record.codex?.model = defaults.string(forKey: "codexDefaultModel").flatMap { $0.isEmpty ? nil : $0 }
            record.codex?.effort = defaults.string(forKey: "codexDefaultEffort").flatMap { $0.isEmpty ? nil : $0 }
        }
        // A sidequest may write in its folder; its instructions say when to leave files alone.
        // Settings that already allow more stay as they are.
        if backend == .codex, ["readOnly", nil].contains(record.codex?.mode ?? (record.codex?.canEdit == true ? "ask" : "readOnly")) {
            record.codex?.mode = "ask"
        }
        record.codex?.canEdit = true
        if backend == .claude, ["default", "plan"].contains(record.claudeModeID) { record.claudeMode = "acceptEdits" }
        record.prepareParentContext(from: parent)
        return record
    }

    var isPCErrand: Bool { record.pcErrand == true }

    /// A PC errand ("do that on the PC"): a sidequest that runs on Shelby-PC, on `backend`
    /// (the session's own agent unless asked). `files` are already on the PC, at these paths.
    static func pcErrandRecord(of parent: ChatSession, anchor: ChatSession, number: Int, backend: Backend, task: String,
                               files: [String]) -> ConversationRecord {
        let machine = RemoteMachine.pc
        let message = files.isEmpty ? task
            : task + "\n\nFiles sent from the Mac, now on \(machine.name):\n" + files.map { "- " + $0 }.joined(separator: "\n")
        var record = sidequestRecord(of: parent, anchor: anchor, number: number, backend: backend, task: message)
        record.title = "On \(machine.name) \u{00B7} " + (task.count > 40 ? String(task.prefix(39)) + "\u{2026}" : task)
        record.runOn = machine.id
        record.pcErrand = true
        record.pendingHandoff = Prompts.pcErrandStart(from: parent.record.backend.label, chat: parent.title, machine: machine.name,
                                                      transcript: record.parentContext?.text ?? "")
        return record
    }

    /// Copies Mac files to the PC for an errand; returns their paths there.
    static func uploadForPCErrand(_ paths: [String]) async throws -> [String] {
        let machine = RemoteMachine.pc
        var uploaded: [String] = []
        for path in paths {
            let local = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: local.path) else { throw RuntimeFailure("No such file: \(path)") }
            let remote = machine.attachmentsRoot + #"\"# + UUID().uuidString.prefix(8).lowercased() + "-" + local.lastPathComponent
            try await RemoteLaunch.upload(local, to: remote, on: machine)
            uploaded.append(remote)
        }
        return uploaded
    }

    /// The agent an automation runs on: its own, else its preset's (older ones), else the
    /// project chat's.
    static func automationBackend(_ automation: ProjectAutomation, project: ChatSession) -> Backend {
        let preset = automation.preset.flatMap { id in ModelPresets.shared.presets.first { $0.id == id } }
        return automation.backend.flatMap(Backend.init(rawValue:)) ?? (automation.model == nil ? preset?.backend : nil) ?? project.record.backend
    }

    /// An automation's run: a sidequest of its project's chat on the automation's agent, told
    /// what it is rather than handed the chat's transcript.
    static func automationRunRecord(_ automation: ProjectAutomation, of project: ChatSession, number: Int, manual: Bool) -> ConversationRecord {
        var record = sidequestRecord(of: project, anchor: project, number: number, backend: automationBackend(automation, project: project),
                                     task: ProjectAutomations.message(for: automation, manual: manual))
        record.automationID = automation.id
        record.title = "Automation \u{00B7} " + automation.title
        record.parentContext = nil
        record.pendingHandoff = Prompts.automationStart(title: automation.title, project: project.projectName)
        return record
    }

    /// Once its record is in: the automation's model and effort (or its preset), then its task.
    func startAutomationRun(_ automation: ProjectAutomation, from project: ChatSession) {
        let codex = record.backend == .codex
        if automation.backend == nil, automation.model == nil,
           let preset = automation.preset.flatMap({ id in ModelPresets.shared.presets.first { $0.id == id } }) {
            ModelPresets.shared.apply(preset, to: self)
        }
        if let model = automation.model { codex ? setCodexModel(model.isEmpty ? nil : model) : setModel(model) }
        if let effort = automation.effort { codex ? setCodexEffort(effort.isEmpty ? nil : effort) : setEffort(effort) }
        beginSidequest(from: project, label: "Automation \u{201C}\(automation.title)\u{201D}")
        if let index = record.items.lastIndex(where: { $0.kind == .user }) {
            record.items[index].automatic = true
            record.items[index].detail = "Automation \u{00B7} \(automation.title)"
        }
        onChange?(self)
    }

    /// Sends the task once the sidequest exists, and marks it in the chat it came from.
    /// `label` names an automation run in place of the task.
    func beginSidequest(from parent: ChatSession, label: String? = nil) {
        guard let task = record.sidequestTask else { return }
        send(task)
        let text = isPCErrand
            ? "Sent to \(RemoteMachine.pc.name): \u{201C}\(title.components(separatedBy: " \u{00B7} ").dropFirst().joined(separator: " \u{00B7} "))\u{201D}. Its answer and files come back here when it's done."
            : label.map { "\($0) is running as a sidequest with \(record.backend.label). Its report comes back here when it's done." }
                ?? "Sent \(record.backend.label) on a sidequest: \u{201C}\(task)\u{201D}. Its answer comes back here when it's done."
        parent.record.items.append(DisplayItem(kind: .notice, text: text, sidequest: id))
        parent.onChange?(parent)
    }

    /// The sidequest's newest final reply, if it hasn't gone back yet.
    var unreturnedSidequestReply: DisplayItem? {
        guard isSidequest, let reply = items.last(where: { $0.kind == .assistant && $0.phase == .final }),
              reply.id != record.sidequestReturned else { return nil }
        return reply
    }

    /// After a sidequest's turn: its finished answer goes back by itself, and the sidequest
    /// archives itself. Unarchived and continued, later answers wait for Send Back, so
    /// refining doesn't restart the other chat each time.
    func sidequestTurnEnded(parent: ChatSession?) {
        guard let parent, record.sidequestReturned == nil, !isWaitingOnYou, unreturnedSidequestReply != nil else { return }
        // A PC errand's files are copied to the Mac first, so its answer can name them.
        if isPCErrand {
            let since = record.turnStartedAt
            Task { @MainActor in
                await mirrorPCWorkspaceNow(changedSince: since)
                guard record.sidequestReturned == nil else { return }
                returnSidequest(to: parent)
            }
            return
        }
        returnSidequest(to: parent)
    }

    /// Sends the newest reply back to `parent`, which carries on from it.
    func returnSidequest(to parent: ChatSession) {
        guard let reply = unreturnedSidequestReply else { return }
        record.sidequestReturned = reply.id
        let automation = record.automationID != nil
        let task = record.sidequestTask ?? title
        parent.send(automation ? Prompts.automationResult(title: title, reply: reply.text)
                    : isPCErrand ? Prompts.pcErrandResult(machine: RemoteMachine.pc.name, task: task.components(separatedBy: "\n\nFiles sent").first ?? task,
                                                          reply: macPaths(reply.text))
                    : Prompts.sidequestResult(from: record.backend, task: task, reply: reply.text))
        if let index = parent.record.items.lastIndex(where: { $0.kind == .user }) {
            parent.record.items[index].automatic = true
            parent.record.items[index].detail = automation ? "\(title) reported back"
                : isPCErrand ? "Back from \(RemoteMachine.pc.name)" : "\(record.backend.label) is back from its sidequest"
            parent.record.items[index].sidequest = id
        }
        parent.onChange?(parent)
        notice("Sent back to \u{201C}\(parent.title)\u{201D}. This sidequest is archived; it's still here if you want it.")
        // Done: it leaves the sidebar and its window. The report is in the chat it came from.
        setArchived(true)
        onChange?(self)
    }
}

extension ConversationRecord {
    /// An automation run from before runs were sidequests (a Sidechat of its project's chat)
    /// becomes one: it shows in that chat's card, and its next finished answer goes back and
    /// archives it. Returns whether it changed.
    mutating func adoptAsSidequestIfAutomationRun() -> Bool {
        guard automationID != nil, sidequestOf == nil, let parent = sidechatOf else { return false }
        sidequestOf = parent
        sidequestTask = title
        return true
    }
}
