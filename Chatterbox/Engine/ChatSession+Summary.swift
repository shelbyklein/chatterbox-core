import Foundation

/// A one-line "what happened last" for a project, shown under its name in the sidebar.
extension ChatSession {
    /// A question or approval is waiting for you.
    var isWaitingOnYou: Bool {
        items.contains { ($0.kind == .approval || $0.kind == .questions) && $0.approvalState == .pending }
    }

    var lastActionSummary: String? {
        if let waiting = items.last(where: { ($0.kind == .approval || $0.kind == .questions) && $0.approvalState == .pending }) {
            return waiting.kind == .questions ? "Has a question for you" : "Waiting for your approval"
        }
        if isRunning {
            // The step it's on, or else that it's thinking or writing.
            switch items.last?.kind {
            case .tool?: return items.last?.text
            case .thought?: return "Thinking\u{2026}"
            case .assistant?: return "Writing a reply\u{2026}"
            default: return "Working\u{2026}"
            }
        }
        guard let reply = items.last(where: { $0.kind == .assistant && $0.phase == .final })?.text else { return nil }
        return Self.firstSentence(of: reply)
    }

    /// The reply's first sentence as plain text, capped to fit a sidebar row.
    static func firstSentence(of markdown: String, limit: Int = 110) -> String? {
        var text = markdown
        // Drop code blocks, tables, and headings; keep the prose.
        text = text.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)
        let prose = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("|") && !$0.hasPrefix("#") && !$0.hasPrefix(">") && $0 != "---" }
        guard var line = prose.first else { return nil }
        // Markdown marks: links keep their text; bold, italics, and code marks go.
        line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`", "*"] { line = line.replacingOccurrences(of: mark, with: "") }
        // Up to the end of the first sentence.
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            line = String(line[..<end.lowerBound]) + String(line[end.lowerBound])
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : line
    }
}
