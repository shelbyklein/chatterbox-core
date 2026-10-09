import Foundation

/// Which of Golem's messages is read aloud, and which wait: each is read whole and in order, and
/// none is read twice. Foundation only, so a fixture checks it (tests/golem-ios-voice/queue).
struct ReplyQueue {
    struct Pending { let id: UUID; var text: String; var final: Bool; var then: (() -> Void)? }
    enum Turn { case read, wait, skip }

    /// Read to the end or stopped: skipped from now on.
    private(set) var completed: Set<UUID> = []
    /// Arrived while another was being read, oldest first.
    private(set) var waiting: [Pending] = []

    /// What to do with an update for `id`, given the reply being read now (nil when none is).
    /// A reply that has to wait keeps its latest text and state for when its turn comes.
    mutating func offer(_ id: UUID, text: String, final: Bool, then: (() -> Void)?, reading: UUID?) -> Turn {
        if id == reading { return .read }
        if completed.contains(id) { return .skip }
        guard reading != nil else { return .read }
        if let i = waiting.firstIndex(where: { $0.id == id }) {
            waiting[i].text = text
            waiting[i].final = waiting[i].final || final
            if let then { waiting[i].then = then }
        } else {
            waiting.append(Pending(id: id, text: text, final: final, then: then))
        }
        return .wait
    }

    /// `id` was read to the end: the next one to read, if any is waiting.
    mutating func finished(_ id: UUID) -> Pending? {
        completed.insert(id)
        return waiting.isEmpty ? nil : waiting.removeFirst()
    }

    /// Stop: the reply being read and everything waiting are dropped for good.
    mutating func stopped(_ id: UUID?) {
        if let id { completed.insert(id) }
        completed.formUnion(waiting.map(\.id))
        waiting = []
    }

    /// An explicit request to read `id` (the Listen button): read it again, and drop what's waiting.
    mutating func restart(_ id: UUID) {
        completed.remove(id)
        waiting = []
    }
}
