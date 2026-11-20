import Foundation

/// Which agent answers: Claude Code, Codex, or Gemini (Google's Antigravity CLI, `agy`).
/// Shared with the iPhone app.
enum Backend: String, Codable, CaseIterable, Identifiable {
    case claude, codex, gemini
    var id: String { rawValue }
    /// Provider marks, rendered as monochrome asset templates.
    var iconName: String {
        switch self {
        case .claude: "AgentClaude"
        case .codex: "AgentCodex"
        case .gemini: "AgentGemini"
        }
    }
    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }
    /// The agent a sidequest goes to by default: Claude and Codex hand to each other, and
    /// Gemini hands to Claude.
    var other: Backend { self == .claude ? .codex : .claude }
    /// An agent's name from its raw value ("codex" → "Codex"); Claude for anything unknown.
    static func label(_ raw: String?) -> String { raw.flatMap(Backend.init(rawValue:))?.label ?? "Claude" }
    /// The instructions file each agent reads from a project folder.
    var instructionsFile: String { self == .claude ? "CLAUDE.md" : self == .codex ? "AGENTS.md" : "GEMINI.md" }
}

/// Effort, named the same everywhere (the Mac's chips and menus, the phone's slider and
/// header): Minimal · Low · Medium · High · Extra High · Max.
enum EffortNames {
    static func label(_ effort: String) -> String { effort == "xhigh" ? "Extra High" : effort.capitalized }
}
