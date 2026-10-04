import Foundation
import Observation

/// Chatterbox's own plugins: features you can turn on and off in Settings → Plugins.
enum ChatterboxPlugin: String, CaseIterable, Identifiable {
    case nextSteps

    var id: String { rawValue }
    var title: String { "Next Steps" }
    var summary: String {
        "After each reply, suggests up to three next prompts above the message box. Press 1, 2 or 3 (or click one) to put it in the box as a draft you can edit, 0 to dismiss, Tab for the top one. Nothing is sent on its own."
    }
    var icon: String { "arrow.turn.down.right" }

    private var key: String { "plugin.\(rawValue).enabled" }
    var isOn: Bool {
        get { AppPreferences.defaults.object(forKey: key) as? Bool ?? true }
        nonmutating set { AppPreferences.defaults.set(newValue, forKey: key) }
    }
}

/// The Next Steps plugin. When a reply ends, one short call to a small model (Claude Haiku
/// for Claude chats, GPT-6-Luna for Codex ones, on your existing sign-ins) reads your last
/// message and the reply and suggests what you might ask next, including the chat's own
/// slash commands. Suggestions are kept per chat, not saved, and go away when you send.
@MainActor
@Observable
final class NextSteps {
    static let shared = NextSteps()

    static let minAnswerKey = "plugin.nextSteps.minAnswerChars"
    static let suggestCommandsKey = "plugin.nextSteps.suggestCommands"
    /// Replies shorter than this get no suggestions (a quick "done" rarely needs them).
    var minAnswerChars: Int { AppPreferences.defaults.object(forKey: Self.minAnswerKey) as? Int ?? 80 }
    var suggestCommands: Bool { AppPreferences.defaults.object(forKey: Self.suggestCommandsKey) as? Bool ?? true }

    /// Suggestions by chat, newest reply only.
    private(set) var suggestions: [UUID: [String]] = [:]
    /// The reply each chat's request is for, so a late answer for an older reply is dropped.
    @ObservationIgnored private var pending: [UUID: UUID] = [:]

    func suggestions(for session: ChatSession) -> [String] {
        ChatterboxPlugin.nextSteps.isOn ? suggestions[session.id] ?? [] : []
    }

    /// A message was sent or a turn started: the suggestions no longer apply.
    func clear(_ session: ChatSession) {
        pending[session.id] = nil
        if suggestions[session.id] != nil { suggestions[session.id] = nil }
    }

    func dismiss(_ session: ChatSession) {
        clear(session)
        session.onChange?(session)   // so the phone hides them too
    }

    /// Called as a reply ends.
    func turnEnded(_ session: ChatSession, commands: [SlashCommand]) {
        clear(session)
        guard ChatterboxPlugin.nextSteps.isOn,
              let reply = session.items.last(where: { $0.kind == .assistant && $0.phase == .final }),
              session.items.last(where: { $0.kind == .assistant })?.id == reply.id,
              reply.text.count >= minAnswerChars,
              // Golem's quiet "nothing to report" check-ins aren't worth a suggestion.
              reply.text.trimmingCharacters(in: .whitespacesAndNewlines) != "NO_REPORT",
              // Answers to what you wrote, not to Chatterbox's own check-ins and briefings.
              let asked = session.items.last(where: { $0.kind == .user }), asked.automatic != true
        else { return }
        pending[session.id] = reply.id
        let known = suggestCommands ? commands : []
        let prompt = Self.prompt(asked: asked.text, reply: reply.text, commands: known)
        let backend = session.record.backend
        let chat = session.id
        Task { [weak session] in
            let raw = await Self.ask(prompt, backend: backend)
            guard pending[chat] == reply.id else { return }
            pending[chat] = nil
            let picks = Self.parse(raw, commands: known)
            guard !picks.isEmpty else { return }
            suggestions[chat] = picks
            // A new revision, so the phone picks them up.
            if let session { session.onChange?(session) }
        }
    }

    // MARK: - Asking

    nonisolated private static let system = """
    You suggest what a user might type next in a chat with a coding or creative agent. You never use tools. \
    Answer with only a JSON array of up to three short strings, the most likely first, written as the user would type them: \
    concrete follow-ups to the reply (run, check, fix, extend, ship), at most 90 characters each. \
    A suggestion may be a slash command from the list given, as "/name arguments". \
    If nothing is worth suggesting, answer [].
    """

    private static func prompt(asked: String, reply: String, commands: [SlashCommand]) -> String {
        func clip(_ text: String, _ limit: Int) -> String {
            text.count <= limit ? text : String(text.prefix(limit / 3)) + "\n…\n" + String(text.suffix(limit * 2 / 3))
        }
        var prompt = "The user wrote:\n\(clip(asked, 3000))\n\nThe agent replied:\n\(clip(reply, 6000))\n"
        if !commands.isEmpty {
            let list = commands.prefix(60).map { "/\($0.name)" + ($0.description.isEmpty ? "" : " — " + String($0.description.prefix(80))) }
            prompt += "\nSlash commands this chat has:\n" + list.joined(separator: "\n") + "\n"
        }
        return prompt + "\nWhat might the user type next? JSON array only."
    }

    /// One short request on the chat's own family of models; nil when it doesn't work.
    private static func ask(_ prompt: String, backend: Backend) async -> String? {
        let claude = ClaudeCodeProcess.locateBinary()
        let codex = CodexAppServer.locateBinary()
        let environment = BinaryLocator.environment
        return await Task.detached(priority: .utility) { () -> String? in
            // An empty folder of its own: there's nothing to read, and nothing is saved.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-next-steps", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            switch backend {
            case .claude:
                guard let claude else { return nil }
                process.executableURL = URL(fileURLWithPath: claude)
                // No user settings: your hooks and plugins shouldn't run for a background suggestion.
                process.arguments = ["-p", "--model", "haiku", "--no-session-persistence", "--strict-mcp-config",
                                     "--disable-slash-commands", "--setting-sources", "project", "--system-prompt", system]
            case .codex:
                guard let codex else { return nil }
                process.executableURL = URL(fileURLWithPath: codex)
                process.arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "-m", "gpt-6-luna",
                                     "-c", "model_reasoning_effort=low", system + "\n\n" + prompt]
            }
            process.currentDirectoryURL = folder
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = backend == .claude ? input : FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            if backend == .claude {
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
            }
            // A stuck call shouldn't linger: suggestions are only useful right after the reply.
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// The JSON array in the answer, cleaned up: short, distinct, and no slash commands the
    /// chat doesn't have.
    static func parse(_ raw: String?, commands: [SlashCommand]) -> [String] {
        guard let raw, let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let list = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [Any] else { return [] }
        let names = Set(commands.map { $0.name.lowercased() })
        var seen: Set<String> = []
        return list.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") }
            .filter { text in
                guard !text.isEmpty, text.count <= 200, seen.insert(text.lowercased()).inserted else { return false }
                guard text.hasPrefix("/") else { return true }
                let name = text.dropFirst().split(separator: " ").first.map { $0.lowercased() } ?? ""
                return names.contains(name)
            }
            .prefix(3)
            .map { $0 }
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
