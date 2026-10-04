import Foundation

/// A transcript row: one item, or (with grouping on, Settings → Appearance) a run of steps
/// between your message and the reply (tools, notes, thinking) collapsed into one row.
enum TranscriptRow: Identifiable, Equatable {
    case item(DisplayItem)
    case steps([DisplayItem], seconds: Int?, active: Bool)

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .steps(let steps, _, _): steps[0].id
        }
    }
}

/// Turns a chat's items into transcript rows. `page` works from the end of the history, so a
/// long chat isn't walked in full on every render (each streamed token re-renders); `rows`
/// is the whole history, the same way.
struct TranscriptPaging {
    var showThinking: Bool
    var groupSteps: Bool
    var isRunning: Bool
    /// Notes the agent is writing in the current turn, shown as they are rather than grouped.
    var liveNotes: Set<UUID> = []

    func isHidden(_ item: DisplayItem) -> Bool { !showThinking && item.kind == .thought }

    func isStep(_ item: DisplayItem) -> Bool {
        guard groupSteps else { return false }
        switch item.kind {
        case .tool, .thought, .notice: return true
        case .assistant: return item.phase == .commentary && !liveNotes.contains(item.id)
        default: return false
        }
    }

    /// Every row, oldest first.
    func rows(_ items: [DisplayItem]) -> [TranscriptRow] {
        group(items.filter { !isHidden($0) })
    }

    /// The newest `limit` rows, the index of the first item they draw from, and whether any
    /// shown items come before it.
    func page(_ items: [DisplayItem], limit: Int) -> (rows: [TranscriptRow], start: Int, hasEarlier: Bool) {
        // Walk back counting rows as grouping makes them: a run of steps is always one row.
        var count = 0, inRun = false, start = items.count
        var index = items.count - 1
        while index >= 0 && count < limit {
            let item = items[index]
            if !isHidden(item) {
                if isStep(item) {
                    if !inRun { inRun = true; count += 1 }
                } else {
                    inRun = false
                    count += 1
                }
            }
            start = index
            index -= 1
        }
        // Stopped partway into a run of steps: the whole run is that one row.
        while inRun, start > 0, isHidden(items[start - 1]) || isStep(items[start - 1]) { start -= 1 }
        var rows = rows(Array(items[start...]))
        if rows.count > limit { rows = Array(rows.suffix(limit)) }
        let hasEarlier = items[..<start].contains { !isHidden($0) }
        return (rows, start, hasEarlier)
    }

    private func group(_ items: [DisplayItem]) -> [TranscriptRow] {
        guard groupSteps else { return items.map(TranscriptRow.item) }
        var rows: [TranscriptRow] = []
        var run: [DisplayItem] = []
        func flush(before next: DisplayItem?) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            // A lone step stays as it is; the reply after a run knows how long it took.
            if run.count == 1 { rows.append(.item(run[0])); return }
            rows.append(.steps(run, seconds: next?.workedSeconds, active: next == nil && isRunning))
        }
        for item in items {
            if isStep(item) { run.append(item) } else { flush(before: item); rows.append(.item(item)) }
        }
        flush(before: nil)
        return rows
    }
}
