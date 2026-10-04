import CryptoKit
import Foundation

/// Dot: an assistant that runs your other chats. It's a Claude or Codex chat with Chatterbox's
/// chats as tools (chatterbox-mcp): it lists, reads, starts, messages, waits on, and stops
/// them. It can't answer approvals or question cards; those stay with you. It can suggest
/// answers for a question card, which you send with one tap.
extension ChatSession {
    var isDot: Bool { record.isDot == true }

    /// The tools Dot may use without asking: reading and messaging chats, and everything in
    /// its own computer's browser (which is walled off from the Mac).
    static let dotTools = ["list_chats", "read_chat", "send_message", "start_chat", "wait_for_reply", "stop_chat",
                                    "suggest_answer", "record_decision",
                                    "computer_status", "start_computer", "stop_computer", "show_computer",
                                    "list_computer_downloads", "hand_off_download", "list_previews"]
        .map { "mcp__chatterbox__" + $0 } + ["mcp__computer"]

    /// chatterbox-mcp, bundled next to the app.
    static var dotToolServer: String? {
        Bundle.main.url(forAuxiliaryExecutable: "chatterbox-mcp")?.path
            ?? ProcessInfo.processInfo.environment["CHATTERBOX_MCP_BINARY"]
    }

    /// The `--mcp-config` that gives Dot's Claude Code session Chatterbox's tools.
    var dotMCPConfig: String? {
        guard isDot, let server = Self.dotToolServer else { return nil }
        var env = ["CHATTERBOX_OWN_CHAT": id.uuidString]
        for key in ["CHATTERBOX_DATA_DIR", "CHATTERBOX_AGENT_PORT"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        var servers: [String: Any] = ["chatterbox": ["command": server, "args": [String](), "env": env]]
        // Its own computer's browser, while that's running.
        if DotComputer.shared.isRunning { servers["computer"] = ["type": "http", "url": DotComputer.shared.toolsURL] }
        let config: [String: Any] = ["mcpServers": servers]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Thread-local overrides: Dot's tools never leak into ordinary Codex chats.
    var dotCodexConfig: JSON {
        guard isDot, let server = Self.dotToolServer else { return .object([:]) }
        var env: [String: JSON] = ["CHATTERBOX_OWN_CHAT": .string(id.uuidString)]
        for key in ["CHATTERBOX_DATA_DIR", "CHATTERBOX_AGENT_PORT"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = .string(value) }
        }
        var config: [String: JSON] = [
            "mcp_servers.chatterbox": ["command": .string(server), "args": [], "env": .object(env),
                                      "enabled": true, "default_tools_approval_mode": "approve"],
            // Explicitly disable a previously configured computer after it stops.
            "mcp_servers.computer": ["url": .string(DotComputer.shared.toolsURL),
                                    "enabled": .bool(DotComputer.shared.isRunning),
                                    "default_tools_approval_mode": "approve"],
        ]
        // The direct ChatGPT connection when Codex has one: through a proxy, Codex loses its
        // apps (Gmail). Without a ChatGPT sign-in, Codex's own default is left alone.
        if EasyCLIProxy.codexHasChatGPTSignIn { config["model_provider"] = "openai" }
        return .object(config)
    }

    var dotCodexInstructions: String {
        Prompts.dotInstructions(name: title) + "\n\nYour shared persistent memory is at " + RuntimePaths.assistantMemoryFolder.path
            + ". Read MEMORY.md there at the start of a session and follow its index to relevant files. Use this same memory when switching between Claude and Codex; do not create a separate competing index."
    }

    var dotCodexConfigurationKey: String {
        String(decoding: (try? dotCodexConfig.encoded()) ?? Data(), as: UTF8.self) + dotCodexInstructions
    }
}
