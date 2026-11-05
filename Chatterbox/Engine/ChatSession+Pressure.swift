import Foundation

/// Work threads wait while the Mac is under pressure (MacPressure; the service's
/// PressureMonitor sets the level). A new work thread is made at once, with its task on the
/// Desk, but its first turn starts only when the Mac is back to OK; while it's overloaded, a
/// work thread doesn't start its next turn either: what Chatterbox would send it by itself (a
/// sidequest's answer) waits until the Mac is Busy or better. A reply already going is never
/// stopped, front threads are never held, nor is a thread Shelby is writing in: writing there,
/// or Start now, sends what's held at once.
///
/// Claude Code picks a turn back up by itself when a background command it started finishes;
/// that happens inside its own process, so it isn't held (holding it would mean stopping it).
@MainActor enum PressureHooks {
    /// The service's latest reading, for the companion API and the socket (nil where nothing
    /// monitors: the app, tests without a monitor).
    static var snapshot: () -> Companion.Pressure? = { nil }
    /// A work thread was held or let go: the monitor counts them again.
    static var holdsChanged: () -> Void = {}
}

extension ChatSession {
    /// Whether Chatterbox may start a turn here that needs the Mac at `need` or calmer.
    func pressureAllows(_ need: MacPressure.Level) -> Bool {
        guard isWorkThread, MacPressure.holdsWork, record.archivedAt == nil else { return true }
        // Shelby is writing here: never in the way.
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return MacPressure.current <= need
    }

    /// A new work thread's brief: sent with `send` now, or held until the Mac is OK.
    func sendFirstOrHold(_ text: String, send: (String) -> Void) {
        if record.pressureHold == nil && pressureAllows(.ok) { send(text) } else { hold(.init(text: text), until: .ok, first: true) }
    }

    /// Something Chatterbox sends this thread by itself (a sidequest's answer), labelled as its
    /// own: sent now; or, in a work thread between turns while the Mac is overloaded (or behind
    /// something already held), held until it's Busy or better. Mid-turn it joins the turn.
    func sendAutomatic(_ message: PressureHold.Message) {
        if record.pressureHold != nil || (!isRunning && !pressureAllows(.busy)) {
            hold(message, until: .busy, first: false)
        } else {
            deliver(message)
        }
    }

    /// Inner threads are headless unless summoned: a work thread whose result has gone back, or a
    /// sidequest that has returned, lets its agent process go as soon as it's idle rather than
    /// after the usual two minutes (ConversationRuntime.releaseIdleAgents). A message, a peek
    /// with something typed, or a background command finishing (which keeps it until then)
    /// starts it again, resuming the same conversation.
    var releasesAgentWhenDone: Bool {
        if isWorkThread { return !isWorkPending && unreportedWorkReply == nil && record.pressureHold == nil && !isWaitingOnYou }
        if record.sidequestOf != nil { return record.sidequestReturned != nil }
        return false
    }

    /// "Waiting: Mac busy", while something's held.
    var pressureWaitingText: String? {
        guard let hold = record.pressureHold else { return nil }
        return "Waiting: \(MacPressure.Level(rawValue: hold.level)?.label ?? "Mac busy")"
    }

    /// Whether what's held may go now: the Mac is calm enough (or holding is off).
    var pressureHoldReady: Bool {
        guard let hold = record.pressureHold else { return false }
        if !MacPressure.holdsWork || record.archivedAt != nil { return true }
        return MacPressure.current <= (MacPressure.Level(rawValue: hold.until) ?? .ok)
    }

    /// Sends what's held, in order, saying why.
    func releasePressureHold(_ why: String) {
        guard let hold = record.pressureHold else { return }
        record.pressureHold = nil
        notice(why)
        RuntimeHooks.note("Work thread \u{201C}\(title)\u{201D}: \(why)")
        for message in hold.messages { deliver(message) }
        onChange?(self)
        PressureHooks.holdsChanged()
    }

    /// Start now (the Work strip, the phone): what's held goes at once, whatever the level.
    func startHeldNow() { releasePressureHold("Started now, as you asked, though the Mac is still under pressure.") }

    /// After the level changed (and every look): held work threads whose level is back go;
    /// the rest show the level now. Answers how many still wait.
    @discardableResult
    static func releasePressureHolds(in sessions: [ChatSession]) -> Int {
        var waiting = 0
        for session in sessions {
            guard let hold = session.record.pressureHold else { continue }
            if session.pressureHoldReady {
                session.releasePressureHold(hold.first == true ? "The Mac is calm again: starting." : "The Mac is less loaded: carrying on.")
            } else {
                waiting += 1
                let now = MacPressure.current.rawValue
                if hold.level != now, MacPressure.current != .ok {
                    session.record.pressureHold?.level = now
                    session.onChange?(session)
                }
            }
        }
        return waiting
    }

    private func hold(_ message: PressureHold.Message, until need: MacPressure.Level, first: Bool) {
        let level = MacPressure.current == .ok ? MacPressure.Level.busy : MacPressure.current
        let why = PressureHooks.snapshot()?.summary
        if var existing = record.pressureHold {
            existing.messages.append(message)
            if need < (MacPressure.Level(rawValue: existing.until) ?? .ok) { existing.until = need.rawValue }
            record.pressureHold = existing
        } else {
            record.pressureHold = PressureHold(since: Date(), until: need.rawValue, level: level.rawValue, messages: [message], first: first ? true : nil)
            let state = level == .overloaded ? "overloaded" : "busy"
            notice(first
                   ? "Waiting to start: the Mac is \(state)\(why.map { " (\($0))" } ?? ""). This work thread starts by itself once the Mac is calm again, or use Start now."
                   : "Holding the next turn: the Mac is overloaded\(why.map { " (\($0))" } ?? ""). It carries on by itself once the Mac is less loaded, or use Start now.")
            RuntimeHooks.note("Work thread \u{201C}\(title)\u{201D} held: the Mac is \(state)\(first ? "; its first turn waits for OK" : "; its next turn waits for Busy or better")")
        }
        onChange?(self)
        PressureHooks.holdsChanged()
    }

    private func deliver(_ message: PressureHold.Message) {
        send(message.text)
        guard message.automatic != nil || message.detail != nil || message.sidequest != nil,
              let index = record.items.lastIndex(where: { $0.kind == .user }) else { return }
        if let automatic = message.automatic { record.items[index].automatic = automatic }
        if let detail = message.detail { record.items[index].detail = detail }
        if let sidequest = message.sidequest { record.items[index].sidequest = sidequest }
        onChange?(self)
    }
}
