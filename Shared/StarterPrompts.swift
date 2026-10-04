import Foundation

/// Contextual starters are drafts, never background model calls or automatic sends.
enum StarterPrompts {
    static func suggestions(project: String?, studio: String?, backend: Backend) -> [String] {
        let project = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let studio = studio?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let project, !project.isEmpty {
            let context = studio.flatMap { $0.isEmpty ? nil : " in the \($0) Studio" } ?? ""
            return [
                "Give me a quick tour of \(project)\(context), including its instructions and current work",
                "What looks unfinished or needs attention in \(project)\(context)?",
                "Help me plan the next improvement to \(project)\(context)",
            ]
        }
        if let studio, !studio.isEmpty {
            return [
                "Read \(studio)’s Studio instructions and design.md, then summarize the direction",
                "Help me plan a new piece of work for \(studio) using its existing briefs and assets",
                "Review the current work in \(studio) and suggest what to do next",
            ]
        }
        if backend == .codex {
            return [
                "Give me a quick tour of what's in this folder",
                "What looks unfinished or broken in this project?",
                "Explain how the main pieces of this code fit together",
            ]
        }
        return [
            "Help me plan a relaxed weekend in a city I've never been to",
            "What's actually new in the latest macOS release?",
            "I need to write a tricky email. Can you help me think it through?",
        ]
    }
}
