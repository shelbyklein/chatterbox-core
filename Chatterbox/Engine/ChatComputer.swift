import Foundation

/// Compatibility for conversations that previously used Chatterbox's retired Docker VM.
/// Native ChatGPT computer-use/cua_repl configuration is deliberately untouched.
extension ChatSession {
    var claudeMCPConfig: String? { isDot ? dotMCPConfig : nil }
    var claudeAllowedTools: [String] { isDot ? Self.dotTools : [] }

    var codexComputerConfig: [String: JSON] {
        guard !isDot, let server = Self.dotToolServer else { return [:] }
        return [
            "mcp_servers.chatterbox": ["command": .string(server), "args": [], "enabled": false],
            "mcp_servers.computer": ["url": "http://127.0.0.1:47332/mcp", "enabled": false],
        ]
    }

    var computerConfigurationKey: String { "vm-retired-v1" }

    func takeComputerUpdate() -> String? {
        guard !isDot, record.useComputer == true || record.sentComputerNote == true else { return nil }
        record.useComputer = nil
        record.sentComputerNote = nil
        return "<app_note>The Chatterbox Agent Computer VM feature was removed. Its browser and handoff tools are unavailable. Native ChatGPT computer use is separate; use only tools actually available in this session.</app_note>"
    }
}
