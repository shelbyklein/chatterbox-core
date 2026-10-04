import Foundation
import Observation

/// EasyCLIProxyAPI (CLIProxyAPI with a Mac app): a local server that pools your Claude and
/// ChatGPT sign-ins and balances requests across them. Chatterbox can send Claude chats,
/// Codex chats, or both through it (Settings). It reads the proxy's own config for the
/// address and access key, so nothing is copied or stored here, and falls back to the
/// direct connection whenever the proxy isn't answering.
///
/// The assistant (Dot) and the email watch always connect directly: through the proxy,
/// Claude loses its claude.ai connectors and Codex its ChatGPT apps (Gmail among them).
@MainActor
@Observable
final class EasyCLIProxy {
    static let shared = EasyCLIProxy()
    static let claudeKey = "proxyClaudeChats"
    static let codexKey = "proxyCodexChats"

    struct Endpoint: Equatable {
        var host: String
        var port: Int
        var key: String
        var base: String { "http://\(host):\(port)" }
    }

    private(set) var endpoint: Endpoint?
    private(set) var isRunning = false
    private(set) var modelCount = 0
    @ObservationIgnored private var checked = Date.distantPast

    var claudeOn: Bool { AppPreferences.defaults.bool(forKey: Self.claudeKey) }
    var codexOn: Bool { AppPreferences.defaults.bool(forKey: Self.codexKey) }

    /// The proxy to use for this agent right now, if it's turned on and answering.
    func active(for backend: Backend) -> Endpoint? {
        refreshIfStale()
        guard isRunning, let endpoint, backend == .claude ? claudeOn : codexOn else { return nil }
        return endpoint
    }

    /// The app's config, then a standalone install's.
    static var configFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Application Support/com.cpa.gui/cpa-core/config.yaml"),
                home.appendingPathComponent("cliproxyapi/config.yaml")]
    }

    /// host, port, and the first access key, from the proxy's YAML.
    static func readEndpoint() -> Endpoint? {
        for file in configFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var host = "127.0.0.1", port = 8317, key: String?
            var section = "", inServer = false, inKeys = false
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
                let indent = line.prefix { $0 == " " }.count
                func value(_ prefix: String) -> String? {
                    guard trimmed.hasPrefix(prefix) else { return nil }
                    var v = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
                    return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
                if indent == 0 { section = trimmed; inServer = trimmed == "server:"; inKeys = false; continue }
                if inServer, indent == 2 {
                    if let v = value("host:"), !v.isEmpty { host = v == "0.0.0.0" ? "127.0.0.1" : v }
                    if let v = value("port:"), let p = Int(v) { port = p }
                }
                if section == "access:" {
                    if trimmed == "api-keys:" { inKeys = true; continue }
                    if inKeys, trimmed.hasPrefix("- "), key == nil, let v = value("- "), !v.isEmpty { key = v }
                }
            }
            if let key { return Endpoint(host: host, port: port, key: key) }
        }
        return nil
    }

    func refreshIfStale() {
        guard Date().timeIntervalSince(checked) > 15 else { return }
        checked = Date()
        Task { await refresh() }
    }

    /// Reads the config and asks the proxy for its models.
    func refresh() async {
        checked = Date()
        let found = Self.readEndpoint()
        endpoint = found
        guard let found, let url = URL(string: found.base + "/v1/models") else { isRunning = false; modelCount = 0; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.setValue("Bearer " + found.key, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isRunning = false; modelCount = 0; return
        }
        isRunning = true
        modelCount = (object["data"] as? [Any])?.count ?? 0
    }

    /// Codex thread config that routes it through the proxy (the token travels in the
    /// request to Codex, not in any process's environment).
    func codexConfig(_ endpoint: Endpoint) -> [String: JSON] {
        ["model_providers.easycliproxy": ["name": "EasyCLIProxyAPI", "base_url": .string(endpoint.base + "/v1"),
                                          "experimental_bearer_token": .string(endpoint.key), "wire_api": "responses"],
         "model_provider": "easycliproxy"]
    }

    /// Whether Codex is signed in to ChatGPT (not just a key), which the direct connection
    /// needs. Only then are the assistant and the email watch pinned to it.
    static var codexHasChatGPTSignIn: Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: file),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (auth["auth_mode"] as? String)?.lowercased() == "chatgpt" || auth["tokens"] != nil
    }

    /// The provider Codex uses without the proxy: the user's own choice, or OpenAI.
    static var directCodexProvider: String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        for line in ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }   // Only top-level keys.
            if t.hasPrefix("model_provider"), let eq = t.firstIndex(of: "=") {
                return t[t.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return "openai"
    }
}
