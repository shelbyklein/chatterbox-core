import Foundation

/// "Use agent computer" for an ordinary chat: its agent browses in the agent computer
/// (its own Chromium, its own sign-ins) instead of the Mac's browser, and can hand files it
/// downloads to this chat's folder. Off unless turned on, per chat.
extension ChatSession {
    var usesComputer: Bool { isDot || record.useComputer == true }

    static let computerToolNames = ["computer_status", "start_computer", "stop_computer", "show_computer",
                                    "list_computer_downloads", "hand_off_download", "list_previews"]

    func setUsesComputer(_ on: Bool) {
        guard !isDot, (record.useComputer == true) != on else { return }
        record.useComputer = on ? true : nil
        restartClaudeForNewTools()
        onChange?(self)
    }

    private var computerToolEnvironment: [String: String] {
        var env = ["CHATTERBOX_OWN_CHAT": id.uuidString, "CHATTERBOX_MCP_TOOLS": "computer"]
        for key in ["CHATTERBOX_DATA_DIR", "CHATTERBOX_AGENT_PORT"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        return env
    }

    /// Claude Code: the assistant's full config, or the computer's tools for a chat using it.
    var claudeMCPConfig: String? {
        if isDot { return dotMCPConfig }
        guard record.useComputer == true, let server = Self.dotToolServer else { return nil }
        var servers: [String: Any] = ["chatterbox": ["command": server, "args": [String](), "env": computerToolEnvironment]]
        if DotComputer.shared.isRunning { servers["computer"] = ["type": "http", "url": DotComputer.shared.toolsURL] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var claudeAllowedTools: [String] {
        if isDot { return Self.dotTools }
        guard record.useComputer == true else { return [] }
        return Self.computerToolNames.map { "mcp__chatterbox__" + $0 } + ["mcp__computer"]
    }

    /// Codex: thread config for a chat using the computer (enabled false when it isn't, so a
    /// thread that had them loses them).
    var codexComputerConfig: [String: JSON] {
        guard !isDot, let server = Self.dotToolServer else { return [:] }
        let on = record.useComputer == true
        return [
            "mcp_servers.chatterbox": ["command": .string(server), "args": [],
                                      "env": .object(computerToolEnvironment.mapValues { .string($0) }),
                                      "enabled": .bool(on), "default_tools_approval_mode": "approve"],
            "mcp_servers.computer": ["url": .string(DotComputer.shared.toolsURL),
                                    "enabled": .bool(on && DotComputer.shared.isRunning),
                                    "default_tools_approval_mode": "approve"],
        ]
    }

    var computerConfigurationKey: String {
        record.useComputer == true ? "computer:\(DotComputer.shared.isRunning)" : ""
    }

    /// Told once when the setting changes.
    func takeComputerUpdate() -> String? {
        guard !isDot else { return nil }
        let on = record.useComputer == true
        guard on != (record.sentComputerNote == true) else { return nil }
        record.sentComputerNote = on ? true : nil
        guard on else {
            return "<app_note>\nThe agent computer is turned off for this chat; its browser and hand-off tools are gone.\n</app_note>"
        }
        return """
        <app_note>
        The user turned on the agent computer for this chat. Do web work there, never in the Mac's own browser: don't drive Google Chrome or Safari on the Mac (no osascript, AppleScript, or opening URLs on the Mac) for browsing, downloading, or reading sites.
        - The computer is a separate Linux machine with its own Chromium and its own sign-ins. Browse with the computer's browser_* tools (browser_navigate, browser_snapshot, browser_click, browser_take_screenshot, …); start it with start_computer if computer_status says it's off (its tools join from your next turn).
        - When a site needs the user to sign in (Dropbox, say), call show_computer and ask them to sign in on its screen; never type their passwords.
        - Downloads land in the computer's Downloads folder. Check them with list_computer_downloads, then copy the ones you need into this project with hand_off_download (into handoff/ by default, or a folder you name). Work on them on the Mac as usual from there.
        - Local previews: list_previews shows the local sites (like SKD Studio) the user let the computer open, at their http://localhost:PORT addresses. If yours isn't listed, ask the user to turn it on in Chatterbox's Computer window.
        - Ask before buying, posting, sending, or deleting anything online.
        </app_note>
        """
    }
}
