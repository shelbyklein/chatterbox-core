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
        record.pendingHandoff = Prompts.sidequestStart(from: parent.record.backend.label, to: backend, chat: parent.title,
                                                       transcript: transcript(parent.record.items[...]))
        return record
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
        parent.record.items.append(DisplayItem(kind: .notice, text: label.map { "\($0) is running as a sidequest with \(record.backend.label). Its report comes back here when it's done." }
                                                    ?? "Sent \(record.backend.label) on a sidequest: \u{201C}\(task)\u{201D}. Its answer comes back here when it's done.",
                                               sidequest: id))
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
        returnSidequest(to: parent)
    }

    /// Sends the newest reply back to `parent`, which carries on from it.
    func returnSidequest(to parent: ChatSession) {
        guard let reply = unreturnedSidequestReply else { return }
        record.sidequestReturned = reply.id
        let automation = record.automationID != nil
        parent.send(automation ? Prompts.automationResult(title: title, reply: reply.text)
                               : Prompts.sidequestResult(from: record.backend, task: record.sidequestTask ?? title, reply: reply.text))
        if let index = parent.record.items.lastIndex(where: { $0.kind == .user }) {
            parent.record.items[index].automatic = true
            parent.record.items[index].detail = automation ? "\(title) reported back" : "\(record.backend.label) is back from its sidequest"
            parent.record.items[index].sidequest = id
        }
        parent.onChange?(parent)
        notice("Sent back to \u{201C}\(parent.title)\u{201D}. This sidequest is archived; it's still here if you want it.")
        // Done: it leaves the sidebar and its window. The report is in the chat it came from.
        setArchived(true)
        onChange?(self)
    }
}
