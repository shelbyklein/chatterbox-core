import Foundation

/// The always-on Desk's inbox (plans/always-on-desk.md, after Anthropic's "Building always-on
/// agents"): every change a watcher sees (a ClickUp task or comment, a USA Archery email, a
/// timer coming due) lands here as an event. One worker takes everything pending as a batch,
/// hands it to a Desk agent run, and marks it done when the run succeeds. The file is the
/// source of truth: a crash mid-run leaves its events `running`, and they're tried again on
/// the next start (at most `maxAttempts`).
struct DeskEvent: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case pending, running, done, failed }
    var id = UUID()
    /// "clickup", "mail", "timer" or "you".
    var source: String
    /// The source's own id for this change (a ClickUp comment id, a task id + its update time,
    /// a Mail message id): the same change twice is dropped.
    var sourceEventID: String
    /// "task.new", "task.updated", "comment.new", "email.new", "timer.followup", "timer.digest".
    var kind: String
    var title: String
    var detail: String = ""
    var link: String? = nil
    /// The Desk task it concerns, when known (a follow-up's).
    var task: UUID? = nil
    var receivedAt = Date()
    var status: Status = .pending
    var attempts = 0
    var finishedAt: Date? = nil
    var problem: String? = nil
}

@MainActor
final class DeskInbox {
    static let shared = DeskInbox()

    /// How long the worker waits after an event for more to arrive, so a burst is one run.
    static var settle: Duration = .seconds(60)
    static let maxAttempts = 3
    /// Finished events are kept this long (for de-duplication and the status line).
    static let keepFor: TimeInterval = 30 * 86_400

    private(set) var events: [DeskEvent] = []
    /// Runs a batch: the Desk agent (DeskAgent); tests replace it. Throws if the run failed.
    var runner: ([DeskEvent]) async throws -> Void = { _ in throw RuntimeFailure("The Desk agent isn't set up.") }
    /// Something changed (the status line).
    var onChange: () -> Void = {}

    private let file: URL
    private var running = false
    private var wakeTask: Task<Void, Never>?

    init(file: URL = RuntimePaths.data.appendingPathComponent("Desk/inbox.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? Companion.decoder.decode([DeskEvent].self, from: data) {
            // A run cut short by a crash or restart: its events go round again.
            events = saved.map { var event = $0; if event.status == .running { event.status = .pending }; return event }
        }
    }

    var pending: [DeskEvent] { events.filter { $0.status == .pending } }
    var isRunning: Bool { running }

    /// Adds a change; false when it's one already seen (same source and source id).
    @discardableResult
    func add(_ event: DeskEvent) -> Bool {
        guard !events.contains(where: { $0.source == event.source && $0.sourceEventID == event.sourceEventID }) else { return false }
        events.append(event)
        save()
        onChange()
        wake()
        return true
    }

    /// Starts the worker after the settle time, unless it's already waiting or running.
    func wake(now: Bool = false) {
        guard wakeTask == nil else { return }
        wakeTask = Task { @MainActor [weak self] in
            if !now { try? await Task.sleep(for: Self.settle) }
            guard let self else { return }
            self.wakeTask = nil
            await self.work()
        }
    }

    /// Runs batches until nothing is pending. One at a time: events that arrive during a run
    /// go in the next.
    func work() async {
        guard !running else { return }
        running = true
        defer { running = false; onChange() }
        while true {
            let batch = pending
            guard !batch.isEmpty else { return }
            let ids = Set(batch.map(\.id))
            update(ids) { $0.status = .running; $0.attempts += 1 }
            do {
                try await runner(events.filter { ids.contains($0.id) })
                update(ids) { $0.status = .done; $0.finishedAt = Date(); $0.problem = nil }
            } catch {
                let reason = error.localizedDescription
                update(ids) { event in
                    event.problem = reason
                    event.status = event.attempts >= Self.maxAttempts ? .failed : .pending
                    if event.status == .failed { event.finishedAt = Date() }
                }
                RuntimeHooks.note("Desk run failed (\(batch.count) events): \(reason)")
                // Wait before trying the same events again.
                if events.contains(where: { ids.contains($0.id) && $0.status == .pending }) {
                    running = false
                    wake()
                    return
                }
            }
        }
    }

    private func update(_ ids: Set<UUID>, _ change: (inout DeskEvent) -> Void) {
        for index in events.indices where ids.contains(events[index].id) { change(&events[index]) }
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        events.removeAll { ($0.status == .done || $0.status == .failed) && ($0.finishedAt ?? $0.receivedAt) < cutoff }
        save()
        onChange()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Companion.encoder.encode(events).write(to: file, options: .atomic)
        } catch {
            RuntimeHooks.note("The Desk inbox couldn't save: \(error.localizedDescription)")
        }
    }
}

/// The always-on Desk agent's memory (`Desk/memory`), after the guide's layout: what every run
/// reads (`instructions.md`, `index.md`, `reported.md`), and folders it opens when needed
/// (`notes/`, `progress/`). The dispatcher appends to `reported.md`; the agent keeps the rest.
struct DeskMemory {
    var directory: URL = RuntimePaths.data.appendingPathComponent("Desk/memory")
    /// The newest lines of `reported.md` a run sees.
    static let reportedLines = 60

    func ensure() {
        let fm = FileManager.default
        for folder in ["notes", "progress"] { try? fm.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let seeds = [
            "instructions.md": "# How the Desk works for Shelby\n\nRead-only on ClickUp and Outlook; prepare work, never act outbound. Quiet by default: urgent means it needs Shelby now or is due within 48 hours.\n",
            "index.md": "# Index\n\nOne line per note or progress file: path — what it holds.\n",
            "reported.md": "# Already told Shelby\n\n",
        ]
        for (name, text) in seeds where !fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            try? text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    func read(_ name: String) -> String { (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    func appendReported(_ line: String, at date: Date = Date()) {
        ensure()
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false))
        let file = directory.appendingPathComponent("reported.md")
        let text = read("reported.md") + "- \(stamp) \(line.replacingOccurrences(of: "\n", with: " "))\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// What a run starts with: the three files it always reads (reported.md's newest lines).
    func promptText() -> String {
        ensure()
        let reported = read("reported.md").split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.reportedLines).joined(separator: "\n")
        return """
            --- instructions.md ---
            \(read("instructions.md").trimmingCharacters(in: .whitespacesAndNewlines))
            --- index.md ---
            \(read("index.md").trimmingCharacters(in: .whitespacesAndNewlines))
            --- reported.md (newest) ---
            \(reported.trimmingCharacters(in: .whitespacesAndNewlines))
            """
    }
}

/// The Desk agent's own follow-ups ("check back on this Tuesday"): each, when due, becomes an
/// inbox event; timers never start a run themselves (`Desk/timers.json`).
@MainActor
final class DeskTimers {
    struct Timer: Codable, Equatable, Identifiable {
        var id = UUID()
        var task: String?
        var note: String
        var due: Date
    }
    static let shared = DeskTimers()
    private(set) var timers: [Timer] = []
    private let file: URL
    var inbox: () -> DeskInbox = { .shared }

    init(file: URL = RuntimePaths.data.appendingPathComponent("Desk/timers.json")) {
        self.file = file
        timers = (try? Data(contentsOf: file)).flatMap { try? Companion.decoder.decode([Timer].self, from: $0) } ?? []
    }

    func add(task: String?, note: String, due: Date) -> Timer {
        let timer = Timer(task: task, note: note, due: due)
        timers.append(timer)
        save()
        return timer
    }

    /// Due follow-ups go to the inbox once each (one that came due while the Mac slept fires
    /// once on wake). Returns how many fired.
    @discardableResult
    func fireDue(now: Date = Date()) -> Int {
        let due = timers.filter { $0.due <= now }
        guard !due.isEmpty else { return 0 }
        for timer in due {
            inbox().add(DeskEvent(source: "timer", sourceEventID: "timer:\(timer.id.uuidString)", kind: "timer.followup",
                                  title: "Follow-up: \(timer.note)", detail: timer.task.map { "Desk task: \($0)" } ?? "",
                                  task: timer.task.flatMap(UUID.init(uuidString:))))
        }
        timers.removeAll { $0.due <= now }
        save()
        return due.count
    }

    /// "2026-11-24T09:00", an ISO date, or "+3d", "+4h", "+30m" from now.
    static func parse(_ text: String, now: Date = Date()) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("+"), let unit = t.last, let n = Double(t.dropFirst().dropLast()) {
            let seconds: Double? = switch unit { case "m": 60; case "h": 3600; case "d": 86_400; default: nil }
            return seconds.map { now.addingTimeInterval(n * $0) }
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return format == "yyyy-MM-dd" ? date.addingTimeInterval(9 * 3600) : date }
        }
        return nil
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Companion.encoder.encode(timers).write(to: file, options: .atomic)
    }
}

/// What the Desk agent tells Shelby (`Desk/outbox.json`), paced: urgent lines go to the phone
/// at once (held through quiet hours), the rest wait for one morning digest on weekdays. Each
/// line sent is added to the agent's `reported.md`, so it isn't told twice.
@MainActor
final class DeskOutbox {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var urgent: Bool
        var task: String?
        var createdAt = Date()
        var sentAt: Date?
    }
    static let shared = DeskOutbox()
    private(set) var items: [Item] = []
    private(set) var lastDigest: Date?
    private let file: URL
    var memory = DeskMemory()
    /// Sends one phone notification; the service sets it to MobilePush (DeskAgent), tests replace it.
    var post: (_ title: String, _ body: String) -> Void = { title, _ in RuntimeHooks.note("Desk notification (not sent): \(title)") }
    var calendar = Calendar.current

    static var digestHour: Int { AppPreferences.defaults.object(forKey: "deskDigestHour") as? Int ?? 8 }
    static var digestMinute: Int { AppPreferences.defaults.object(forKey: "deskDigestMinute") as? Int ?? 30 }
    /// No pushes from 9 pm to 7 am; urgent lines wait for morning.
    static let quietStart = 21, quietEnd = 7

    private struct Saved: Codable { var items: [Item]; var lastDigest: Date? }

    init(file: URL = RuntimePaths.data.appendingPathComponent("Desk/outbox.json")) {
        self.file = file
        if let saved = (try? Data(contentsOf: file)).flatMap({ try? Companion.decoder.decode(Saved.self, from: $0) }) {
            items = saved.items; lastDigest = saved.lastDigest
        }
    }

    func add(_ text: String, urgent: Bool, task: String?, now: Date = Date()) {
        items.append(Item(text: text, urgent: urgent, task: task, createdAt: now))
        save()
        dispatch(now: now)
    }

    func isQuiet(_ now: Date) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= Self.quietStart || hour < Self.quietEnd
    }

    /// The digest due at or before `now` on a weekday, if it hasn't gone yet.
    func digestDue(_ now: Date) -> Bool {
        guard !calendar.isDateInWeekend(now) else { return false }
        guard let today = calendar.date(bySettingHour: Self.digestHour, minute: Self.digestMinute, second: 0, of: now), now >= today else { return false }
        return lastDigest.map { $0 < today } ?? true
    }

    /// Sends what's due: urgent lines now (outside quiet hours), and the digest at its time.
    func dispatch(now: Date = Date()) {
        var changed = false
        if !isQuiet(now) {
            for index in items.indices where items[index].urgent && items[index].sentAt == nil {
                post("Desk", items[index].text)
                items[index].sentAt = now
                memory.appendReported(items[index].text, at: now)
                changed = true
            }
        }
        if digestDue(now) {
            let waiting = items.indices.filter { !items[$0].urgent && items[$0].sentAt == nil }
            if !waiting.isEmpty {
                let lines = waiting.map { "• " + items[$0].text }
                post("Desk: \(waiting.count) update\(waiting.count == 1 ? "" : "s") since yesterday", lines.joined(separator: "\n"))
                for index in waiting { items[index].sentAt = now; memory.appendReported(items[index].text, at: now) }
            }
            lastDigest = now
            changed = true
        }
        if changed {
            let cutoff = now.addingTimeInterval(-14 * 86_400)
            items.removeAll { ($0.sentAt ?? now) < cutoff }
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Companion.encoder.encode(Saved(items: items, lastDigest: lastDigest)).write(to: file, options: .atomic)
    }
}
