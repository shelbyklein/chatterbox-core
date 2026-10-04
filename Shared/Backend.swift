import Foundation

/// Which agent answers: Claude Code or Codex. Shared with the iPhone app.
enum Backend: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    /// Original provider SVG marks, rendered as monochrome asset templates.
    var iconName: String { self == .claude ? "AgentClaude" : "AgentCodex" }
    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
