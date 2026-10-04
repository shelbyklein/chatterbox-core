import Foundation

/// How much an agent may do without asking. Each agent has its own set, matching the
/// choices in Claude Code and the Codex app.
struct PermissionMode: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var systemImage: String
    /// Shown in orange: the agent can do anything without asking.
    var isUnrestricted = false
    var isRecommended = false
}

enum PermissionModes {
    static let claude: [PermissionMode] = [
        PermissionMode(id: "auto", title: "Auto", detail: "Claude handles permission decisions", systemImage: "wand.and.stars", isRecommended: true),
        PermissionMode(id: "default", title: "Manual", detail: "Always ask before making changes", systemImage: "hand.raised"),
        PermissionMode(id: "acceptEdits", title: "Accept edits", detail: "Automatically accept all file edits", systemImage: "pencil"),
        PermissionMode(id: "plan", title: "Plan", detail: "Create a plan before making changes", systemImage: "list.bullet.clipboard"),
        PermissionMode(id: "bypassPermissions", title: "Bypass permissions", detail: "Accepts all permissions", systemImage: "exclamationmark.shield", isUnrestricted: true),
    ]

    static let codex: [PermissionMode] = [
        PermissionMode(id: "readOnly", title: "Read only", detail: "Can look at files but not change them", systemImage: "eye"),
        PermissionMode(id: "ask", title: "Ask for approval", detail: "Always ask to edit external files and use the internet", systemImage: "hand.raised"),
        PermissionMode(id: "autoReview", title: "Approve for me", detail: "Only ask for actions detected as potentially unsafe", systemImage: "checkmark.shield"),
        PermissionMode(id: "fullAccess", title: "Full access", detail: "Unrestricted access to the internet and any file on your computer", systemImage: "exclamationmark.shield", isUnrestricted: true),
    ]

    static func modes(for backend: Backend) -> [PermissionMode] {
        backend == .claude ? claude : codex
    }

    static func mode(_ id: String, for backend: Backend) -> PermissionMode {
        let all = modes(for: backend)
        return all.first { $0.id == id } ?? all[1] // Manual / Ask for approval
    }

    /// Defaults for new chats, from Settings.
    static var defaultClaude: String {
        AppPreferences.defaults.string(forKey: "claudeDefaultMode")
            ?? ((AppPreferences.defaults.object(forKey: "codexCanEdit") as? Bool ?? false) ? "acceptEdits" : "default")
    }

    static var defaultCodex: String {
        AppPreferences.defaults.string(forKey: "codexDefaultMode")
            ?? ((AppPreferences.defaults.object(forKey: "codexCanEdit") as? Bool ?? false) ? "ask" : "readOnly")
    }
}
