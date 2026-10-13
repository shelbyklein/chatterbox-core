import Foundation

/// What the agents load on their own, outside Chatterbox: Claude Code's servers, plugins and
/// skills (~/.claude.json, ~/.claude, a project's .mcp.json and .claude/skills) and Codex's
/// (~/.codex/config.toml, its skill folders). Read only: Chatterbox never writes these files.
/// The Tools settings list them, can turn them off per level, and can import a server.
struct DiscoveredTool: Identifiable, Hashable {
    enum Kind: String { case server, skill, connector }
    enum Source: String { case claude = "Claude", codex = "Codex", project = "Project file" }
    var kind: Kind
    var source: Source
    /// As the agents name it ("inspo", "impeccable", "Gmail").
    var name: String
    /// Command or URL, or the skill's folder.
    var detail: String
    var agents: [Backend]
    /// Off in the agent's own config already.
    var enabledThere = true
    /// The key `ToolSet.off` uses to turn it off.
    var offKey: String
    /// What Import copies into a level (servers only).
    var importable: ToolServer?
    /// A skill both agents have under one name, but in copies that differ.
    var drift = false
    var id: String { "\(kind.rawValue):\(source.rawValue):\(name)" }
}

enum ToolDiscovery {
    static var home: URL {
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_TOOLS_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Everything both agents load for a chat in `projectFolder` (nil: outside any project).
    static func discover(projectFolder: String?) -> [DiscoveredTool] {
        var found = claudeServers(projectFolder: projectFolder) + codexServers() + claudeSkills(projectFolder: projectFolder) + codexSkills()
        found += connectors()
        // Same server in both agents' configs, or the same skill (one folder, or identical
        // copies): one row for both. A skill whose copies differ is marked.
        var merged: [DiscoveredTool] = []
        for item in found {
            if let i = merged.firstIndex(where: { $0.kind == item.kind && $0.name == item.name && $0.agents != item.agents }) {
                if item.kind == .skill, !sameSkill(merged[i].detail, item.detail) {
                    merged[i].drift = true
                    var copy = item; copy.drift = true
                    merged.append(copy)
                    continue
                }
                merged[i].agents = Array(Set(merged[i].agents + item.agents)).sorted { $0.rawValue < $1.rawValue }
                continue
            }
            merged.append(item)
        }
        return merged
    }

    /// One folder (through links), or the same SKILL.md.
    static func sameSkill(_ a: String, _ b: String) -> Bool {
        let ra = URL(fileURLWithPath: a).resolvingSymlinksInPath().path, rb = URL(fileURLWithPath: b).resolvingSymlinksInPath().path
        if ra == rb { return true }
        return FileManager.default.contentsEqual(atPath: a + "/SKILL.md", andPath: b + "/SKILL.md")
    }

    // MARK: Claude

    static func claudeServers(projectFolder: String?) -> [DiscoveredTool] {
        var result: [DiscoveredTool] = []
        let config = json(home.appendingPathComponent(".claude.json"))
        func add(_ servers: [String: Any]?, source: DiscoveredTool.Source) {
            for (name, value) in (servers ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let spec = value as? [String: Any] else { continue }
                result.append(server(name, spec, source: source, agents: [.claude]))
            }
        }
        add(config["mcpServers"] as? [String: Any], source: .claude)
        if let folder = projectFolder {
            let projects = config["projects"] as? [String: Any] ?? [:]
            add((projects[RuntimePaths.normalize(folder)] as? [String: Any])?["mcpServers"] as? [String: Any], source: .claude)
            add(json(URL(fileURLWithPath: folder).appendingPathComponent(".mcp.json"))["mcpServers"] as? [String: Any], source: .project)
        }
        // Installed plugins' servers: tools named mcp__plugin_<plugin>_<server>__…
        for (plugin, path) in claudePlugins() {
            let servers = json(URL(fileURLWithPath: path).appendingPathComponent(".mcp.json"))
            let specs = (servers["mcpServers"] as? [String: Any]) ?? servers
            for (name, value) in specs.sorted(by: { $0.key < $1.key }) {
                guard let spec = value as? [String: Any] else { continue }
                var item = server("plugin:\(plugin):\(name)", spec, source: .claude, agents: [.claude])
                item.offKey = ToolKey.server("plugin_\(plugin)_\(name)")
                item.importable = nil
                result.append(item)
            }
        }
        return result
    }

    /// Claude Code plugins installed and switched on (settings.json's enabledPlugins): name →
    /// install folder. Ones switched off load nothing, so they aren't listed.
    static func claudePlugins() -> [(String, String)] {
        let installed = json(home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        let plugins = (installed["plugins"] as? [String: Any]) ?? [:]
        let enabled = (json(home.appendingPathComponent(".claude/settings.json"))["enabledPlugins"] as? [String: Bool]) ?? [:]
        var result: [(String, String)] = []
        for (key, value) in plugins.sorted(by: { $0.key < $1.key }) where enabled[key] == true {
            let entries = (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? [])
            let name = String(key.split(separator: "@").first ?? Substring(key))
            guard let path = entries.first?["installPath"] as? String, !result.contains(where: { $0.0 == name }) else { continue }
            result.append((name, path))
        }
        return result
    }

    static func claudeSkills(projectFolder: String?) -> [DiscoveredTool] {
        var roots = [(home.appendingPathComponent(".claude/skills").path, DiscoveredTool.Source.claude, "")]
        if let folder = projectFolder { roots.append((folder + "/.claude/skills", .project, "")) }
        for (plugin, path) in claudePlugins() { roots.append((path + "/skills", .claude, plugin + ":")) }
        return roots.flatMap { root, source, prefix in
            skillFolders(in: root).map { name, path in
                DiscoveredTool(kind: .skill, source: source, name: prefix + name, detail: path, agents: [.claude], offKey: ToolKey.skill(prefix + name))
            }
        }
    }

    // MARK: Codex

    static func codexServers() -> [DiscoveredTool] {
        TOMLSections.read(home.appendingPathComponent(".codex/config.toml"), prefix: "mcp_servers.").map { name, values in
            var spec: [String: Any] = [:]
            if let command = values["command"] as? String { spec["command"] = command }
            if let args = values["args"] as? [String] { spec["args"] = args }
            if let url = values["url"] as? String { spec["url"] = url }
            var item = server(name, spec, source: .codex, agents: [.codex])
            item.enabledThere = (values["enabled"] as? Bool) ?? true
            return item
        }
    }

    /// Names of Codex's own servers: only these can be switched off in a thread's config.
    static func codexServerNames() -> Set<String> { Set(codexServers().map(\.name)) }

    static func codexSkills() -> [DiscoveredTool] {
        let disabled = Set(TOMLSections.skillEntries(home.appendingPathComponent(".codex/config.toml")).filter { !$0.enabled }.map(\.path))
        return [home.appendingPathComponent(".codex/skills").path, home.appendingPathComponent(".agents/skills").path].flatMap { root in
            skillFolders(in: root).map { name, path in
                DiscoveredTool(kind: .skill, source: .codex, name: name, detail: path, agents: [.codex],
                               enabledThere: !disabled.contains(path + "/SKILL.md"), offKey: ToolKey.skill(name))
            }
        }
    }

    // MARK: Connectors

    /// The claude.ai connectors Claude chats have loaded (noted from their start-up message),
    /// and Codex's ChatGPT apps, which a thread can only switch on or off all together.
    static func connectors() -> [DiscoveredTool] {
        let names = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: connectorsFile))) ?? []
        return names.map { DiscoveredTool(kind: .connector, source: .claude, name: $0, detail: "claude.ai connector", agents: [.claude], offKey: ToolKey.connector($0)) }
            + [DiscoveredTool(kind: .connector, source: .codex, name: "ChatGPT apps", detail: "All of Codex's ChatGPT apps (Gmail, Drive, Canva…), on or off together",
                              agents: [.codex], offKey: ToolKey.codexApps)]
    }

    private static var connectorsFile: URL { RuntimePaths.data.appendingPathComponent("ToolConnectors.json") }

    /// From a Claude chat's start: servers named "claude.ai Gmail" are account connectors.
    static func noteClaudeServers(_ names: [String]) {
        let connectors = names.filter { $0.hasPrefix("claude.ai ") }.map { String($0.dropFirst("claude.ai ".count)) }
        guard !connectors.isEmpty else { return }
        let known = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: connectorsFile))) ?? []
        let all = Array(Set(known + connectors)).sorted()
        if all != known.sorted() { try? JSONEncoder().encode(all).write(to: connectorsFile, options: .atomic) }
    }

    // MARK: Helpers

    private static func server(_ name: String, _ spec: [String: Any], source: DiscoveredTool.Source, agents: [Backend]) -> DiscoveredTool {
        let url = (spec["url"] as? String) ?? ""
        let command = (spec["command"] as? String) ?? ""
        let args = (spec["args"] as? [String]) ?? []
        var importable = ToolServer(name: ToolServer.cleanName(name), kind: url.isEmpty ? .command : .url, command: command, args: args, url: url)
        // Plain env values come along; anything that looks like a key is left for Secrets.
        for (key, value) in (spec["env"] as? [String: String]) ?? [:] where !looksSecret(key) { importable.env[key] = value }
        importable.agents = agents
        return DiscoveredTool(kind: .server, source: source, name: name, detail: url.isEmpty ? ([command] + args).joined(separator: " ") : url,
                              agents: agents, offKey: ToolKey.server(name), importable: importable)
    }

    /// Env names an import moves into Secrets instead of copying.
    static func looksSecret(_ key: String) -> Bool {
        key.range(of: "KEY|TOKEN|SECRET|PASSWORD|AUTH", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func skillFolders(in root: String) -> [(String, String)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.sorted().compactMap { name in
            let path = root + "/" + name
            return FileManager.default.fileExists(atPath: path + "/SKILL.md") ? (name, path) : nil
        }
    }

    private static func json(_ url: URL) -> [String: Any] {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

/// Just enough TOML for Codex's config: `[prefix.name]` tables with string, string-array and
/// bool values, and `[[skills.config]]` entries. Anything else is skipped.
enum TOMLSections {
    static func read(_ url: URL, prefix: String) -> [(String, [String: Any])] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [(String, [String: Any])] = []
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                if header.hasPrefix(prefix), !header.dropFirst(prefix.count).contains(".") {
                    let name = String(header.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    current = name
                    result.append((name, [:]))
                } else { current = nil }
                continue
            }
            guard current != nil, let (key, value) = pair(line) else { continue }
            result[result.count - 1].1[key] = value
        }
        return result
    }

    static func skillEntries(_ url: URL) -> [(path: String, enabled: Bool)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [(String, Bool)] = []
        var inSkill = false
        var path: String?, enabled = true
        func flush() { if let path { result.append((path, enabled)) }; path = nil; enabled = true }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { if inSkill { flush() }; inSkill = line == "[[skills.config]]"; continue }
            guard inSkill, let (key, value) = pair(line) else { continue }
            if key == "path" { path = value as? String }
            if key == "enabled" { enabled = (value as? Bool) ?? true }
        }
        if inSkill { flush() }
        return result
    }

    private static func pair(_ line: String) -> (String, Any)? {
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value == "true" || value == "false" { return (key, value == "true") }
        if value.hasPrefix("\"") { return (key, unquote(value)) }
        if value.hasPrefix("[") {
            let inner = value.dropFirst().dropLast()
            return (key, inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
        }
        return nil
    }

    private static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\""), let end = text.dropFirst().firstIndex(of: "\"") else { return text }
        return String(text[text.index(after: text.startIndex)..<end]).replacingOccurrences(of: "\\\\", with: "\\")
    }
}
