import Foundation

/// A command offered in the message box's "/" menu: a Claude Code slash command or skill,
/// or a Codex skill.
struct SlashCommand: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var description: String
    var argumentHint: String?
    /// For Codex skills: the SKILL.md path, sent with the message so Codex loads it.
    var codexSkillPath: String?

    init(name: String, description: String, argumentHint: String? = nil, codexSkillPath: String? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.codexSkillPath = codexSkillPath
    }

    /// From Claude Code's command list: `{name, description, argumentHint}`.
    init?(claude json: JSON) {
        guard let name = json["name"]?.string else { return nil }
        self.init(name: name, description: json["description"]?.string ?? "",
                  argumentHint: json["argumentHint"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Commands whose name starts with, then contains, what's been typed after the slash.
    static func matches(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = commands.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return prefix + contains
    }

    /// Splits "/name rest" when the name is one of `commands`.
    static func leading(_ text: String, in commands: [SlashCommand]) -> (SlashCommand, String)? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard let command = commands.first(where: { $0.name == name }) else { return nil }
        return (command, String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
