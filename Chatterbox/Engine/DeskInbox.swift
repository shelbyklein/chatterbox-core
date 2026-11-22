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
