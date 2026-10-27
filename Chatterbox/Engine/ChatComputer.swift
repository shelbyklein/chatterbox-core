import Foundation

/// Compatibility for conversations that previously used Chatterbox's retired Docker VM.
/// Native ChatGPT computer-use/cua_repl configuration is deliberately untouched.
extension ChatSession {
    var codexComputerConfig: [String: JSON] {
        [
            "mcp_servers.computer": ["url": "http://127.0.0.1:47332/mcp", "enabled": false],
        ]
    }

    var computerConfigurationKey: String { "vm-retired-v1" }

    func takeComputerUpdate() -> String? {
        guard record.useComputer == true || record.sentComputerNote == true else { return nil }
        record.useComputer = nil
        record.sentComputerNote = nil
        return "<app_note>The Chatterbox Agent Computer VM feature was removed. Its browser and handoff tools are unavailable. Native ChatGPT computer use is separate; use only tools actually available in this session.</app_note>"
    }
}
