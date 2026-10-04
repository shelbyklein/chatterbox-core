import Foundation

/// Context usage and queued-message bookkeeping, shared by both agents.
extension ChatSession {
    /// Progress notes for the current reply stay readable while it runs. A message sent
    /// mid-turn does not hide the notes before it; completed turns keep their folded steps.
    var liveCommentaryIDs: Set<UUID> {
        guard isRunning else { return [] }
        var ids: Set<UUID> = []
        for item in record.items.reversed() {
            if (item.kind == .user && !item.steered)
                || (item.kind == .assistant && item.phase == .final) { break }
            if item.kind == .assistant && item.phase == .commentary { ids.insert(item.id) }
        }
        return ids
    }

    // MARK: - Queued messages

    /// The agent has taken a message sent mid-turn: it now reads "Sent while working".
    func markPickedUp(_ id: UUID) {
        updateItem(id) { $0.queued = nil }
    }

    /// Nothing is waiting anymore, e.g. the agent went idle or its process ended.
    func clearQueuedMessages() {
        for index in record.items.indices where record.items[index].queued == true {
            record.items[index].queued = nil
        }
    }

    /// Claude Code echoes each message from stdin (`--replay-user-messages`) at the moment it
    /// joins the conversation, so a steered message is picked up when its echo arrives. The echo
    /// may carry extra blocks (tone, handoff), so it's matched by the message's own text.
    func claudeMessageReplayed(_ message: JSON) {
        let blocks = message["message"]?["content"]?.array ?? []
        guard !blocks.contains(where: { $0["type"]?.string == "tool_result" }) else { return }
        let text = blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
        let hasFiles = blocks.contains { $0["type"]?.string != "text" }
        let queued = record.items.filter { $0.queued == true }
        let match = queued.first { !$0.text.isEmpty && text.contains($0.text) }
            ?? queued.first { $0.text.isEmpty && hasFiles }
        if let match {
            markPickedUp(match.id)
            claudeAwaitingEcho.removeAll { !$0.isEmpty && text.contains($0) }
            return
        }
        if let sent = claudeAwaitingEcho.firstIndex(where: { $0.isEmpty ? hasFiles : text.contains($0) }) {
            claudeAwaitingEcho.remove(at: sent)
            return
        }
        // Not from here: typed on claude.ai or in the Claude app while Remote Control is on.
        // (Claude Code's own notes to itself start with a tag, and aren't shown.)
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteURL != nil, !typed.isEmpty, !typed.hasPrefix("<") {
            appendItem(DisplayItem(kind: .user, text: typed, detail: "From the Claude app"))
            if !isRunning { isRunning = true }
            onChange?(self)
        }
    }

    // MARK: - Context usage

    /// Per-request usage from Claude Code: input plus cache reads and writes is everything the
    /// model was sent, which is how full the context is.
    func claudeUpdateContext(usage: JSON?) {
        guard let usage else { return }
        let parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
        let used = parts.compactMap { usage[$0]?.int }.reduce(0, +)
        guard used > 0 else { return }
        contextUsage[.claude] = ContextUsage(used: used, window: contextUsage[.claude]?.window)
    }

    /// `compact_boundary` (from /compact or automatic compaction) says how big the context is
    /// afterwards, so the meter drops right away instead of after the next request.
    func claudeCompacted(_ message: JSON) {
        let meta = message["compact_metadata"]
        guard let after = meta?["post_tokens"]?.int else { return }
        contextUsage[.claude] = ContextUsage(used: after, window: contextUsage[.claude]?.window)
        let before = meta?["pre_tokens"]?.int
        let auto = meta?["trigger"]?.string == "auto"
        let sizes = before.map { " from \(Self.tokens($0)) to \(Self.tokens(after)) tokens" } ?? " to \(Self.tokens(after)) tokens"
        notice((auto ? "The conversation was compacted automatically" : "Compacted the conversation") + sizes + ".")
        onChange?(self)
    }

    private static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// The `result` message names each model's context window in `modelUsage`. Sub-tasks can
    /// use a smaller model, so the one that read the most is taken as the chat's.
    func claudeUpdateContextWindow(result: JSON) {
        let models = result["modelUsage"]?.object ?? [:]
        let main = models.values.max { a, b in
            let read: (JSON) -> Int = { ($0["inputTokens"]?.int ?? 0) + ($0["cacheReadInputTokens"]?.int ?? 0) + ($0["cacheCreationInputTokens"]?.int ?? 0) }
            return read(a) < read(b)
        }
        guard let window = main?["contextWindow"]?.int, window > 0 else { return }
        contextUsage[.claude] = ContextUsage(used: contextUsage[.claude]?.used ?? 0, window: window)
    }

    /// Codex's `thread/tokenUsage/updated`: `last` is the latest request, `modelContextWindow`
    /// the window it counts against.
    func codexUpdateContext(_ params: JSON) {
        let usage = params["tokenUsage"]
        guard let used = usage?["last"]?["totalTokens"]?.int, used > 0 else { return }
        contextUsage[.codex] = ContextUsage(used: used, window: usage?["modelContextWindow"]?.int ?? contextUsage[.codex]?.window)
    }
}
