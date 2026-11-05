import Foundation

/// Work threads (plans/work-threads.md): a project keeps one front thread Shelby talks to, and
/// real pieces of work go to fresh threads in the same folder. Each starts with a brief (what to
/// do, what's decided, which files to read) rather than the front thread's transcript, carries
/// its own task on the Desk, and reports its result back to the front thread when it's done (a
/// turn ends with no background work still running) or calls `work report`. One level only: a
/// work thread doesn't start work threads. The background service runs both ends, so the report
/// happens with the app closed.
extension ChatSession {
    var isWorkThread: Bool { record.workOf != nil }

    /// A work thread of `front`, under `anchor` like any Sidechat of it, on the front thread's
    /// agent and model. Its brief is its first message; the framing goes with it.
    static func workThreadRecord(of front: ChatSession, anchor: ChatSession, title: String) -> ConversationRecord {
        var record = sidechatRecord(of: front, anchor: anchor, number: 1)
        record.title = title
        record.workOf = front.id
        // What it's for, not the front thread's transcript.
        record.parentContext = nil
        let project = front.record.projectFolder != nil ? front.projectName : nil
        record.pendingHandoff = Prompts.workStart(front: front.title, project: project, agent: front.record.backend.label)
        return record
    }

    /// How long a work thread whose turn ended with background work running may then sit idle,
    /// nothing running, before it reports what it has (in case its agent never picks back up).
    static var workIdleReport: TimeInterval = 30 * 60

    /// How long a work thread waits, after a turn that ended owing its agent a wake-up
    /// (`owedWakeups`), for that turn to start before reporting anyway. Claude Code starts it
    /// within a second; this is for when it doesn't.
    static var workWakeupGrace: TimeInterval = 20

    /// The newest final reply not yet reported to the front thread.
    var unreportedWorkReply: DisplayItem? {
        guard isWorkThread, let reply = items.last(where: { $0.kind == .assistant && $0.phase == .final }),
              reply.id != record.workReported else { return nil }
        return reply
    }

    /// Between turns but not done: a turn ended with background work running, and the result
    /// hasn't gone back yet. Its task stays Working; its last reply is progress.
    var isWorkPending: Bool { isWorkThread && record.workPendingSince != nil && record.archivedAt == nil }

    /// Working, as the Work strip and the board say it: replying, running something in the
    /// background, or between turns waiting on that (`isWorkPending`).
    var isWorkingOn: Bool { isRunning || hasBackgroundWork || isWorkPending }

    /// After a work thread's turn: its finished reply goes to the front thread, unless it asks
    /// for an approval or answers first, the turn already reported (`work report`), background
    /// work it started still runs or has just ended and is about to wake its agent (it reports
    /// after the turn that ends with nothing running; see `reportIdleWork` for when that turn
    /// never comes), or, failing those, the reply itself says it's waiting on something
    /// (`readsAsInterim`).
    func workTurnEnded(front: ChatSession?) {
        let previous = record.workTurnEndedAt
        record.workTurnEndedAt = Date()
        guard let front, !isWaitingOnYou, let reply = unreportedWorkReply else { return }
        // Reported during this turn, after the message that started it (not one added while
        // it worked) and after the turn before it: that was the result.
        let asked = max(items.last(where: { $0.kind == .user && !$0.steered })?.timestamp ?? .distantPast, previous ?? .distantPast)
        if let at = record.workReportedAt, at >= asked {
            record.workReported = reply.id
            record.workPendingSince = nil
            onChange?(self)
            return
        }
        if hasBackgroundWork || !owedWakeups.isEmpty {
            // A background command or subagent still runs, and the agent picks up when it
            // finishes; or one finished while this reply was being written, and Claude Code is
            // about to start a turn to tell it: this reply says how it's going, not what came of it.
            record.workPendingSince = Date()
            if !hasBackgroundWork { reportIfNotWoken(front: front, reply: reply.id) }
            onChange?(self)
            return
        }
        if Self.readsAsInterim(reply.text) {
            // Nothing Chatterbox can see still runs, but the agent says it's waiting on something
            // (a job it detached itself, say): progress, until it picks back up or the safety net.
            RuntimeHooks.note("Work thread \u{201C}\(title)\u{201D} ended a turn saying it's waiting: holding its report")
            record.workPendingSince = Date()
            onChange?(self)
            return
        }
        reportWork(reply.text, to: front, reply: reply.id)
    }

    /// The wake-up a turn ended owing doesn't come within `workWakeupGrace`: nothing will
    /// pick back up, so the reply that ended it reports (unless it reads as waiting, which the
    /// idle safety net covers).
    private func reportIfNotWoken(front: ChatSession, reply: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.workWakeupGrace) { [weak self, weak front] in
            guard let self, let front, self.isWorkPending, !self.isRunning, !self.hasBackgroundWork, !self.isWaitingOnYou,
                  self.unreportedWorkReply?.id == reply else { return }
            self.owedWakeups.removeAll()
            guard let text = self.unreportedWorkReply?.text, !Self.readsAsInterim(text) else { return }
            RuntimeHooks.note("Work thread \u{201C}\(self.title)\u{201D}: no turn came for its finished background work, reporting its reply")
            self.reportWork(text, to: front, reply: reply)
        }
    }

    /// A short reply that says the agent is waiting to carry on ("I'll pick up when they
    /// finish", "Still waiting on the retest", "I'll be notified…") rather than giving a result.
    /// Only a backstop for background work Chatterbox can't see: waiting on you ("…when you
    /// say ship") and long replies (a result that mentions what's next) don't count.
    static func readsAsInterim(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        guard !text.isEmpty, text.count <= 600 else { return false }
        let notYou = #"(?!\s*(?:you\b|you'|your\b|shelby\b|the user\b))"#
        let patterns = [
            // "I'll pick up when they finish", "I'll carry on once the test reports"
            #"\bi(?:'ll| will) (?:pick (?:it |this |that |them |things )?(?:back )?up|carry on|continue|resume|report back|check back|follow up|get back to (?:it|this)|come back to (?:it|this))\b[^.!?\n]{0,60}?\b(?:when|once|after|as soon as)\b"# + notYou,
            // "I'll be notified when the suite finishes"
            #"\bi(?:'ll| will) (?:be|get) (?:notified|pinged|woken)\b"#,
            #"\b(?:when|once) (?:the |its |a )?notification (?:arrives|comes|lands)\b"#,
            // "Waiting for the rest.", "Still waiting on the retest", "I'm waiting for the build"
            #"(?:^|[.!?;:]\s+|\bi'm |\bi am |\bnow )(?:still )?waiting (?:for|on)\b"# + notYou,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// The safety net, checked now and then by whoever runs the conversation: a work thread
    /// whose turn ended with background work running reports its newest reply once it has sat
    /// idle, nothing running, for `workIdleReport`. Anything running counts as fresh activity.
    func reportIdleWork(front: ChatSession?, now: Date = Date()) {
        guard isWorkPending, let since = record.workPendingSince else { return }
        if isRunning || hasBackgroundWork || isWaitingOnYou || awaitingHostResume {
            record.workPendingSince = now
            return
        }
        guard now.timeIntervalSince(since) >= Self.workIdleReport else { return }
        guard let front, let reply = unreportedWorkReply else {
            record.workPendingSince = nil
            onChange?(self)
            return
        }
        RuntimeHooks.note("Work thread \u{201C}\(title)\u{201D} idle since its background work ended: reporting its last reply")
        reportWork(reply.text, to: front, reply: reply.id)
    }

    /// Sends `text` (what the work thread found or did) to its front thread as a new message,
    /// which its agent carries on from; `reply` is the reply it reports, if it's one. An
    /// archived front thread isn't woken: the report stays here.
    func reportWork(_ text: String, to front: ChatSession, reply: UUID? = nil) {
        if let reply { record.workReported = reply } else { record.workReportedAt = Date() }
        record.workPendingSince = nil
        guard front.record.archivedAt == nil else {
            notice("\u{201C}\(front.title)\u{201D} is archived, so this result wasn't sent there.")
            onChange?(self)
            return
        }
        front.send(Prompts.workResult(title: title, agent: record.backend.label, reply: text, finished: reply != nil))
        if let index = front.record.items.lastIndex(where: { $0.kind == .user }) {
            front.record.items[index].automatic = true
            front.record.items[index].detail = reply != nil ? "Work thread \u{201C}\(title)\u{201D} finished" : "Work thread \u{201C}\(title)\u{201D} reported"
            front.record.items[index].sidequest = id
        }
        front.onChange?(front)
        onChange?(self)
    }

    /// In the front thread: a work thread started from it, with a way to open it.
    func noteWorkStarted(_ work: ChatSession) {
        record.items.append(DisplayItem(kind: .notice, text: "Started work thread \u{201C}\(work.title)\u{201D} with \(work.record.backend.label). Its result comes back here when it finishes.",
                                        sidequest: work.id))
        onChange?(self)
    }
}
