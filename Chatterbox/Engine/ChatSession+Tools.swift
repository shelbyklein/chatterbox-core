import CryptoKit
import Foundation

/// A chat's tools (ToolScopes) as each agent takes them. Claude Code: a generated
/// `--mcp-config` file, `--disallowedTools=` for what's off, and a generated plugin folder for
/// added skills (`--plugin-dir`). Codex: entries in the thread's config. A chat with nothing
/// set gets none of these, so it launches as before.
extension ChatSession {
    /// Where generated per-chat files go; readable only by this user.
    static var toolFilesFolder: URL { RuntimePaths.data.appendingPathComponent("ToolConfigs", isDirectory: true) }

    // MARK: Claude

    /// The servers this chat adds, as an `--mcp-config` file (values from Secrets stay out of
    /// the command line). nil when there are none.
    func claudeToolsMCPConfigFile(_ tools: EffectiveTools) -> String? {
        let servers = tools.servers(for: .claude)
        guard !servers.isEmpty else { return nil }
        var specs: [String: JSON] = [:]
        for server in servers {
            switch server.kind {
            case .command:
                var spec: [String: JSON] = ["command": .string(server.command), "args": .array(server.args.map { .string($0) })]
                let env = Self.serverEnvironment(server)
                if !env.isEmpty { spec["env"] = .object(env.mapValues { .string($0) }) }
                specs[server.name] = .object(spec)
            case .url:
                var spec: [String: JSON] = ["type": .string("http"), "url": .string(server.url)]
                if let token = server.bearerSecret.flatMap({ SecretVault.shared.value(forVariable: $0) }) {
                    spec["headers"] = ["Authorization": .string("Bearer " + token)]
                }
                specs[server.name] = .object(spec)
            }
        }
        let file = Self.toolFilesFolder.appendingPathComponent("claude-\(id.uuidString).json")
        do {
            try FileManager.default.createDirectory(at: Self.toolFilesFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(JSON.object(["mcpServers": .object(specs)]))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            RuntimeHooks.note("Couldn't write the tools for \u{201C}\(title)\u{201D}: \(error.localizedDescription)")
            return nil
        }
    }

    /// What's turned off, as Claude Code tool rules: a server's or connector's tools, a skill.
    static func claudeDisallowedTools(_ tools: EffectiveTools) -> [String] {
        tools.off.sorted().compactMap { key in
            if key.hasPrefix("server:") { return "mcp__" + claudeToolName(String(key.dropFirst("server:".count))) }
            if key.hasPrefix("connector:") { return "mcp__claude_ai_" + claudeToolName(String(key.dropFirst("connector:".count))) }
            if key.hasPrefix("skill:") { return "Skill(\(key.dropFirst("skill:".count)))" }
            return nil
        }
    }

    /// Claude Code's tool-name form of a server name: anything but letters, digits, - and _ is _.
    static func claudeToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
    }

    /// Added skill folders, as a plugin Claude Code loads: its skills/ links to each skill.
    func claudeToolsPluginDir(_ tools: EffectiveTools) -> String? {
        let skills = Self.skillPaths(tools.skillFolders(for: .claude))
        guard !skills.isEmpty else { return nil }
        let key = SHA256.hash(data: Data(skills.map(\.1).joined(separator: "\n").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let root = Self.toolFilesFolder.appendingPathComponent("skills-\(key)", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.appendingPathComponent(".claude-plugin/plugin.json").path) {
            do {
                try fm.createDirectory(at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
                try fm.createDirectory(at: root.appendingPathComponent("skills"), withIntermediateDirectories: true)
                let manifest = #"{"name":"chatterbox-tools","version":"1.0.0","description":"Skills added in Chatterbox's Tools settings"}"#
                try Data(manifest.utf8).write(to: root.appendingPathComponent(".claude-plugin/plugin.json"))
                for (name, path) in skills {
                    try? fm.createSymbolicLink(atPath: root.appendingPathComponent("skills/\(name)").path, withDestinationPath: path)
                }
            } catch { return nil }
        }
        return root.path
    }

    /// Each skill in the added folders: a folder holding SKILL.md, or a folder of them.
    static func skillPaths(_ folders: [String]) -> [(String, String)] {
        let fm = FileManager.default
        var result: [(String, String)] = []
        for folder in folders {
            if fm.fileExists(atPath: folder + "/SKILL.md") {
                result.append((URL(fileURLWithPath: folder).lastPathComponent, folder))
            } else if let names = try? fm.contentsOfDirectory(atPath: folder) {
                for name in names.sorted() where fm.fileExists(atPath: "\(folder)/\(name)/SKILL.md") { result.append((name, "\(folder)/\(name)")) }
            }
        }
        return result
    }

    /// A command server's environment: its plain values, then its keys from Secrets.
    static func serverEnvironment(_ server: ToolServer) -> [String: String] {
        var env = server.env
        for (name, variable) in server.secretEnv {
            if let value = SecretVault.shared.value(forVariable: variable) { env[name] = value }
        }
        return env
    }

    // MARK: Codex

    /// Thread config entries: the servers this chat adds, and what it turns off.
    func codexToolsConfig(_ tools: EffectiveTools, codexServers: Set<String>) -> [String: JSON] {
        var config: [String: JSON] = [:]
        for server in tools.servers(for: .codex) {
            switch server.kind {
            case .command:
                var spec: [String: JSON] = ["command": .string(server.command), "args": .array(server.args.map { .string($0) }), "enabled": true]
                if let cwd = server.cwd { spec["cwd"] = .string(cwd) }
                let env = Self.serverEnvironment(server)
                if !env.isEmpty { spec["env"] = .object(env.mapValues { .string($0) }) }
                config["mcp_servers.\(server.name)"] = .object(spec)
            case .url:
                var spec: [String: JSON] = ["url": .string(server.url), "enabled": true]
                if let token = server.bearerSecret.flatMap({ SecretVault.shared.value(forVariable: $0) }) {
                    spec["http_headers"] = ["Authorization": .string("Bearer " + token)]
                }
                config["mcp_servers.\(server.name)"] = .object(spec)
            }
        }
        var skills: [JSON] = []
        for key in tools.off.sorted() {
            if key.hasPrefix("server:") {
                let name = String(key.dropFirst("server:".count))
                // Only Codex's own servers: naming one it doesn't have would make a broken entry.
                if codexServers.contains(name) { config["mcp_servers.\(name).enabled"] = false }
            } else if key.hasPrefix("skill:") {
                skills.append(["name": .string(String(key.dropFirst("skill:".count))), "enabled": false])
            } else if key == ToolKey.codexApps {
                config["features.apps"] = false
            }
        }
        for (_, path) in Self.skillPaths(tools.skillFolders(for: .codex)) { skills.append(["path": .string(path + "/SKILL.md"), "enabled": true]) }
        if !skills.isEmpty { config["skills.config"] = .array(skills) }
        return config
    }
}

extension ChatSession {
    /// After a switch: MCP servers the leaving agent used here that the incoming agent has
    /// neither in its own config nor from Chatterbox's Tools for this session, said once as a
    /// notice. Chatterbox's own server and claude.ai connectors (Claude only) are left out.
    @MainActor func noteMissingServers(used items: ArraySlice<DisplayItem>, by leaving: Backend, now incoming: Backend) {
        var used: [String] = []
        for item in items where item.kind == .tool {
            guard let tool = item.tool, tool.hasPrefix("mcp:"),
                  let server = tool.dropFirst(4).split(separator: "/").first.map(String.init),
                  server != "chatterbox", !server.hasPrefix("claude_ai_"), !used.contains(server) else { continue }
            used.append(server)
        }
        guard !used.isEmpty else { return }
        let missing = used.filter { !Self.agentHasServer($0, incoming, session: self) }
        guard !missing.isEmpty else { return }
        let names = missing.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        appendItem(DisplayItem(kind: .notice, text: "\(incoming.label) doesn't have the \(names) MCP server\(missing.count == 1 ? "" : "s") \(leaving.label) was using here. Add \(missing.count == 1 ? "it" : "them") in Settings \u{2192} Tools, or import \(missing.count == 1 ? "it" : "them") from \(leaving.label)'s config."))
    }

    /// Whether `backend` gets an MCP server by this name: its own config, or this session's Tools.
    @MainActor static func agentHasServer(_ name: String, _ backend: Backend, session: ChatSession) -> Bool {
        func same(_ a: String, _ b: String) -> Bool { claudeToolName(a).lowercased() == claudeToolName(b).lowercased() }
        let own: [String] = backend == .codex ? ToolDiscovery.codexServers().map(\.name)
            : ToolDiscovery.claudeServers(projectFolder: session.record.boundFolder).map(\.name)
        let added = ToolScopes.effective(for: session).servers(for: backend).map(\.name)
        return (own + added).contains { same($0, name) }
    }
}

