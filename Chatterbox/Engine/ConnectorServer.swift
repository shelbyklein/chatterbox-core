import CryptoKit
import Foundation
import Network

/// Chatterbox as an MCP connector for Claude (claude.ai, Claude Duet): a small web server on
/// this Mac's loopback only, published by a Cloudflare tunnel. Claude signs in with OAuth;
/// each sign-in is approved on the Mac, then gets a token paired like a phone (listed with
/// the phones, removed the same way). Its tools go through the phone API, so Claude can do
/// what the iPhone app can and nothing more.
@MainActor
final class ConnectorServer {
    static let shared = ConnectorServer()

    /// The Mac end of the tunnel. CHATTERBOX_CONNECTOR_PORT keeps tests off it.
    nonisolated static let port = UInt16(ProcessInfo.processInfo.environment["CHATTERBOX_CONNECTOR_PORT"] ?? "") ?? 47331
    /// Where Claude reaches it (the tunnel's hostname); "connectorURL" overrides.
    static var publicURL: String {
        let set = AppPreferences.defaults.string(forKey: "connectorURL")?.trimmingCharacters(in: .whitespaces) ?? ""
        let url = set.isEmpty ? (ProcessInfo.processInfo.environment["CHATTERBOX_CONNECTOR_URL"] ?? "https://chatterbox-mcp.shelbyklein.com") : set
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }
    /// Where Claude's sign-in may return to. Tests add their own.
    static var redirectHosts: Set<String> {
        var hosts: Set<String> = ["claude.ai", "claude.com"]
        if let extra = ProcessInfo.processInfo.environment["CHATTERBOX_CONNECTOR_TEST_REDIRECT_HOST"] { hosts.insert(extra) }
        return hosts
    }

    /// A sign-in waiting for the Mac's Allow; shown by the app (`connector.request`).
    var onRequest: ((_ id: UUID, _ client: String) -> Void)?

    private var listener: NWListener?
    private struct Client: Codable { var id: String; var name: String; var redirects: [String] }
    private struct Pending { var client: Client; var redirect: String; var state: String?; var challenge: String; var created = Date(); var decision: Bool? }
    private struct Grant { var client: Client; var redirect: String; var challenge: String; var created = Date() }
    private var clients: [String: Client] = [:]
    /// Files Claude shared as links: who may fetch them is whoever has the link, for a day.
    private struct Share { var session: UUID; var file: UUID; var token: String; var created = Date() }
    private var shares: [String: Share] = [:]
    private var pending: [UUID: Pending] = [:]
    private var codes: [String: Grant] = [:]

    private init() { loadClients() }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.acceptLocalOnly = true
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            RuntimeHooks.note("Connector couldn't start: \(error.localizedDescription)")
        }
    }

    /// The Mac's answer to a sign-in.
    func decide(_ id: UUID, allow: Bool) {
        guard pending[id]?.decision == nil else { return }
        pending[id]?.decision = allow
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > Companion.maxRequestBytes || error != nil { return connection.cancel() }
                switch HTTPRequest.parse(buffer) {
                case .request(let request):
                    let response = await self.respond(to: request)
                    if let file = response.fileURL {
                        HTTPFileTransfer(connection: connection, url: file, contentType: response.contentType).start()
                    } else {
                        connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
                    }
                case .invalid:
                    connection.send(content: HTTPResponse.error(400, "Bad request.").data, completion: .contentProcessed { _ in connection.cancel() })
                case .incomplete where isComplete: connection.cancel()
                case .incomplete: self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        expire()
        let base = Self.publicURL
        switch (request.method, request.path) {
        case ("GET", "/.well-known/oauth-protected-resource"), ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return .object(["resource": .string(base + "/mcp"), "authorization_servers": .array([.string(base)]),
                            "bearer_methods_supported": .array([.string("header")]), "resource_name": .string("Chatterbox")])
        case ("GET", "/.well-known/oauth-authorization-server"):
            return .object(["issuer": .string(base), "authorization_endpoint": .string(base + "/authorize"),
                            "token_endpoint": .string(base + "/token"), "registration_endpoint": .string(base + "/register"),
                            "response_types_supported": .array([.string("code")]), "grant_types_supported": .array([.string("authorization_code")]),
                            "code_challenge_methods_supported": .array([.string("S256")]),
                            "token_endpoint_auth_methods_supported": .array([.string("none")])])
        case ("POST", "/register"): return register(request)
        case ("GET", "/authorize"): return authorize(request)
        case ("GET", "/authorize/status"): return status(request)
        case ("POST", "/token"): return token(request)
        case ("POST", "/mcp"), ("POST", "/"): return await mcp(request)
        case ("GET", let path) where path.hasPrefix("/share/"): return await shared(path)
        case ("GET", "/mcp"), ("DELETE", "/mcp"): return HTTPResponse(status: 405, contentType: "text/plain", body: Data("Method not allowed".utf8))
        default: return .error(404, "Not found")
        }
    }

    // MARK: - OAuth

    /// Dynamic client registration: Claude names itself and where sign-in returns to.
    private func register(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(JSON.self, from: request.body),
              let redirects = body["redirect_uris"]?.array?.compactMap(\.string), !redirects.isEmpty,
              redirects.allSatisfy(allowedRedirect) else { return .oauthError(400, "invalid_redirect_uri") }
        guard clients.count < 50 else { return .oauthError(400, "invalid_client_metadata") }
        let client = Client(id: UUID().uuidString.lowercased(), name: String((body["client_name"]?.string ?? "Claude").prefix(60)), redirects: redirects)
        clients[client.id] = client
        saveClients()
        var response = HTTPResponse.object(["client_id": .string(client.id), "client_name": .string(client.name),
                                            "redirect_uris": .array(redirects.map(JSON.string)), "token_endpoint_auth_method": .string("none"),
                                            "grant_types": .array([.string("authorization_code")]), "response_types": .array([.string("code")])])
        response.status = 201
        return response
    }

    private func allowedRedirect(_ uri: String) -> Bool {
        guard let url = URL(string: uri), let host = url.host?.lowercased() else { return false }
        let local = ProcessInfo.processInfo.environment["CHATTERBOX_CONNECTOR_TEST_REDIRECT_HOST"] == host
        return (url.scheme == "https" || local) && Self.redirectHosts.contains(host)
    }

    /// Starts a sign-in: the Mac is asked to Allow, and this page waits for its answer.
    private func authorize(_ request: HTTPRequest) -> HTTPResponse {
        let q = request.query
        guard let client = q["client_id"].flatMap({ clients[$0] }), let redirect = q["redirect_uri"], client.redirects.contains(redirect) else {
            return .page(status: 400, title: "Can't sign in", message: "This sign-in link isn't from a connector Chatterbox knows. Add the connector again in Claude.")
        }
        guard q["response_type"] == "code", q["code_challenge_method"] == "S256", let challenge = q["code_challenge"], !challenge.isEmpty else {
            return .page(status: 400, title: "Can't sign in", message: "This sign-in request is missing its security check (PKCE).")
        }
        guard pending.values.filter({ $0.decision == nil }).count < 3 else {
            return .page(status: 429, title: "Too many sign-ins", message: "Answer the sign-ins already waiting on your Mac, then try again.")
        }
        let id = UUID()
        pending[id] = Pending(client: client, redirect: redirect, state: q["state"], challenge: challenge)
        onRequest?(id, client.name)
        return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(Self.waitingPage(id).utf8))
    }

    /// The waiting page asks every two seconds; Allow sends it back to Claude with a code.
    private func status(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.query["request"].flatMap(UUID.init(uuidString:)), let entry = pending[id] else {
            return .object(["state": .string("expired")])
        }
        guard let allow = entry.decision else { return .object(["state": .string("waiting")]) }
        pending[id] = nil
        var parts = URLComponents(string: entry.redirect)!
        var items = parts.queryItems ?? []
        if allow {
            let code = Self.random()
            codes[code] = Grant(client: entry.client, redirect: entry.redirect, challenge: entry.challenge)
            items.append(URLQueryItem(name: "code", value: code))
        } else {
            items.append(URLQueryItem(name: "error", value: "access_denied"))
        }
        if let state = entry.state { items.append(URLQueryItem(name: "state", value: state)) }
        parts.queryItems = items
        return .object(["state": .string(allow ? "approved" : "denied"), "redirect": .string(parts.url?.absoluteString ?? entry.redirect)])
    }

    /// A code (once, within two minutes, with its PKCE verifier) for a token.
    private func token(_ request: HTTPRequest) -> HTTPResponse {
        let form = Self.form(request.body)
        guard form["grant_type"] == "authorization_code" else { return .oauthError(400, "unsupported_grant_type") }
        guard let code = form["code"], let grant = codes.removeValue(forKey: code),
              form["redirect_uri"] == grant.redirect, form["client_id"].map({ $0 == grant.client.id }) ?? true,
              let verifier = form["code_verifier"], Self.challenge(verifier) == grant.challenge else {
            return .oauthError(400, "invalid_grant")
        }
        let token = CompanionServer.shared.issueToken(name: grant.client.name)
        return .object(["access_token": .string(token), "token_type": .string("Bearer")])
    }

    /// A link to a session's file, good for 24 hours (or until the service restarts).
    func share(session: UUID, file: UUID, name: String, token: String) -> String {
        let key = Self.random()
        shares[key] = Share(session: session, file: file, token: token)
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "file"
        return "\(Self.publicURL)/share/\(key)/\(safe)"
    }

    private func shared(_ path: String) async -> HTTPResponse {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let share = shares[parts[1]] else {
            return .page(status: 404, title: "Link expired", message: "This file link has expired or doesn't exist. Ask Claude to share the file again.")
        }
        // Fetched as the connector that shared it: a removed connector's links stop working.
        let request = HTTPRequest(method: "GET", path: "/v1/chats/\(share.session.uuidString)/files/\(share.file.uuidString)", query: [:],
                                  headers: [Companion.tokenHeader.lowercased(): share.token], body: Data())
        let response = await CompanionServer.shared.respondAsync(to: request)
        guard response.status == 200 else { return .page(status: 404, title: "File gone", message: "That file isn't in the session any more.") }
        return response
    }

    private func expire() {
        let now = Date()
        shares = shares.filter { now.timeIntervalSince($0.value.created) < 86_400 }
        pending = pending.filter { now.timeIntervalSince($0.value.created) < 300 }
        codes = codes.filter { now.timeIntervalSince($0.value.created) < 120 }
    }

    // MARK: - MCP

    private func mcp(_ request: HTTPRequest) async -> HTTPResponse {
        let bearer = request.headers["authorization"].flatMap { $0.lowercased().hasPrefix("bearer ") ? String($0.dropFirst(7)) : nil } ?? ""
        guard CompanionServer.shared.device(forToken: bearer) != nil else {
            var response = HTTPResponse.error(401, "Sign in to Chatterbox.")
            response.headers["WWW-Authenticate"] = "Bearer resource_metadata=\"\(Self.publicURL)/.well-known/oauth-protected-resource\""
            return response
        }
        guard let message = try? JSONDecoder().decode(JSON.self, from: request.body), let method = message["method"]?.string else {
            return .rpc(id: .null, error: (-32700, "Parse error"))
        }
        let id = message["id"] ?? .null
        // Notifications get no answer.
        if message["id"] == nil { return HTTPResponse(status: 202, contentType: "application/json", body: Data()) }
        switch method {
        case "initialize":
            let version = message["params"]?["protocolVersion"]?.string ?? "2025-06-18"
            return .rpc(id: id, result: ["protocolVersion": .string(version), "capabilities": ["tools": [:]],
                                         "serverInfo": ["name": "chatterbox", "version": "1.0"],
                                         "instructions": .string(ConnectorTools.instructions)])
        case "ping": return .rpc(id: id, result: [:])
        case "tools/list": return .rpc(id: id, result: ["tools": .array(ConnectorTools.list)])
        case "tools/call":
            let name = message["params"]?["name"]?.string ?? ""
            let arguments = message["params"]?["arguments"] ?? [:]
            let (content, failed) = await ConnectorTools.content(name, arguments: arguments, token: bearer)
            return .rpc(id: id, result: ["content": .array(content), "isError": .bool(failed)])
        default: return .rpc(id: id, error: (-32601, "Method not found"))
        }
    }

    // MARK: - Storage and helpers

    private var clientsFile: URL { RuntimePaths.data.appendingPathComponent("connector-clients.json") }
    private func loadClients() {
        guard let data = try? Data(contentsOf: clientsFile), let list = try? JSONDecoder().decode([Client].self, from: data) else { return }
        clients = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }
    private func saveClients() {
        try? JSONEncoder().encode(Array(clients.values)).write(to: clientsFile, options: [.atomic])
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func form(_ body: Data) -> [String: String] {
        var parts = URLComponents()
        parts.percentEncodedQuery = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        return Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    private static func waitingPage(_ id: UUID) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Chatterbox</title><style>body{font:16px -apple-system,system-ui,sans-serif;background:#111;color:#eee;display:grid;place-items:center;min-height:90vh;margin:0}
        main{max-width:26em;padding:2em;text-align:center}h1{font-size:1.3em}p{color:#aaa;line-height:1.5}</style></head>
        <body><main><h1 id="t">Allow on your Mac</h1><p id="m">Chatterbox is asking on your Mac whether Claude may use it. Choose Allow there; this page continues by itself.</p></main>
        <script>
        async function check(){try{const r=await fetch('/authorize/status?request=\(id.uuidString)');const s=await r.json();
        if(s.redirect){location.replace(s.redirect);return}
        if(s.state==='expired'){document.getElementById('t').textContent='Sign-in expired';document.getElementById('m').textContent='Add the connector again in Claude.';return}}catch(e){}
        setTimeout(check,2000)}check()
        </script></body></html>
        """
    }
}

private extension HTTPResponse {
    static func object(_ value: [String: JSON]) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: (try? JSONEncoder().encode(JSON.object(value))) ?? Data())
    }
    static func oauthError(_ status: Int, _ code: String) -> HTTPResponse {
        var response = object(["error": .string(code)])
        response.status = status
        return response
    }
    static func rpc(id: JSON, result: JSON) -> HTTPResponse {
        object(["jsonrpc": "2.0", "id": id, "result": result])
    }
    static func rpc(id: JSON, error: (Int, String)) -> HTTPResponse {
        object(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.0)), "message": .string(error.1)]])
    }
    static func page(status: Int, title: String, message: String) -> HTTPResponse {
        let html = "<!doctype html><meta charset=utf-8><title>Chatterbox</title><body style=\"font:16px -apple-system,sans-serif;background:#111;color:#eee;padding:3em\"><h1>\(title)</h1><p>\(message)</p>"
        return HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }
}
