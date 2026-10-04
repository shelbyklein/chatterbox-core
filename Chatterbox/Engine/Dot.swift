import Foundation

extension AppModel {
    /// Dot's chat, if it's been made.
    var dot: ChatSession? { sessions.first { $0.isDot } }

    /// Where Dot works: ~/Chatterbox/Dot (inside the data folder under tests).
    static var dotFolder:String {RuntimePaths.assistantFolder}

    /// Dot's memory: Claude Code's own memory for Dot's folder, which it loads into every
    /// session (MEMORY.md is the index; each memory is a file beside it) and keeps up itself.
    static var dotMemoryFolder:URL {RuntimePaths.assistantMemoryFolder}

    /// Dot's chat, made the first time it's asked for.
    @discardableResult
    func ensureDot() -> ChatSession {
        if let dot { return dot }
        let defaults = AppPreferences.defaults
        var record = ConversationRecord(
            model: defaults.string(forKey: "defaultModel") ?? "default",
            effort: defaults.string(forKey: "defaultEffort") ?? "",
            personality: Personality(rawValue: defaults.string(forKey: "defaultPersonality") ?? "") ?? .friendly
        )
        record.title = "Dot"
        record.isDot = true
        record.claudeMode = PermissionModes.defaultClaude
        record.activeBackend = .claude
        if defaults.string(forKey: "dotDefaultBackend") == Backend.codex.rawValue {
            record.activeBackend = .codex
            record.codex = CodexSettings(folder: Self.dotFolder, canEdit: false, mode: PermissionModes.defaultCodex)
            record.codex?.model = defaults.string(forKey: "dotDefaultModel") ?? "gpt-6.1-sol"
        }
        return insertSession(record)
    }

    /// Starts Dot's computer, and makes Dot's next message pick up its browser tools.
    func startDotComputer() async {
        if RuntimeClient.usesDaemon{RuntimeClient.shared.command("computer",body:["action":"start"]);return}
        await DotComputer.shared.start()
        dot?.restartClaudeForNewTools()
    }

    func setUpDotComputer() async {
        if RuntimeClient.usesDaemon{RuntimeClient.shared.command("computer",body:["action":"setUp"]);return}
        await DotComputer.shared.setUp()
        dot?.restartClaudeForNewTools()
    }

    func stopDotComputer() async {
        if RuntimeClient.usesDaemon{RuntimeClient.shared.command("computer",body:["action":"stop"]);return}
        await DotComputer.shared.stop()
        dot?.restartClaudeForNewTools()
    }

    /// A requested default applies once to the existing assistant, after host reconnection.
    /// Later manual model choices remain intact across launches.
    func applyRequestedDotDefault() {
        let defaults = AppPreferences.defaults
        guard defaults.bool(forKey: "dotApplyDefault"), let dot, !dot.isRunning else { return }
        if defaults.string(forKey: "dotDefaultBackend") == Backend.codex.rawValue {
            defaults.set(false, forKey: "dotApplyDefault")
            dot.setBackend(.codex)
            dot.setCodexFolder(Self.dotFolder)
            dot.setCodexModel(defaults.string(forKey: "dotDefaultModel") ?? "gpt-6.1-sol")
        }
    }

    /// What you call Dot. Its chat's title, so it shows wherever the chat does.
    var dotName: String { dot?.title ?? "Dot" }

    /// Renames Dot. Its next session (the same conversation) starts with the new name.
    func renameDot(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let dot = ensureDot()
        dot.setTitle(trimmed.isEmpty ? "Dot" : trimmed)
        Attention.shared.registerCategories()
        dot.restartClaudeForNewTools()
    }

    /// Dot's own chat, opened full size.
    func openDot() {
        #if !GOLEM_APP
        GolemIntegration.shared.open();return
        #else
        selectedID = ensureDot().id
        showingDot = false
        #endif
    }
}
