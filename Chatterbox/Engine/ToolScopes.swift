import CryptoKit
import Foundation

/// What agents can use, set at three levels: Chatterbox-wide, Studios (one set for every
/// Studio chat) and each project. A chat gets Chatterbox-wide plus its Studio's or project's
/// set; a Studio or project can turn off what it inherits, including what the agents load
/// from their own config (see ToolDiscovery). Stored in ToolScopes.json; the app writes it,
/// the app and the background service read it when an agent starts.
struct ToolServer: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case command, url }
    var id = UUID()
    /// The MCP server's name, as the agents see it ("linear").
    var name: String
    var kind: Kind
    var command = ""
    var args: [String] = []
    /// The folder a command server runs in (Codex only); nil: the chat's own.
    var cwd: String?
    var url = ""
    /// Plain environment values.
    var env: [String: String] = [:]
    /// Environment variables filled from Secrets, by the secret's variable: "API_KEY" → "LINEAR_KEY".
    var secretEnv: [String: String] = [:]
    /// For a URL server: a secret sent as its bearer token.
    var bearerSecret: String?
    /// Which agents get it.
    var agents: [Backend] = Backend.allCases
    var enabled = true

    /// Letters, digits, - and _: what both agents accept as a server name.
    static func cleanName(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// One level's set.
struct ToolSet: Codable, Equatable {
    /// Servers this level adds (connectors by URL are servers too).
    var servers: [ToolServer] = []
    /// What this level turns off, from levels above or the agents' own config: keys from
    /// `ToolKey` ("server:inspo", "connector:Gmail", "skill:impeccable", "apps:codex").
    var off: [String] = []
    /// Skill folders this level adds (each holds <name>/SKILL.md).
    var skillFolders: [String] = []
    /// A folder only some agents get ("Share with Codex" on a Claude-only skill); missing: both.
    var skillFolderAgents: [String: [Backend]] = [:]

    var isEmpty: Bool { servers.isEmpty && off.isEmpty && skillFolders.isEmpty }

    init(servers: [ToolServer] = [], off: [String] = [], skillFolders: [String] = [], skillFolderAgents: [String: [Backend]] = [:]) {
        self.servers = servers; self.off = off; self.skillFolders = skillFolders; self.skillFolderAgents = skillFolderAgents
    }
    // Older files have no skillFolderAgents.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([ToolServer].self, forKey: .servers) ?? []
        off = try c.decodeIfPresent([String].self, forKey: .off) ?? []
        skillFolders = try c.decodeIfPresent([String].self, forKey: .skillFolders) ?? []
        skillFolderAgents = try c.decodeIfPresent([String: [Backend]].self, forKey: .skillFolderAgents) ?? [:]
    }
}

/// The keys `ToolSet.off` uses.
enum ToolKey {
    static func server(_ name: String) -> String { "server:" + name }
    static func connector(_ name: String) -> String { "connector:" + name }
    static func skill(_ name: String) -> String { "skill:" + name }
    static let codexApps = "apps:codex"
}

enum ToolScope: Hashable, Identifiable {
    case chatterbox, studios, project(String)
    var key: String {
        switch self {
        case .chatterbox: "chatterbox"
        case .studios: "studios"
        case .project(let folder): "project:" + RuntimePaths.normalize(folder)
        }
    }
    var id: String { key }
}

/// What one chat gets, all levels applied.
struct EffectiveTools: Equatable {
    var servers: [ToolServer] = []
    var off: Set<String> = []
    var skillFolders: [String] = []
    var skillFolderAgents: [String: [Backend]] = [:]

    var isEmpty: Bool { servers.isEmpty && off.isEmpty && skillFolders.isEmpty }
    func skillFolders(for backend: Backend) -> [String] { skillFolders.filter { skillFolderAgents[$0]?.contains(backend) ?? true } }
    func servers(for backend: Backend) -> [ToolServer] { servers.filter { $0.agents.contains(backend) } }
    func isOff(_ key: String) -> Bool { off.contains(key) }
}

enum ToolScopes {
    static var file: URL { RuntimePaths.data.appendingPathComponent("ToolScopes.json") }

    static func load() -> [String: ToolSet] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: ToolSet].self, from: data)) ?? [:]
    }

    static func save(_ sets: [String: ToolSet]) throws {
        let kept = sets.filter { !$0.value.isEmpty }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(kept).write(to: file, options: .atomic)
    }

    /// The levels a chat draws from, Chatterbox-wide first. Golem keeps its own tools.
    @MainActor static func scopes(for session: ChatSession) -> [ToolScope] {
        guard !session.isDot else { return [] }
        if session.record.studioID != nil { return [.chatterbox, .studios] }
        if let folder = projectFolder(of: session) { return [.chatterbox, .project(folder)] }
        return [.chatterbox]
    }

    /// The project a chat belongs to: its own, or its worktree's, Sidechat's or sidequest's.
    @MainActor static func projectFolder(of session: ChatSession) -> String? {
        (session.record.sidechatProjectFolder ?? session.convertedProjectScope ?? session.record.worktreeOf ?? session.record.projectFolder)
    }

    /// Every level's servers that are on, minus what any of the chat's levels turned off.
    static func effective(_ scopes: [ToolScope], sets: [String: ToolSet]) -> EffectiveTools {
        var result = EffectiveTools()
        for scope in scopes {
            guard let set = sets[scope.key] else { continue }
            result.off.formUnion(set.off)
            for server in set.servers where server.enabled {
                result.servers.removeAll { $0.name == server.name }
                result.servers.append(server)
            }
            result.skillFolders += set.skillFolders.filter { !result.skillFolders.contains($0) }
            result.skillFolderAgents.merge(set.skillFolderAgents) { $1 }
        }
        result.servers.removeAll { result.off.contains(ToolKey.server($0.name)) }
        return result
    }

    @MainActor static func effective(for session: ChatSession) -> EffectiveTools {
        effective(scopes(for: session), sets: load())
    }

    /// Changes whenever what a chat would get changes, so its agent restarts or reloads.
    @MainActor static func fingerprint(for session: ChatSession) -> String {
        let tools = effective(for: session)
        guard !tools.isEmpty else { return "" }
        let data = (try? JSONEncoder().encode(Fingerprinted(tools))) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fingerprinted: Encodable {
        var servers: [ToolServer]
        var off: [String]
        var skillFolders: [String]
        var skillFolderAgents: [String: [Backend]]
        init(_ t: EffectiveTools) { servers = t.servers; off = t.off.sorted(); skillFolders = t.skillFolders; skillFolderAgents = t.skillFolderAgents }
    }
}
