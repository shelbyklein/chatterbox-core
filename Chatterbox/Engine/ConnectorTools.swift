import Foundation

/// The connector's tools. Each one is a phone API request made with the connector's own
/// token, so Claude gets what the iPhone app gets: the same checks, the same answers.
@MainActor
enum ConnectorTools {
    static let instructions = """
    Chatterbox runs Claude Code and Codex sessions on Shelby's Mac. Use list_sessions to see them \
    (what's working, what's waiting on Shelby), read_session for a session's latest messages, \
    send_message to reply in one, start_session for a new one, answer to approve, deny or answer \
    questions a session is waiting on, and stop_reply to stop one. read_session lists each \
    message's files: show_image shows a picture, share_file makes a download link (24 hours) \
    for any file. session_settings shows or changes a session's agent, model, effort and Fast \
    mode. Sessions act on the Mac: before sending work, starting a session, approving anything \
    or changing a model, confirm with Shelby.
    """

    static let list: [JSON] = [
        tool("list_sessions", "The Mac's sessions, newest first: id, title, project or Studio, and whether each is working or waiting on Shelby.",
             ["filter": prop("string", "all (default), working, or waiting", ["all", "working", "waiting"])], required: []),
        tool("read_session", "A session's latest messages, and any approval or questions it's waiting on (with their ids, for answer).",
             ["session_id": prop("string", "From list_sessions"), "last": prop("integer", "How many recent messages (default 12, at most 50)")],
             required: ["session_id"]),
        tool("send_message", "Sends a message in a session, as Shelby typing it. While it's working, the message waits for the reply to finish.",
             ["session_id": prop("string", "From list_sessions"), "text": prop("string", "The message")], required: ["session_id", "text"]),
        tool("start_session", "Starts a new session and sends its first message. Optionally in a Studio, by name, or on Codex.",
             ["text": prop("string", "The first message"), "studio": prop("string", "A Studio's name (optional)"),
              "agent": prop("string", "claude (default) or codex", ["claude", "codex"]), "title": prop("string", "A name (optional)")],
             required: ["text"]),
        tool("answer", "Answers what a session is waiting on: an approval (approve, approve_for_session or deny) or its questions (question id to chosen labels).",
             ["session_id": prop("string", "From list_sessions"), "item_id": prop("string", "The approval's or questions' id, from read_session"),
              "decision": prop("string", "For an approval", ["approve", "approve_for_session", "deny"]),
              "answers": ["type": "object", "description": "For questions: question id → array of chosen option labels (or typed text)",
                          "additionalProperties": ["type": "array", "items": ["type": "string"]]]],
             required: ["session_id", "item_id"]),
        tool("stop_reply", "Stops the reply a session is working on.", ["session_id": prop("string", "From list_sessions")], required: ["session_id"]),
        tool("show_image", "Shows a picture from a session (a render, a screenshot), to look at or show Shelby.",
             ["session_id": prop("string", "From list_sessions"), "file_id": prop("string", "An image's id, from read_session"),
              "size": prop("integer", "Longest side in pixels (default 1600, 400 to 2400)")], required: ["session_id", "file_id"]),
        tool("share_file", "A download link for a file from a session (an image, PDF, document, zip), for Shelby. Anyone with the link can download it for 24 hours.",
             ["session_id": prop("string", "From list_sessions"), "file_id": prop("string", "A file's id, from read_session")], required: ["session_id", "file_id"]),
        tool("session_settings", "Shows a session's agent, model, effort and Fast mode and the choices; given any of them, changes them. Changes apply from the next message.",
             ["session_id": prop("string", "From list_sessions"), "agent": prop("string", "claude or codex", ["claude", "codex"]),
              "model": prop("string", "A model's name or id from the choices"), "effort": prop("string", "An effort level from the choices"),
              "fast_mode": prop("boolean", "Fast mode on or off, where the model has it")], required: ["session_id"]),
    ]

    /// The tool's answer as MCP content (text, or an image), and whether it failed.
    static func content(_ name: String, arguments: JSON, token: String) async -> ([JSON], Bool) {
        if name == "show_image" { return await image(arguments, token: token) }
        let (text, failed) = await call(name, arguments: arguments, token: token)
        return ([["type": "text", "text": .string(text)]], failed)
    }

    static func call(_ name: String, arguments: JSON, token: String) async -> (String, Bool) {
        func text(_ key: String) -> String { arguments[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let session = text("session_id")
        switch name {
        case "list_sessions":
            guard case .ok(let list) = await request("GET", "/v1/chats", token: token, as: Companion.ChatList.self) else { return failure }
            return (sessions(list, filter: text("filter")), false)
        case "read_session":
            guard UUID(uuidString: session) != nil else { return ("Give a session_id from list_sessions.", true) }
            switch await request("GET", "/v1/chats/\(session)", token: token, as: Companion.ChatDetail.self) {
            case .ok(let detail): return (transcript(detail, last: min(max(arguments["last"]?.int ?? 12, 1), 50)), false)
            case .failed(let message): return (message, true)
            }
        case "send_message":
            guard UUID(uuidString: session) != nil, !text("text").isEmpty else { return ("Give a session_id and the text.", true) }
            return await detailResult(request("POST", "/v1/chats/\(session)/messages", body: Companion.SendRequest(text: text("text")), token: token), "Sent.")
        case "start_session":
            guard !text("text").isEmpty else { return ("Give the first message.", true) }
            var studio: UUID?
            if !text("studio").isEmpty {
                guard case .ok(let list) = await request("GET", "/v1/chats", token: token, as: Companion.ChatList.self) else { return failure }
                let studios = list.groups.filter { $0.kind == .studio }
                guard let match = studios.first(where: { $0.title.localizedCaseInsensitiveCompare(text("studio")) == .orderedSame }) else {
                    return ("No Studio named \(text("studio")). Studios: \(studios.map(\.title).joined(separator: ", ")).", true)
                }
                studio = match.studioID ?? UUID(uuidString: String(match.id.dropFirst("studio-".count)))
            }
            let new = Companion.NewChatRequest(studio: studio, backend: text("agent").isEmpty ? nil : text("agent"),
                                               title: text("title").isEmpty ? nil : text("title"))
            guard case .ok(let detail) = await request("POST", "/v1/chats", body: new, token: token, as: Companion.ChatDetail.self) else { return failure }
            let sent = await request("POST", "/v1/chats/\(detail.summary.id.uuidString)/messages", body: Companion.SendRequest(text: text("text")), token: token)
            return await detailResult(sent, "Started session \(detail.summary.id.uuidString).")
        case "answer":
            guard UUID(uuidString: session) != nil, UUID(uuidString: text("item_id")) != nil else { return ("Give the session_id and item_id from read_session.", true) }
            if let decision = arguments["decision"]?.string {
                let value = ["approve": "approved", "approve_for_session": "approvedForSession", "deny": "denied"][decision] ?? decision
                return await detailResult(request("POST", "/v1/chats/\(session)/approvals/\(text("item_id"))", body: Companion.DecisionRequest(decision: value), token: token), "Answered.")
            }
            let answers = (arguments["answers"]?.object ?? [:]).mapValues { value in value.array?.compactMap(\.string) ?? value.string.map { [$0] } ?? [] }
            guard !answers.isEmpty else { return ("Give a decision (for an approval) or answers (for questions).", true) }
            return await detailResult(request("POST", "/v1/chats/\(session)/answers/\(text("item_id"))", body: Companion.AnswersRequest(answers: answers), token: token), "Answered.")
        case "stop_reply":
            guard UUID(uuidString: session) != nil else { return ("Give a session_id from list_sessions.", true) }
            return await detailResult(request("POST", "/v1/chats/\(session)/stop", body: [String: String](), token: token), "Stopped.")
        case "share_file":
            guard let id = UUID(uuidString: session), let file = UUID(uuidString: text("file_id")) else { return ("Give the session_id and file_id from read_session.", true) }
            guard case .ok(let detail) = await request("GET", "/v1/chats/\(session)", token: token, as: Companion.ChatDetail.self) else { return ("That session is gone.", true) }
            guard let found = detail.items.flatMap(\.attachments).first(where: { $0.id == file }) else { return ("No file with that id in the session's recent messages.", true) }
            return ("\(found.name): \(ConnectorServer.shared.share(session: id, file: file, name: found.name, token: token))\nAnyone with the link can download it for 24 hours.", false)
        case "session_settings":
            guard UUID(uuidString: session) != nil else { return ("Give a session_id from list_sessions.", true) }
            return await settings(session, arguments: arguments, token: token)
        default:
            return ("No tool named \(name).", true)
        }
    }

    // MARK: - Images and settings

    private static func image(_ arguments: JSON, token: String) async -> ([JSON], Bool) {
        let session = arguments["session_id"]?.string ?? "", file = arguments["file_id"]?.string ?? ""
        func failed(_ text: String) -> ([JSON], Bool) { ([["type": "text", "text": .string(text)]], true) }
        guard UUID(uuidString: session) != nil, UUID(uuidString: file) != nil else { return failed("Give the session_id and file_id from read_session.") }
        let size = min(max(arguments["size"]?.int ?? 1600, 400), 2400)
        var parts = URLComponents(); parts.path = "/v1/chats/\(session)/files/\(file)"
        let request = HTTPRequest(method: "GET", path: parts.path, query: ["max": String(size)],
                                  headers: [Companion.tokenHeader.lowercased(): token], body: Data())
        let response = await CompanionServer.shared.respondAsync(to: request)
        guard response.status == 200 else { return failed(message(response)) }
        // Small enough already: the original comes as a file instead of resized bytes.
        let data = response.fileURL.flatMap { try? Data(contentsOf: $0) } ?? response.body
        guard response.contentType.hasPrefix("image/"), !data.isEmpty else { return failed("That file isn't a picture; use share_file for a link to it.") }
        guard data.count <= 5_000_000 else { return failed("That picture is too large to show; try a smaller size, or share_file for a link.") }
        return ([["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(response.contentType)]], false)
    }

    /// Shows the settings and choices; with changes, applies them the way the phone does.
    private static func settings(_ session: String, arguments: JSON, token: String) async -> (String, Bool) {
        guard case .ok(var detail) = await request("GET", "/v1/chats/\(session)", token: token, as: Companion.ChatDetail.self),
              var options = detail.options else { return ("That session is gone.", true) }
        let agent = arguments["agent"]?.string?.lowercased(), modelName = arguments["model"]?.string, effort = arguments["effort"]?.string?.lowercased()
        let fast = arguments["fast_mode"]?.bool
        if agent != nil || modelName != nil || effort != nil || fast != nil {
            let target = agent ?? options.backend
            var change = Companion.SettingsRequest()
            if target != options.backend { change.backend = target }
            if let modelName {
                let models = target == "codex" ? options.codexModels : options.claudeModels
                guard let model = models.first(where: { $0.id.caseInsensitiveCompare(modelName) == .orderedSame || $0.name.caseInsensitiveCompare(modelName) == .orderedSame })
                        ?? models.first(where: { $0.name.localizedCaseInsensitiveContains(modelName) }) else {
                    return ("No \(target) model called \(modelName). Choices: \(models.map(\.name).joined(separator: ", ")).", true)
                }
                change.model = model.id
            } else if change.backend != nil {
                change.model = (target == "codex" ? options.codexModels : options.claudeModels).first?.id
            }
            let applied = await request("POST", "/v1/chats/\(session)/settings", body: change, token: token, as: Companion.ChatDetail.self)
            guard case .ok(let updated) = applied else { if case .failed(let text) = applied { return (text, true) }; return failure }
            detail = updated; options = updated.options ?? options
            var follow = Companion.SettingsRequest()
            if let effort {
                let levels = (options.backend == "codex" ? options.codexModels : options.claudeModels).first { $0.id == options.model }?.efforts ?? []
                guard levels.isEmpty || levels.contains(effort) else { return ("Model changed, but \(effort) isn't one of its efforts: \(levels.joined(separator: ", ")).", true) }
                follow.effort = effort
            }
            if let fast { follow.fastMode = fast }
            if follow.effort != nil || follow.fastMode != nil {
                let second = await request("POST", "/v1/chats/\(session)/settings", body: follow, token: token, as: Companion.ChatDetail.self)
                guard case .ok(let again) = second else { if case .failed(let text) = second { return (text, true) }; return failure }
                detail = again; options = again.options ?? options
            }
            return ("Changed. Now: \(detail.settings)", false)
        }
        let models = options.backend == "codex" ? options.codexModels : options.claudeModels
        let current = models.first { $0.id == options.model }
        var lines = ["Now: \(detail.settings)", "Agent: \(options.backend)"]
        lines.append("Claude models: \(options.claudeModels.map(\.name).joined(separator: ", "))")
        lines.append("Codex models: \(options.codexModels.map(\.name).joined(separator: ", "))")
        if let efforts = current?.efforts, !efforts.isEmpty { lines.append("Efforts for \(current?.name ?? "this model"): \(efforts.joined(separator: ", "))") }
        if let fast = options.fastMode { lines.append("Fast mode: \(fast ? "on" : "off")") }
        return (lines.joined(separator: "\n"), false)
    }

    // MARK: - Shaping answers

    private static func sessions(_ list: Companion.ChatList, filter: String) -> String {
        var rows: [String] = []
        for group in list.groups {
            for chat in group.chats {
                if filter == "working", !chat.isRunning { continue }
                if filter == "waiting", !chat.isWaitingOnYou { continue }
                let place = group.kind == .studio ? "Studio \(group.title)" : chat.project.map { "Project \($0)" } ?? group.title
                let state = chat.isWaitingOnYou ? "waiting on Shelby" : chat.isRunning ? "working" : "idle"
                let latest = chat.subtitle.map { " — \($0.prefix(140))" } ?? ""
                rows.append("- \(chat.title) [\(chat.id.uuidString)] · \(place) · \(chat.backend) · \(state)\(latest)")
            }
        }
        return rows.isEmpty ? "No sessions\(filter.isEmpty || filter == "all" ? "" : " \(filter)")." : rows.joined(separator: "\n")
    }

    private static func transcript(_ detail: Companion.ChatDetail, last: Int) -> String {
        let summary = detail.summary
        var lines = ["\(summary.title) [\(summary.id.uuidString)] · \(detail.settings) · \(summary.isRunning ? "working" : summary.isWaitingOnYou ? "waiting on Shelby" : "idle")", ""]
        let shown = detail.items.filter { ([.user, .assistant, .approval, .questions, .notice].contains($0.kind) && !$0.isCommentary) || !$0.attachments.isEmpty }
        for item in shown.suffix(last) {
            switch item.kind {
            case .user: lines.append("Shelby: \(item.text)")
            case .assistant: lines.append("\(summary.backend == "codex" ? "Codex" : "Claude"): \(item.text)")
            case .approval:
                let state = item.approval?.state ?? "pending"
                lines.append("Approval [\(item.id.uuidString)] (\(state)): \(item.text)\(item.detail.map { "\n\($0)" } ?? "")")
            case .questions:
                let pending = item.approval?.state == "pending" || item.answers == nil
                lines.append("Questions [\(item.id.uuidString)]\(pending ? " (waiting)" : " (answered)"):")
                for q in item.questions ?? [] {
                    lines.append("  \(q.id): \(q.question) Options: \(q.options.map(\.label).joined(separator: " | "))\(q.multiSelect ? " (several)" : "")")
                }
            default: lines.append("Note: \(item.text)")
            }
            for file in item.attachments {
                lines.append("  File [\(file.id.uuidString)] \(file.name)\(file.isImage ? " (image: show_image)" : "")")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Requests

    private enum Result<T> { case ok(T), failed(String) }
    private static let failure = ("Chatterbox couldn't do that just now.", true)

    private static func request<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, token: String, as type: T.Type) async -> Result<T> {
        let response = await send(method, path, body: body, token: token)
        guard response.status == 200 else { return .failed(message(response)) }
        guard let value = try? Companion.decoder.decode(T.self, from: response.body) else { return .failed("Chatterbox answered in a way the connector didn't expect.") }
        return .ok(value)
    }

    private static func request(_ method: String, _ path: String, body: (any Encodable)? = nil, token: String) async -> HTTPResponse {
        await send(method, path, body: body, token: token)
    }

    private static func send(_ method: String, _ path: String, body: (any Encodable)?, token: String) async -> HTTPResponse {
        var parts = URLComponents(string: path)!
        let data = body.flatMap { try? Companion.encoder.encode($0) } ?? Data()
        let request = HTTPRequest(method: method, path: parts.path,
                                  query: Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 }),
                                  headers: [Companion.tokenHeader.lowercased(): token, "content-type": "application/json"], body: data)
        parts.query = nil
        return await CompanionServer.shared.respondAsync(to: request)
    }

    private static func detailResult(_ response: HTTPResponse, _ done: String) async -> (String, Bool) {
        response.status == 200 ? (done, false) : (message(response), true)
    }

    private static func message(_ response: HTTPResponse) -> String {
        (try? Companion.decoder.decode(Companion.ErrorResponse.self, from: response.body))?.error ?? "Chatterbox answered \(response.status)."
    }

    // MARK: - Schema

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSON], required: [String]) -> JSON {
        ["name": .string(name), "description": .string(description),
         "inputSchema": ["type": "object", "properties": .object(properties), "required": .array(required.map(JSON.string))]]
    }
    private static func prop(_ type: String, _ description: String, _ values: [String]? = nil) -> JSON {
        var schema: [String: JSON] = ["type": .string(type), "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSON.string)) }
        return .object(schema)
    }
}
