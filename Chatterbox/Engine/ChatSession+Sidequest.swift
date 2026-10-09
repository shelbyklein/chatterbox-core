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
        record.pendingHandoff = Prompts.sidequestStart(from: parent.record.backend.label, chat: parent.title,
                                                       transcript: transcript(parent.record.items[...]))
        return record
    }

    /// Sends the task once the sidequest exists, and marks it in the chat it came from.
    func beginSidequest(from parent: ChatSession) {
        guard let task = record.sidequestTask else { return }
        send(task)
        parent.record.items.append(DisplayItem(kind: .notice, text: "Sent \(record.backend.label) on a sidequest: \u{201C}\(task)\u{201D}. Its answer comes back here when it's done.",
                                               sidequest: id))
        parent.onChange?(parent)
    }

    /// The sidequest's newest final reply, if it hasn't gone back yet.
    var unreturnedSidequestReply: DisplayItem? {
        guard isSidequest, let reply = items.last(where: { $0.kind == .assistant && $0.phase == .final }),
              reply.id != record.sidequestReturned else { return nil }
        return reply
    }

    /// After a sidequest's turn: the first finished answer goes back by itself. Later ones
    /// (after you keep chatting in it) wait for Send Back, so refining doesn't restart the
    /// other chat each time.
    func sidequestTurnEnded(parent: ChatSession?) {
        guard let parent, record.sidequestReturned == nil, !isWaitingOnYou, unreturnedSidequestReply != nil else { return }
        returnSidequest(to: parent)
    }

    /// Sends the newest reply back to `parent`, which carries on from it.
    func returnSidequest(to parent: ChatSession) {
        guard let reply = unreturnedSidequestReply else { return }
        record.sidequestReturned = reply.id
        parent.send(Prompts.sidequestResult(from: record.backend.label, task: record.sidequestTask ?? title, reply: reply.text))
        if let index = parent.record.items.lastIndex(where: { $0.kind == .user }) {
            parent.record.items[index].automatic = true
            parent.record.items[index].detail = "\(record.backend.label) is back from its sidequest"
            parent.record.items[index].sidequest = id
        }
        parent.onChange?(parent)
        notice("Sent back to \u{201C}\(parent.title)\u{201D}.")
        onChange?(self)
    }
}
