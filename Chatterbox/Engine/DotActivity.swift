#if GOLEM_APP
import Foundation
import Observation
import UserNotifications

/// Makes Dot active: it checks in on its own at set times (weekday mornings and afternoons
/// by default) and when a chat starts waiting on you. A check-in with nothing to report
/// collapses to one quiet line; one with news reaches you as a notification. It runs while
/// Chatterbox is open (on a Mac that's awake).
@MainActor
@Observable
final class DotActivity {
    static let shared = DotActivity()

    static let checkInsKey = "dotCheckIns"
    static let timesKey = "dotCheckInTimes"
    static let watchWaitingKey = "dotWatchWaiting"
    private static let doneKey = "dotCheckInsDone"
    /// What Dot answers when there's nothing to tell.
    static let quietReply = "NO_REPORT"

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var timer: Timer?
    /// Waiting items already handed to Dot.
    @ObservationIgnored private var toldAbout: Set<UUID> = []

    var checkInsOn: Bool { AppPreferences.defaults.object(forKey: Self.checkInsKey) as? Bool ?? true }
    var watchWaiting: Bool { AppPreferences.defaults.object(forKey: Self.watchWaitingKey) as? Bool ?? true }
    static let summarizeFinishedKey = "dotSummarizeFinished"
    var summarizeFinished: Bool { AppPreferences.defaults.object(forKey: Self.summarizeFinishedKey) as? Bool ?? true }

    /// Check-in times as minutes after midnight (8:00 and 15:00 unless changed).
    static var times: [Int] {
        get { (AppPreferences.defaults.array(forKey: timesKey) as? [Int]) ?? [8 * 60, 15 * 60] }
        set { AppPreferences.defaults.set(newValue.sorted(), forKey: timesKey) }
    }

    func start(model: AppModel) {
        self.model = model
        // Whatever was waiting before launch isn't news to hand Dot.
        for session in model.sessions {
            for item in session.items where (item.kind == .approval || item.kind == .questions) && item.approvalState == .pending {
                toldAbout.insert(item.id)
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    // MARK: - Check-ins

    /// Runs a check-in that's due: weekdays, at or after its time, not yet done today, and
    /// no more than three hours late (a Mac that was asleep at 8 catches up when it wakes).
    private func tick() {
        guard checkInsOn, let model, !Calendar.current.isDateInWeekend(Date()) else { return }
        let now = Date()
        let minutes = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        let today = Self.dayKey(now)
        var done = Set(AppPreferences.defaults.stringArray(forKey: Self.doneKey) ?? []).filter { $0.hasPrefix(today) }
        guard let slot = Self.times.last(where: { $0 <= minutes && minutes - $0 <= 180 && !done.contains("\(today) \($0)") }) else { return }
        let dot = model.ensureDot()
        guard !dot.isRunning else { return }   // Try again next minute.
        // Earlier slots today count as covered by this one.
        for time in Self.times where time <= slot { done.insert("\(today) \(time)") }
        AppPreferences.defaults.set(Array(done), forKey: Self.doneKey)
        checkIn(dot, label: slot < 12 * 60 ? "Morning check-in" : "Afternoon check-in", at: slot)
    }

    /// A check-in right away (from Settings).
    func checkInNow() {
        guard let model else { return }
        let dot = model.ensureDot()
        guard !dot.isRunning else { return }
        let now = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        checkIn(dot, label: "Check-in", at: now)
    }

    private func checkIn(_ dot: ChatSession, label: String, at minutes: Int) {
        let time = String(format: "%d:%02d", minutes / 60, minutes % 60)
        dot.sendAutomatic(label: "\(label) \u{00B7} \(time)", text: """
        <app_note>
        \(label), \(time). This is a scheduled check-in, not a message from the user. Do your standing jobs from your memory: look for important email, USA Archery changes in ClickUp, and chats that finished or are waiting on the user (list_chats). Check only what your tools reach; don't guess.
        If nothing needs the user, reply with exactly \(Self.quietReply) and nothing else. Otherwise reply with a short briefing, most important first. It reaches the user as a notification, so lead with the point.
        </app_note>
        """)
    }

    // MARK: - Chats waiting on you

    /// Called on every chat change: a new approval or question in another chat goes to Dot.
    func noticeWaiting(in session: ChatSession) {
        guard watchWaiting, !session.isDot, let model else { return }
        let waiting = session.items.filter { ($0.kind == .approval || $0.kind == .questions) && $0.approvalState == .pending && !toldAbout.contains($0.id) }
        guard let item = waiting.first else { return }
        waiting.forEach { toldAbout.insert($0.id) }
        let what = item.kind == .questions
            ? "questions: " + (item.questions ?? []).map(\.question).joined(separator: " / ")
            : "approval: " + item.text + (item.detail.map { " (" + String($0.prefix(300)) + ")" } ?? "")
        let name = session.record.projectFolder != nil ? session.projectName : session.title
        model.ensureDot().sendAutomatic(label: "\u{201C}\(name)\u{201D} is waiting on you", text: """
        <app_note>
        The chat \u{201C}\(name)\u{201D} [\(session.id.uuidString)] is now waiting on the user for \(what). Read it (read_chat) and brief the user: what it has done so far, what exactly it needs from them, and your suggestion if you have one. For a question card, when you can tell what the user would pick, put your pick on the card with suggest_answer (with a one-line reason) so they can send it in one tap; skip it when the choice is theirs to make (money, access, deleting, deploying, publishing, anything personal) or you aren't confident. Keep it to a few short lines. It reaches them as a notification, so lead with what's needed. You can't send answers or approvals; only the user can.
        </app_note>
        """)
    }

    // MARK: - Finished work

    /// Chats that finished while Dot was busy, to report once it's free.
    @ObservationIgnored private var finishedWhileBusy: [UUID] = []

    /// A chat's reply ended. If it was real work (a minute or more, or tools), or Dot handed
    /// it the work, Dot reads it and sends you a summary in place of the usual alert. Not for
    /// the chat you're looking at. Returns whether Dot's summary replaces the alert.
    func chatFinished(_ session: ChatSession, watching: Bool) -> Bool {
        guard let model, !session.isDot else { return false }
        let followed = session.record.dotFollowing == true
        session.record.dotFollowing = nil
        guard followed || summarizeFinished, !watching, !session.isWaitingOnYou else { return false }
        let lastPrompt = session.record.items.lastIndex(where: { $0.kind == .user && !$0.steered }) ?? 0
        let turn = session.record.items[lastPrompt...]
        let worked = turn.compactMap(\.workedSeconds).max() ?? 0
        guard followed || worked >= 60 || turn.contains(where: { $0.kind == .tool }) else { return false }
        if !finishedWhileBusy.contains(session.id) { finishedWhileBusy.append(session.id) }
        let dot = model.ensureDot()
        // Busy: likely waiting on this very reply; it's reported after Dot's turn otherwise.
        guard !dot.isRunning else { return true }
        DispatchQueue.main.async { [weak self] in self?.reportFinished(to: dot) }
        return true
    }

    /// After Dot's own turn: report chats that finished meanwhile, unless Dot already read them.
    func dotTurnEnded(_ dot: ChatSession) {
        guard !finishedWhileBusy.isEmpty else { return }
        let start = dot.record.items.lastIndex(where: { $0.kind == .user }) ?? 0
        let readOne = dot.record.items[start...].contains { item in
            item.kind == .tool && ["wait_for_reply", "wait for reply", "read_chat", "read chat"].contains { item.text.localizedCaseInsensitiveContains($0) }
        }
        if readOne, finishedWhileBusy.count == 1 { finishedWhileBusy = []; return }
        DispatchQueue.main.async { [weak self] in self?.reportFinished(to: dot) }
    }

    /// One message for every chat that finished: Dot reads each and tells you what got done.
    private func reportFinished(to dot: ChatSession) {
        guard let model, !dot.isRunning, !finishedWhileBusy.isEmpty else { return }
        let sessions = finishedWhileBusy.compactMap { id in model.sessions.first { $0.id == id } }
        finishedWhileBusy = []
        guard !sessions.isEmpty else { return }
        let names = sessions.map { Self.name(of: $0) }
        let list = sessions.map { "\u{201C}\(Self.name(of: $0))\u{201D} [\($0.id.uuidString)]" }.joined(separator: ", ")
        dot.sendAutomatic(label: names.count == 1 ? "\u{201C}\(names[0])\u{201D} finished" : "\(names.count) chats finished", text: """
        <app_note>
        Finished just now: \(list). Read \(sessions.count == 1 ? "it" : "each") (read_chat) and give the user a summary of what was done: the result, what changed (files, pages, commits, deploys), and anything they need to check, do, or decide next. A few short lines per chat, under its name, most important first. It reaches them as a notification, so lead with the outcome. Don't reply \(Self.quietReply); they want to hear about finished work.
        </app_note>
        """)
    }

    private static func name(of session: ChatSession) -> String {
        session.record.projectFolder != nil ? session.projectName : session.title
    }

    // MARK: - After Dot answers

    /// Tidies an automatic turn: nothing to report becomes one quiet line; a report goes to
    /// you as a notification. Returns whether Chatterbox's usual "finished" alert should be skipped.
    func finishedAutomaticTurn(_ dot: ChatSession) -> Bool {
        guard let prompt = dot.record.items.lastIndex(where: { $0.kind == .user }),
              dot.record.items[prompt].automatic == true else { return false }
        let replies = dot.record.items.indices.filter { $0 > prompt && dot.record.items[$0].kind == .assistant }
        let text = replies.map { dot.record.items[$0].text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasSuffix(Self.quietReply) && text.count < Self.quietReply.count + 40 {
            // Nothing to tell: the prompt row says so, and the rest of the turn is cleared away.
            let label = dot.record.items[prompt].detail ?? "Check-in"
            dot.record.items[prompt].detail = label + " \u{00B7} nothing needs you"
            // (Email-watch lines that landed meanwhile stay.)
            let rest = dot.record.items[(prompt + 1)...].filter { $0.kind == .notice && $0.text.hasPrefix("Email for you") }
            dot.record.items.replaceSubrange((prompt + 1)..., with: rest)
            return true
        }
        notify(dot, label: dot.record.items[prompt].detail ?? "Check-in", body: text)
        return true
    }

    private func notify(_ dot: ChatSession, label: String, body: String) {
        MobilePush.shared.post(title: "\(dot.title) · \(label)", body: body, chat: dot.id, kind: "golem")
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = dot.title
        content.subtitle = label
        content.body = String(body.prefix(900))
        content.sound = .default
        content.threadIdentifier = dot.id.uuidString
        content.userInfo = ["session": dot.id.uuidString, "item": ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension ChatSession {
    /// A message from Chatterbox to Dot (a check-in, a chat waiting on you), shown as a
    /// small labeled row rather than as something you typed.
    func sendAutomatic(label: String, text: String) {
        GolemJournal.shared.add(.activity, title: label)
        send(text)
        if let index = record.items.lastIndex(where: { $0.kind == .user }) {
            record.items[index].automatic = true
            record.items[index].detail = label
        }
        automaticTurn = true
        onChange?(self)
    }
}

#endif
