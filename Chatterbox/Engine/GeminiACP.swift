import Foundation

struct GeminiError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// One `agy acp` process (Google's Antigravity CLI over the Agent Client Protocol), owned by
/// one chat. Like Claude Code's, it runs in ChatterboxHost so a reply outlives the app, and
/// `offset` is how far its output has been read. It speaks JSON-RPC 2.0 over stdio: requests
/// we send (`session/prompt`, …) get replies; agy sends `session/update` notifications and
/// asks us things (`session/request_permission`). See plans/gemini-agent.md for the protocol.
@MainActor
final class GeminiACPProcess {
    /// Notifications and agy's own requests (which carry an `id` to answer with `respond`).
    var onMessage: ((JSON) -> Void)?
    /// Called once if the process ends; the text is the last thing it printed to stderr.
    var onExit: ((_ status: Int32, _ detail: String) -> Void)?

    private(set) var hostID: String?
    private(set) var offset = 0
    private var running = false
    private var nextID = 1
    /// Ids differ per attach, so a reply to a request from before a relaunch never matches a new one.
    private let idPrefix = "c" + UUID().uuidString.prefix(6) + "-"
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]

    var isRunning: Bool { running }
    var canReleaseIdleProcess: Bool { pending.isEmpty }

    static func locateBinary() -> String? { BinaryLocator.find("agy", customPathKey: "agyPath") }

    /// Starts `agy acp` in the host under `id`.
    func start(cwd: String, environment: [String: String], id: String) throws {
        guard let binary = Self.locateBinary() else {
            throw GeminiError(message: "Couldn't find the `agy` command (Antigravity CLI). Install it from antigravity.google/cli, or set its path in Settings.")
        }
        try HostClient.shared.spawn(id: id, executable: binary, arguments: ["acp"], cwd: cwd,
                                    environment: BinaryLocator.environment.merging(environment) { $1 }, kind: "gemini")
        try attach(id: id, from: 0)
    }

    /// Follows a process already in the host, replaying its output from `offset` first.
    func attach(id: String, from offset: Int) throws {
        hostID = id
        self.offset = offset
        running = true
        try HostClient.shared.attach(id: id, from: offset, onLine: { [weak self] line, end in
            self?.consume(line, end: end)
        }, onExit: { [weak self] status, detail in
            self?.handleExit(status: status, detail: detail)
        })
    }

    private func write(_ message: JSON) {
        guard running, let hostID, let data = try? message.encoded() else { return }
        HostClient.shared.write(id: hostID, data)
    }

    /// Sends a request and waits for its reply's `result`.
    @discardableResult
    func request(_ method: String, _ params: JSON) async throws -> JSON {
        guard running else { throw GeminiError(message: "Gemini isn't running.") }
        let id = "\(idPrefix)\(nextID)"
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params])
        }
    }

    /// Sends a request without waiting, so it stays in order with what's sent after it.
    func requestNow(_ method: String, _ params: JSON) {
        guard running else { return }
        let id = "\(idPrefix)\(nextID)"
        nextID += 1
        write(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params])
    }

    func notify(_ method: String, _ params: JSON) {
        write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    /// Answers one of agy's requests (a permission prompt).
    func respond(to id: JSON, _ result: JSON) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respondError(to id: JSON, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    /// Stops the process and removes its log.
    func terminate() {
        onExit = nil
        if let hostID { HostClient.shared.kill(id: hostID, forget: true) }
        failPending()
        running = false
        hostID = nil
    }

    private func consume(_ line: Data, end: Int) {
        defer { offset = end }
        guard !line.isEmpty, let message = try? JSON.parse(line) else { return }
        if message["method"] == nil, let id = message["id"]?.string, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] {
                continuation.resume(throwing: GeminiError(message: error["message"]?.string ?? "Gemini refused the request."))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        // A reply to a request sent without waiting (or from an earlier attach): nothing to do,
        // except a prompt's reply, which ends the turn.
        onMessage?(message)
    }

    private func handleExit(status: Int32, detail: String) {
        guard running else { return }
        running = false
        failPending()
        if let hostID { HostClient.shared.forget(id: hostID) }
        onExit?(status, detail)
    }

    private func failPending() {
        let error = GeminiError(message: "Gemini stopped.")
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending = [:]
    }
}

/// agy's models and efforts, as `session/new` reports them (`configOptions`). Kept from the
/// last session started, with a built-in list until then.
@MainActor
final class GeminiModels {
    static let shared = GeminiModels()

    struct Model: Equatable, Hashable, Identifiable {
        var id: String
        var name: String
    }

    /// The default, before any session reported its own list (agy 1.5.13, 2026-11-20).
    private(set) var models: [Model] = [
        .init(id: "gemini-4-neon", name: "Gemini 4 Neon"),
        .init(id: "gemini-4-carbon", name: "Gemini 4 Carbon"),
        .init(id: "gemini-4-argon", name: "Gemini 4 Argon"),
        .init(id: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen"),
        .init(id: "gemini-pro-orchestrator-neon", name: "Orchestrator (Neon)"),
        .init(id: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)"),
        .init(id: "gemini-pro-orchestrator-argon", name: "Orchestrator (Argon)"),
        .init(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
    ]
    private(set) var efforts = ["low", "medium", "high", "xhigh"]
    private(set) var defaultModel = "gemini-4-neon"
    private(set) var defaultEffort = "high"

    /// agy also offers Claude and GPT models; Chatterbox has its own agents for those.
    static func isGemini(_ id: String) -> Bool { id.hasPrefix("gemini") }

    func name(_ id: String?) -> String {
        guard let id else { return models.first { $0.id == defaultModel }?.name ?? "Gemini" }
        return models.first { $0.id == id }?.name ?? id
    }

    /// Takes the lists from a `session/new` or `session/load` reply.
    func update(from result: JSON) {
        for option in result["configOptions"]?.array ?? [] {
            let values = (option["options"]?.array ?? []).compactMap { o -> Model? in
                guard let value = o["value"]?.string else { return nil }
                return Model(id: value, name: o["name"]?.string ?? value)
            }
            switch option["id"]?.string {
            case "model":
                let gemini = values.filter { Self.isGemini($0.id) }
                if !gemini.isEmpty { models = gemini }
            case "thought_level":
                if !values.isEmpty { efforts = values.map(\.id) }
            default: break
            }
        }
    }
}

/// Gemini's account limits, from `agy -p /usage --output-format json` (no model call; a
/// second or two). Read when the service starts, every ten minutes, after each Gemini reply,
/// and when the phone opens Usage; at most once a minute.
@MainActor
final class GeminiUsage {
    static let shared = GeminiUsage()
    private var lastRun: Date?
    private var running = false
    private var timer: Timer?

    /// Every ten minutes from now (the service).
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { GeminiUsage.shared.refresh() }
        }
    }

    func refreshIfStale() { if lastRun.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh() } }

    func refresh() {
        guard !running, let agy = GeminiACPProcess.locateBinary() else { return }
        running = true
        lastRun = Date()
        let environment = BinaryLocator.environment
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: agy)
                process.arguments = ["-p", "/usage", "--output-format", "json"]
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                return data
            }.value
            running = false
            guard let data, let reply = try? JSON.parse(data) else { return }
            UsageLimits.shared.updateGemini(reply["command"]?["data"])
        }
    }
}
