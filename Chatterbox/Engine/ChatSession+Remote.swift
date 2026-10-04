import Foundation

/// Remote Control: Claude Code makes a chat's session reachable on claude.ai and in the
/// Claude app, so it can be read and continued from a phone. It lasts while the chat's
/// Claude Code process runs.
extension ChatSession {
    /// Settings > General: new Claude chats turn Remote Control on when they start.
    static let remoteControlKey = "remoteControlClaudeChats"
    static var remoteControlByDefault: Bool { AppPreferences.defaults.bool(forKey: remoteControlKey) }

    var wantsRemoteControl: Bool {
        record.backend == .claude && (record.remoteControl ?? Self.remoteControlByDefault)
    }

    /// Turns Remote Control on or off for this chat. On starts its Claude Code session
    /// right away, so the chat is reachable before you send anything.
    func setRemoteControl(_ on: Bool) {
        if let remoteCommand {remoteCommand("remoteControl",["enabled":.bool(on)]);return}
        record.remoteControl = on
        onChange?(self)
        if on {
            if let process = claudeProcess, process.isRunning {
                Task { await enableRemoteControl() }
            } else {
                do { _ = try claudeStartForRemoteControl() } catch { notice(error.localizedDescription) }
            }
        } else if let process = claudeProcess, process.isRunning {
            process.controlNow("remote_control", ["enabled": false])
            remoteURL = nil
        }
    }

    func enableRemoteControl() async {
        guard let process = claudeProcess, process.isRunning else { return }
        do {
            let response = try await process.control("remote_control", ["enabled": true, "name": .string("Chatterbox \u{00B7} \(title)")])
            remoteURL = response["session_url"]?.string.flatMap(URL.init(string:))
        } catch {
            notice("Couldn't turn on Remote Control: \(error.localizedDescription)")
        }
    }
}
